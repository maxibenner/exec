mod support;

use async_trait::async_trait;
use exec_agent::{
    Error, Result, core::*, manager::AgentManager, service::*, storage::ConversationStore,
};
use serde_json::json;
use std::{
    collections::BTreeMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::{FakeProvider, client::AgentClient};
use tokio_util::sync::CancellationToken;

struct Gate {
    entered: tokio::sync::Semaphore,
    release: CancellationToken,
}
impl Gate {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            entered: tokio::sync::Semaphore::new(0),
            release: CancellationToken::new(),
        })
    }
    async fn wait(&self, count: u32) {
        tokio::time::timeout(Duration::from_secs(5), self.entered.acquire_many(count))
            .await
            .expect("storage gate not reached")
            .unwrap()
            .forget();
    }
    async fn hold(&self) {
        self.entered.add_permits(1);
        self.release.cancelled().await;
    }
}

#[derive(Default)]
struct GatedStore {
    records: Mutex<BTreeMap<String, ConversationRecord>>,
    delete_gate: Mutex<Option<Arc<Gate>>>,
    save_gate: Mutex<Option<Arc<Gate>>>,
    saves: AtomicUsize,
}
#[async_trait]
impl Checkpoint for GatedStore {
    async fn save(&self, record: ConversationRecord) -> Result<()> {
        self.saves.fetch_add(1, Ordering::SeqCst);
        let gate = self.save_gate.lock().unwrap().clone();
        if let Some(gate) = gate {
            gate.hold().await;
        }
        self.records
            .lock()
            .unwrap()
            .insert(record.id.clone(), record);
        Ok(())
    }
}
#[async_trait]
impl ConversationStore for GatedStore {
    async fn load(&self) -> Result<Vec<ConversationRecord>> {
        Ok(self.records.lock().unwrap().values().cloned().collect())
    }
    async fn delete(&self, id: String) -> Result<()> {
        let gate = self.delete_gate.lock().unwrap().clone();
        if let Some(gate) = gate {
            gate.hold().await;
        }
        self.records.lock().unwrap().remove(&id);
        Ok(())
    }
    async fn close(&self) -> Result<()> {
        Ok(())
    }
}

async fn serve(manager: Arc<AgentManager>, provider: Arc<dyn ChatProvider>) -> Service {
    start_service(ServiceOptions {
        manager,
        provider,
        tools: vec![],
        address: "127.0.0.1:0".parse().unwrap(),
        access: support::http_access(),
    })
    .await
    .unwrap()
}

#[derive(Default)]
struct PartialMetadataProvider {
    limit: AtomicUsize,
    model_calls: AtomicUsize,
    stream_calls: AtomicUsize,
    entered: CancellationToken,
}
#[async_trait]
impl ChatProvider for PartialMetadataProvider {
    fn stream(
        &self,
        _: ProviderRequest,
    ) -> futures_util::stream::BoxStream<'static, Result<ProviderEvent>> {
        self.stream_calls.fetch_add(1, Ordering::SeqCst);
        // A single explicit fake turn seeds derived context usage, without I/O.
        Box::pin(futures_util::stream::iter([
            Ok(ProviderEvent::Metadata {
                state: None,
                usage: Some(TokenUsage {
                    total_tokens: Some(120),
                    ..Default::default()
                }),
            }),
            Ok(ProviderEvent::Done),
        ]))
    }
    fn context_window(&self, _: &str) -> Option<u64> {
        let limit = self.limit.load(Ordering::SeqCst);
        (limit != 0).then_some(limit as u64)
    }
    async fn models(&self, _: CancellationToken) -> Result<Vec<ChatModel>> {
        self.model_calls.fetch_add(1, Ordering::SeqCst);
        self.limit.store(1_000, Ordering::SeqCst);
        self.entered.cancel();
        // Simulate one updated cache followed by another provider that stalls.
        // Deliberately ignore cancellation: the HTTP boundary must drop us.
        std::future::pending().await
    }
}

