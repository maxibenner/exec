mod support;

use async_trait::async_trait;
use exec_agent::{
    Error, Result, core::*, manager::AgentManager, service::*, storage::ConversationStore,
};
use serde_json::json;
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
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
}
#[async_trait]
impl Checkpoint for GatedStore {
    async fn save(&self, record: ConversationRecord) -> Result<()> {
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
