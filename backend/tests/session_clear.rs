mod support;
use async_trait::async_trait;
use exec_agent::{
    Error,
    core::*,
    manager::AgentManager,
    service::*,
    storage::{ConversationStore, JsonConversationStore},
};
use futures_util::{StreamExt, stream::BoxStream};
use serde_json::json;
use std::{
    fs,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::{client::AgentClient, *};
use tokio_util::sync::CancellationToken;

struct Windowed(Arc<FakeProvider>);
#[async_trait]
impl ChatProvider for Windowed {
    async fn accepts_images(&self, _: &str, _: CancellationToken) -> exec_agent::Result<bool> {
        Ok(true)
    }
    fn context_window(&self, _: &str) -> Option<u64> {
        Some(1000)
    }
    fn stream(
        &self,
        request: ProviderRequest,
    ) -> BoxStream<'static, exec_agent::Result<ProviderEvent>> {
        self.0.stream(request)
    }
}
async fn terminal(client: &AgentClient, id: &str) -> ConversationSnapshot {
    let mut events = client.events(id, CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(event) = events.next().await {
            let snapshot = match event.unwrap() {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } => snapshot,
                _ => continue,
            };
            if snapshot
                .operation
                .as_ref()
                .is_some_and(|op| !op.state.active())
            {
                return snapshot;
            }
        }
        panic!("Missing terminal snapshot")
    })
    .await
    .unwrap()
}
fn assert_cleared(snapshot: &ConversationSnapshot) {
    assert!(snapshot.messages.is_empty());
    assert!(snapshot.pending_input.is_empty());
    assert!(snapshot.resources.is_empty());
    assert!(snapshot.operation.is_none());
    assert!(snapshot.approval.is_none());
    assert!(snapshot.active_tool_call_id.is_none());
    assert!(snapshot.usage.is_none());
    assert!(snapshot.context_usage.is_none());
    assert!(snapshot.storage_error.is_none());
}
async fn post(address: std::net::SocketAddr, path: &str) -> reqwest::Response {
    reqwest::Client::builder()
        .no_proxy()
        .retry(reqwest::retry::never())
        .build()
        .unwrap()
        .post(format!("http://{address}{path}"))
        .bearer_auth(API_TOKEN)
        .json(&json!({}))
        .send()
        .await
        .unwrap()
}