#[tokio::test]
async fn partial_discovery_disconnect_and_timeout_invalidate_derived_snapshots() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    for disconnect in [true, false] {
        let manager = Arc::new(AgentManager::default());
        let provider = Arc::new(PartialMetadataProvider::default());
        let c = manager
            .create(support::options(provider.clone(), vec![]))
            .await
            .unwrap();
        support::complete(c.submit("seed fake usage".into()).unwrap()).await;
        assert!(c.snapshot().context_usage.is_none());
        let service = serve(manager.clone(), provider.clone()).await;
        let mut changes = manager.subscribe_changes();
        let request = format!(
            "GET /v1/models HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {}\r\nConnection: close\r\n\r\n",
            support::API_TOKEN
        );
        let mut socket = tokio::net::TcpStream::connect(service.address)
            .await
            .unwrap();
        socket.write_all(request.as_bytes()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), provider.entered.cancelled())
            .await
            .unwrap();
        assert_eq!(c.snapshot().context_usage.unwrap().limit, 1_000);
        // Invalidation must include sessions created while discovery is suspended.
        let late = manager
            .create(support::options(provider.clone(), vec![]))
            .await
            .unwrap();
        let before = changes.borrow_and_update().clone();
        if disconnect {
            drop(socket);
        } else {
            // Use the real API's 120-second deadline without waiting on wall time.
            // Pause only after loopback headers have reached the provider gate.
            tokio::time::pause();
            tokio::time::advance(Duration::from_secs(120)).await;
            tokio::time::resume();
            let mut response = Vec::new();
            tokio::time::timeout(Duration::from_secs(2), socket.read_to_end(&mut response))
                .await
                .unwrap()
                .unwrap();
            assert!(response.starts_with(b"HTTP/1.1 500"));
        }
        tokio::time::timeout(Duration::from_secs(2), changes.changed())
            .await
            .unwrap()
            .unwrap();
        let after = changes.borrow_and_update().clone();
        assert_ne!(after.catalog, before.catalog);
        for id in [&c.id, &late.id] {
            assert_ne!(after.conversations[id], before.conversations[id]);
        }
        assert_eq!(
            manager
                .snapshot(&c.id)
                .unwrap()
                .context_usage
                .unwrap()
                .limit,
            1_000
        );
        assert_eq!(provider.model_calls.load(Ordering::SeqCst), 1);
        assert_eq!(provider.stream_calls.load(Ordering::SeqCst), 1);
        service.close().await.unwrap();
    }
}

#[tokio::test]
async fn pending_deletion_is_conflict_not_absence_and_readers_still_work() {
    let store = Arc::new(GatedStore::default());
    let provider = FakeProvider::new(vec![]);
    let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let conversation = manager
        .create(support::options(provider.clone(), vec![]))
        .await
        .unwrap();
    let service = serve(manager.clone(), provider.clone()).await;
    let client = AgentClient::new(service.address).unwrap();
    let path = format!("/v1/conversations/{}", conversation.id);
    let gate = Gate::new();
    *store.delete_gate.lock().unwrap() = Some(gate.clone());
    let deleting = {
        let client = client.clone();
        let id = conversation.id.clone();
        tokio::spawn(async move { client.delete(&id).await })
    };
    gate.wait(1).await;
    assert!(matches!(manager.get(&conversation.id), Err(Error::Busy)));
    for (method, suffix, body) in [
        ("PUT", "/title", Some(json!({"title":"must not run"}))),
        ("POST", "/fork", Some(json!({}))),
        ("DELETE", "", None),
    ] {
        assert_eq!(
            client
                .call(method, &format!("{path}{suffix}"), body)
                .await
                .unwrap_err(),
            Error::Api(409)
        );
    }
    assert_eq!(
        client.call("GET", &path, None).await.unwrap()["id"],
        conversation.id
    );
    assert_eq!(
        client
            .call("GET", &format!("{path}/sync"), None)
            .await
            .unwrap()["snapshot"]["id"],
        conversation.id
    );
    let http = reqwest::Client::builder()
        .no_proxy()
        .retry(reqwest::retry::never())
        .build()
        .unwrap();
    let events = http
        .get(format!("http://{}{path}/events", service.address))
        .bearer_auth(support::API_TOKEN)
        .send()
        .await
        .unwrap();
    assert_eq!(events.status(), 200);
    drop(events);
    gate.release.cancel();
    tokio::time::timeout(Duration::from_secs(5), deleting)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(matches!(
        manager.get(&conversation.id),
        Err(Error::ConversationNotFound)
    ));
    for suffix in ["", "/sync", "/events"] {
        assert_eq!(
            client
                .call("GET", &format!("{path}{suffix}"), None)
                .await
                .unwrap_err(),
            Error::Api(404)
        );
    }
    assert_eq!(
        client
            .call(
                "PUT",
                &format!("{path}/title"),
                Some(json!({"title":"absent"}))
            )
            .await
            .unwrap_err(),
        Error::Api(404)
    );
    assert_eq!(provider.count(), 0);
    service.close().await.unwrap();
}

#[tokio::test]
async fn disconnected_writes_keep_admission_until_storage_settles_and_shutdown_waits() {
    use tokio::io::AsyncWriteExt;
    let store = Arc::new(GatedStore::default());
    let provider = FakeProvider::new(vec![]);
    let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let mut sessions = Vec::new();
    for _ in 0..65 {
        sessions.push(
            manager
                .create(support::options(provider.clone(), vec![]))
                .await
                .unwrap(),
        );
    }
    let service = serve(manager, provider.clone()).await;
    let client = AgentClient::new(service.address).unwrap();
    let gate = Gate::new();
    *store.save_gate.lock().unwrap() = Some(gate.clone());
    let initial_saves = store.saves.load(Ordering::SeqCst);
    for (index, conversation) in sessions[..64].iter().enumerate() {
        let body = json!({"title":format!("accepted {index}")}).to_string();
        let request = format!(
            "PUT /v1/conversations/{}/title HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            conversation.id,
            support::API_TOKEN,
            body.len()
        );
        let mut socket = tokio::net::TcpStream::connect(service.address)
            .await
            .unwrap();
        socket.write_all(request.as_bytes()).await.unwrap();
        gate.wait(1).await;
        // The complete body was accepted. Losing TCP ownership must not release
        // admission or cancel the in-flight save. No mutation is ever replayed.
        drop(socket);
    }
    let spare = &sessions[64];
    for _ in 0..8 {
        assert_eq!(
            tokio::time::timeout(
                Duration::from_secs(2),
                client.call(
                    "PUT",
                    &format!("/v1/conversations/{}/title", spare.id),
                    Some(json!({"title":"must not queue"}))
                )
            )
            .await
            .unwrap()
            .unwrap_err(),
            Error::Api(503)
        );
    }
    assert_eq!(store.saves.load(Ordering::SeqCst), initial_saves + 64);
    assert_eq!(
        client.call("GET", "/v1/health", None).await.unwrap()["version"],
        1
    );
    assert_eq!(client.get(&spare.id).await.unwrap().metadata.title, None);
    let mut closing = tokio::spawn(service.close());
    assert!(
        tokio::time::timeout(Duration::from_millis(25), &mut closing)
            .await
            .is_err()
    );
    gate.release.cancel();
    tokio::time::timeout(Duration::from_secs(5), closing)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let records = store.records.lock().unwrap();
    assert_eq!(records.len(), 65);
    for (index, conversation) in sessions[..64].iter().enumerate() {
        assert_eq!(
            records[&conversation.id].metadata.title,
            Some(format!("accepted {index}"))
        );
    }
    assert_eq!(records[&spare.id].metadata.title, None);
    assert_eq!(store.saves.load(Ordering::SeqCst), initial_saves + 64);
    assert_eq!(provider.count(), 0);
}