#[tokio::test]
async fn clear_is_durable_and_fork_copies_context_settings_and_shared_assets_without_replay() {
    use base64::Engine;
    let profile = directory();
    let workspace = directory();
    fs::write(workspace.path().join("AGENTS.md"), "Original project rules").unwrap();
    let fake = FakeProvider::new(vec![
        response(vec![
            ProviderEvent::Text("Original answer".into()),
            ProviderEvent::Metadata {
                state: Some(json!({"opaque":"original context"})),
                usage: Some(TokenUsage {
                    total_tokens: Some(42),
                    ..Default::default()
                }),
            },
            ProviderEvent::Done,
        ]),
        answer(),
    ]);
    let provider: Arc<dyn ChatProvider> = Arc::new(Windowed(fake.clone()));
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        false,
        "127.0.0.1:0".parse().unwrap(),
        http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let mut library = client.library().await.unwrap();
    library.automatic_titles = false;
    client.update_library(library).await.unwrap();
    let settings = SessionSettings {
        system_prompt: "Custom prompt".into(),
        effort: Some("high".into()),
        search_model: Some("search-model".into()),
        auto_approve: false,
    };
    let initial = client.call("POST", "/v1/conversations", Some(json!({"model":"fake", "workspace":workspace.path(), "settings":settings, "disabledTools":["fetch_content", "delegate"]}))).await.unwrap();
    let id = initial["id"].as_str().unwrap();
    let path = format!("/v1/conversations/{id}");
    client.rename(id, "Keep this title").await.unwrap();
    let file: FileRef = serde_json::from_value(client.call("POST", &format!("{path}/files"), Some(json!({"name":"notes.txt", "base64":base64::engine::general_purpose::STANDARD.encode(b"shared notes")}))).await.unwrap()).unwrap();
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgba8(1, 1)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let image = client
        .upload_image(id, "pixel.png", &png.into_inner())
        .await
        .unwrap();
    client
        .call(
            "POST",
            &format!("{path}/turns"),
            Some(json!({"text":"original input", "files":[file.id], "images":[image]})),
        )
        .await
        .unwrap();
    let source = terminal(&client, id).await;
    assert_eq!(source.context_usage.as_ref().unwrap().tokens, 42);
    let fork = client.fork(id).await.unwrap();
    assert_ne!(fork.id, id);
    assert_eq!(fork.messages, source.messages);
    assert_eq!(fork.configuration, source.configuration);
    assert_eq!(fork.model, source.model);
    assert_eq!(fork.workspace, source.workspace);
    assert_eq!(fork.metadata.disabled_tools, source.metadata.disabled_tools);
    assert_eq!(fork.resources, source.resources);
    assert_eq!(fork.usage, source.usage);
    assert_eq!(fake.count(), 1);
    let mut events = client.events(id, CancellationToken::new());
    events.next().await.unwrap().unwrap();
    let response = post(service.address, &format!("{path}/clear")).await;
    assert_eq!(response.status(), 200);
    let cleared: ConversationSnapshot = response.json().await.unwrap();
    assert_cleared(&cleared);
    assert_eq!(cleared.id, id);
    assert_eq!(cleared.configuration, source.configuration);
    assert_eq!(cleared.model, source.model);
    assert_eq!(cleared.workspace, source.workspace);
    assert_eq!(cleared.metadata.title, source.metadata.title);
    assert_eq!(
        cleared.metadata.manually_named,
        source.metadata.manually_named
    );
    assert_eq!(
        cleared.metadata.disabled_tools,
        source.metadata.disabled_tools
    );
    assert!(!cleared.can_change_workspace);
    let event = tokio::time::timeout(Duration::from_secs(5), events.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(matches!(event, ServiceEvent::Snapshot { snapshot } if snapshot == cleared));
    assert_eq!(client.get(&fork.id).await.unwrap(), fork);
    assert_eq!(fs::read(&file.path).unwrap(), b"shared notes");
    client.read_image(&image.id).await.unwrap();
    assert_eq!(fake.count(), 1);
    assert_eq!(
        client
            .call(
                "PUT",
                &format!("{path}/workspace"),
                Some(json!({"workspace":workspace.path()}))
            )
            .await
            .unwrap_err(),
        Error::Api(409)
    );
    service.close().await.unwrap();

    let store = JsonConversationStore::open(profile.path().join("conversations"))
        .await
        .unwrap();
    let records = store.load().await.unwrap();
    let saved = records.iter().find(|r| r.id == id).unwrap();
    assert!(saved.provider_state.is_none());
    assert!(saved.executing_tool_id.is_none());
    assert!(saved.messages.is_empty() && saved.resources.is_empty());
    assert!(saved.tool_availability.is_empty());
    let fork_availability = &records
        .iter()
        .find(|r| r.id == fork.id)
        .unwrap()
        .tool_availability;
    assert_eq!(fork_availability.len(), 1);
    assert!(fork_availability[0].enabled.is_empty());
    assert_eq!(
        records
            .iter()
            .find(|r| r.id == fork.id)
            .unwrap()
            .provider_state,
        Some(json!({"opaque":"original context"}))
    );
    ConversationStore::close(store.as_ref()).await.unwrap();
    fs::write(
        workspace.path().join("AGENTS.md"),
        "Changed rules must not be loaded",
    )
    .unwrap();
    let service = start_persistent_service(
        profile.path(),
        provider,
        false,
        "127.0.0.1:0".parse().unwrap(),
        http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    assert_eq!(client.get(id).await.unwrap(), cleared);
    assert_eq!(client.get(&fork.id).await.unwrap(), fork);
    assert_eq!(fake.count(), 1);
    client.submit(id, "fresh input").await.unwrap();
    terminal(&client, id).await;
    {
        let requests = fake.requests.lock().unwrap();
        let fresh = &requests[1];
        assert_eq!(fresh.messages.len(), 2);
        assert_eq!(
            fresh.messages[1],
            ContextMessage::ToolAvailability { enabled: vec![] }
        );
        assert_ne!(fresh.message_ids[1], fork_availability[0].id);
        assert_eq!(
            fresh.messages[0],
            ContextMessage::User {
                text: "fresh input".into()
            }
        );
        assert!(fresh.provider_state.is_none());
        assert_eq!(fresh.instructions, requests[0].instructions);
        assert_eq!(fresh.effort, settings.effort);
        assert_eq!(fresh.model, "fake");
        assert_eq!(fresh.tools, requests[0].tools);
    }
    service.close().await.unwrap();
}

#[tokio::test]
async fn clear_resets_reused_sync_cursors_and_keeps_unused_workspace_editable() {
    let manager = Arc::new(AgentManager::default());
    let fake = FakeProvider::new(vec![answer(), answer()]);
    let workspace = directory();
    let c = manager
        .create(ConversationOptions::new(
            fake.clone(),
            "fake",
            workspace.path().to_string_lossy(),
        ))
        .await
        .unwrap();
    let service = start_service(ServiceOptions {
        manager: manager.clone(),
        provider: fake.clone(),
        tools: vec![],
        address: "127.0.0.1:0".parse().unwrap(),
        access: http_access(),
    })
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let path = format!("/v1/conversations/{}", c.id);
    let empty = client
        .call("POST", &format!("{path}/clear"), Some(json!({})))
        .await
        .unwrap();
    assert_eq!(empty["canChangeWorkspace"], true);
    client
        .call(
            "PUT",
            &format!("{path}/workspace"),
            Some(json!({"workspace":workspace.path()})),
        )
        .await
        .unwrap();
    for body in [json!({"unexpected":true}), json!(null)] {
        assert_eq!(
            client
                .call("POST", &format!("{path}/clear"), Some(body))
                .await
                .unwrap_err(),
            Error::Api(400)
        );
    }
    assert_eq!(
        post(
            service.address,
            &format!("/v1/conversations/{}/clear", new_id())
        )
        .await
        .status(),
        404
    );
    complete(c.submit("old".into()).unwrap()).await;
    let page = client
        .call("GET", &format!("{path}/sync"), None)
        .await
        .unwrap();
    let anchor = c.snapshot().messages.last().unwrap().id().to_owned();
    let cursor = format!(
        "{path}/sync?after={anchor}&prefix={}",
        page["prefix"].as_str().unwrap()
    );
    client
        .call("POST", &format!("{path}/clear"), Some(json!({})))
        .await
        .unwrap();
    for _ in 0..2 {
        let page = client.call("GET", &cursor, None).await.unwrap();
        assert_eq!(page["reset"], true);
        assert_eq!(page["offset"], 0);
        assert_eq!(page["total"], 0);
        assert_eq!(page["prefix"], json!(null));
        assert_eq!(page["snapshot"]["messages"], json!([]));
        assert_eq!(page["snapshot"]["operation"], json!(null));
    }
    assert_eq!(
        client
            .call("GET", &format!("{path}/sync?before={anchor}"), None)
            .await
            .unwrap_err(),
        Error::Api(409)
    );
    complete(c.submit("new".into()).unwrap()).await;
    let replacement = client.call("GET", &cursor, None).await.unwrap();
    assert_eq!(replacement["total"], page["total"]); // Same count, different transcript.
    assert_eq!(replacement["reset"], true);
    assert_eq!(replacement["snapshot"]["messages"][0]["text"], "new");
    assert_eq!(fake.count(), 2);
    service.close().await.unwrap();
}

#[tokio::test]
async fn clear_rejects_active_approval_and_cancelling_work_then_discards_pending_input() {
    let fake = FakeProvider::new(vec![response(vec![call("approval"), ProviderEvent::Done])]);
    let manager = Arc::new(AgentManager::default());
    let tools = vec![tool(Some("Approve"), |_| async {
        panic!("must not execute")
    })];
    let c = manager
        .create(options(fake.clone(), tools.clone()))
        .await
        .unwrap();
    let service = start_service(ServiceOptions {
        manager: manager.clone(),
        provider: fake.clone(),
        tools,
        address: "127.0.0.1:0".parse().unwrap(),
        access: http_access(),
    })
    .await
    .unwrap();
    let path = format!("/v1/conversations/{}/clear", c.id);
    let run = c.submit("original".into()).unwrap();
    assert_eq!(manager.clear(&c.id).await.unwrap_err(), Error::Busy);
    let pending = approval(&c).await;
    let before = c.record();
    let response = post(service.address, &path).await;
    assert_eq!(response.status(), 409);
    assert_eq!(
        response.json::<serde_json::Value>().await.unwrap(),
        json!({"error":"Conversation is busy."})
    );
    assert_eq!(c.record(), before);
    c.steer(&run.operation_id, "never replay this".into())
        .unwrap();
    assert!(c.cancel(&run.operation_id));
    assert_eq!(manager.clear(&c.id).await.unwrap_err(), Error::Busy);
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(c.snapshot().pending_input.len(), 1);
    let response = post(service.address, &path).await;
    assert_eq!(response.status(), 200);
    assert_cleared(&response.json::<ConversationSnapshot>().await.unwrap());
    assert!(!c.resolve_approval(&pending.operation_id, &pending.id, true));
    assert!(!c.cancel(&pending.operation_id));
    assert_eq!(fake.count(), 1);
    service.close().await.unwrap();
}

#[tokio::test]
async fn clear_reserves_idle_children_until_save_settles_even_if_caller_detaches() {
    let manager = Arc::new(AgentManager::default());
    let fake = FakeProvider::new(vec![answer()]);
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = entered.clone();
    let held = release.clone();
    let mut opts = options(fake.clone(), vec![]);
    opts.checkpoint = Some(checkpoint(move |record| {
        let ready = ready.clone();
        let held = held.clone();
        async move {
            if record.configuration.unwrap().instructions_frozen && record.operation.is_none() {
                ready.cancel();
                held.cancelled().await;
            }
            Ok(())
        }
    }));
    let c = manager.create(opts).await.unwrap();
    complete(c.submit("original".into()).unwrap()).await;
    let mut opts = options(fake.clone(), vec![]);
    opts.metadata.parent = Some(SessionParent {
        session_id: c.id.clone(),
        operation_id: c.snapshot().operation.unwrap().id,
        tool_call_id: "delegate".into(),
    });
    let child = manager.create(opts).await.unwrap();
    let child_before = child.snapshot();
    let before = c.snapshot();
    let (m, id) = (manager.clone(), c.id.clone());
    let task = tokio::spawn(async move { m.clear(&id).await });
    tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
    assert_eq!(c.snapshot(), before);
    for session in [&c, &child] {
        assert!(matches!(session.submit("blocked".into()), Err(Error::Busy)));
        assert_eq!(manager.clear(&session.id).await.unwrap_err(), Error::Busy);
        assert!(matches!(
            manager.fork(&session.id, fake.clone(), vec![]).await,
            Err(Error::Busy)
        ));
    }
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    assert!(c.busy() && child.busy());
    release.cancel();
    assert_cleared(&until(&c, |s| s.operation.is_none()).await);
    until(&child, |_| !child.busy()).await;
    assert_eq!(child.snapshot(), child_before);
    assert_eq!(fake.count(), 1);
    manager.close().await.unwrap();
}

#[tokio::test]
async fn clear_rejects_busy_descendants_and_idle_children_owned_by_active_delegation() {
    let manager = Arc::new(AgentManager::default());
    let entered = CancellationToken::new();
    let child_entered = CancellationToken::new();
    let fake = FakeProvider::new(vec![
        waiting(entered.clone()),
        waiting(child_entered.clone()),
    ]);
    let parent = manager.create(options(fake.clone(), vec![])).await.unwrap();
    let run = parent.submit("parent".into()).unwrap();
    entered.cancelled().await;
    let mut opts = options(fake.clone(), vec![]);
    opts.metadata.parent = Some(SessionParent {
        session_id: parent.id.clone(),
        operation_id: run.operation_id.clone(),
        tool_call_id: "delegate".into(),
    });
    let child = manager.create(opts).await.unwrap();
    assert!(!child.busy());
    assert_eq!(manager.clear(&child.id).await.unwrap_err(), Error::Busy);
    parent.cancel(&run.operation_id);
    complete(run).await;
    let before = parent.record();
    let run = child.submit("child".into()).unwrap();
    child_entered.cancelled().await;
    assert_eq!(manager.clear(&parent.id).await.unwrap_err(), Error::Busy);
    assert_eq!(parent.record(), before);
    child.cancel(&run.operation_id);
    complete(run).await;
    assert_cleared(&manager.clear(&parent.id).await.unwrap());
    assert_eq!(fake.count(), 2);
    manager.close().await.unwrap();
}

#[tokio::test]
async fn failed_clear_save_retains_transcript_and_blocks_retry() {
    let attempts = Arc::new(AtomicUsize::new(0));
    let count = attempts.clone();
    let mut opts = options(FakeProvider::new(vec![answer()]), vec![]);
    opts.checkpoint = Some(checkpoint(move |record| {
        let count = count.clone();
        async move {
            if record.operation.is_none() {
                count.fetch_add(1, Ordering::SeqCst);
                return Err(Error::Storage);
            }
            Ok(())
        }
    }));
    let manager = Arc::new(AgentManager::default());
    let c = manager.create(opts).await.unwrap();
    complete(c.submit("retain this".into()).unwrap()).await;
    let before = c.record();
    let service = start_service(ServiceOptions {
        manager: manager.clone(),
        provider: FakeProvider::new(vec![]),
        tools: vec![],
        address: "127.0.0.1:0".parse().unwrap(),
        access: http_access(),
    })
    .await
    .unwrap();
    let path = format!("/v1/conversations/{}/clear", c.id);
    for _ in 0..2 {
        let response = post(service.address, &path).await;
        assert_eq!(response.status(), 409);
        assert_eq!(
            response.json::<serde_json::Value>().await.unwrap(),
            json!({"error":"Conversation requires storage recovery."})
        );
    }
    assert_eq!(c.record(), before);
    assert!(c.snapshot().storage_error.is_some());
    assert!(!c.busy());
    assert_eq!(attempts.load(Ordering::SeqCst), 1);
    assert!(matches!(c.submit("blocked".into()), Err(Error::Storage)));
    service.close().await.unwrap();
}