fn png() -> Vec<u8> {
    let mut bytes = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(1, 1)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    bytes.into_inner()
}

#[tokio::test]
async fn invalid_uploads_do_not_checkpoint_ownership_or_create_assets() {
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    let profile = support::directory();
    let workspace = support::directory();
    let provider = FakeProvider::new(vec![]);
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let c = client
        .create("fake", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    let path = format!("/v1/conversations/{}", c.id);
    let record = profile
        .path()
        .join("conversations")
        .join(format!("{}.json", c.id));
    let before = std::fs::read(&record).unwrap();
    let modified = std::fs::metadata(&record).unwrap().modified().unwrap();
    for (kind, name, data) in [
        ("images", "empty.png".to_owned(), String::new()),
        ("images", "broken.png".into(), B64.encode(b"not an image")),
        ("images", "truncated.png".into(), B64.encode(&png()[..24])),
        ("images", String::new(), B64.encode(png())),
        ("images", "bad\nname".into(), B64.encode(png())),
        ("images", "x".repeat(257), B64.encode(png())),
        ("images", "bad-base64.png".into(), "%%%".into()),
        ("files", "../escape".into(), B64.encode(b"data")),
        ("files", String::new(), B64.encode(b"data")),
    ] {
        assert_eq!(
            client
                .call(
                    "POST",
                    &format!("{path}/{kind}"),
                    Some(json!({"name":name,"base64":data}))
                )
                .await
                .unwrap_err(),
            Error::Api(400)
        );
        assert_eq!(std::fs::read(&record).unwrap(), before);
        assert_eq!(
            std::fs::metadata(&record).unwrap().modified().unwrap(),
            modified
        );
        assert_eq!(client.get(&c.id).await.unwrap(), c);
        for directory in ["images", "session-files"] {
            assert_eq!(
                std::fs::read_dir(profile.path().join(directory))
                    .unwrap()
                    .count(),
                0
            );
        }
    }
    service.close().await.unwrap();
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    assert!(client.get(&c.id).await.unwrap().resources.is_empty());
    client
        .upload_image(&c.id, "valid.png", &png())
        .await
        .unwrap();
    assert_eq!(client.get(&c.id).await.unwrap().resources.len(), 1);
    assert_eq!(provider.count(), 0);
    service.close().await.unwrap();
}

#[tokio::test]
async fn storage_failures_keep_reserved_uploads_and_are_not_bad_requests() {
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    use std::os::unix::fs::PermissionsExt;
    let profile = support::directory();
    let workspace = support::directory();
    let provider = FakeProvider::new(vec![]);
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let c = client
        .create("fake", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    for (kind, directory, name, bytes) in [
        ("images", "images", "valid.png", png()),
        ("files", "session-files", "valid.txt", b"data".to_vec()),
    ] {
        // Break store identity in this isolated profile before publication. The
        // write boundary still must conservatively retain checkpointed ownership.
        let root = profile.path().join(directory);
        std::fs::rename(&root, profile.path().join(format!("{directory}-original"))).unwrap();
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            client
                .call(
                    "POST",
                    &format!("/v1/conversations/{}/{kind}", c.id),
                    Some(json!({"name":name,"base64":B64.encode(bytes)}))
                )
                .await
                .unwrap_err(),
            Error::Api(500)
        );
    }
    let snapshot = client.get(&c.id).await.unwrap();
    assert_eq!(snapshot.resources.len(), 2);
    let durable: ConversationRecord = serde_json::from_slice(
        &std::fs::read(
            profile
                .path()
                .join("conversations")
                .join(format!("{}.json", c.id)),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(durable.resources, snapshot.resources);
    assert_eq!(provider.count(), 0);
    service.close().await.unwrap();
}
