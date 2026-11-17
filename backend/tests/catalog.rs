use support::client::AgentClient;
mod support;
use exec_agent::{
    Error, core::*, manager::AgentManager, service::*, storage::JsonConversationStore,
};
use serde_json::json;
use std::{fs, sync::Arc};
use support::*;
use tokio_util::sync::CancellationToken;

async fn settled(client: &AgentClient, id: &str) {
    use futures_util::StreamExt;
    let mut events = client.events(id, CancellationToken::new());
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while let Some(event) = events.next().await {
            let snapshot = match event.unwrap() {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } => snapshot,
                _ => continue,
            };
            if snapshot.operation.is_some_and(|op| !op.state.active()) {
                return;
            }
        }
        panic!("missing terminal state");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn defaults_order_rename_model_and_fork_survive_restart_without_mutating_source() {
    let root = directory();
    let workspace = directory();
    let p = FakeProvider::new(vec![answer(), answer()]);
    let service = start_persistent_service(
        root.path(),
        p.clone(),
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let config = LibraryConfiguration {
        automatic_titles: false,
        default_model: Some("first-model".into()),
        settings: SessionSettings {
            system_prompt: "default prompt".into(),
            effort: None,
            search_model: None,
            auto_approve: false,
        },
        order: vec![],
    };
    client.update_library(config.clone()).await.unwrap();
    let c: ConversationSnapshot = serde_json::from_value(
        client
            .call(
                "POST",
                "/v1/conversations",
                Some(json!({"workspace":workspace.path()})),
            )
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(c.model, "first-model");
    assert_eq!(c.configuration.settings, config.settings);
    client
        .submit(&c.id, "A descriptive initial prompt")
        .await
        .unwrap();
    settled(&client, &c.id).await;
    assert_eq!(
        client.get(&c.id).await.unwrap().metadata.title.as_deref(),
        Some("A descriptive initial prompt")
    );
    client.rename(&c.id, "My session").await.unwrap();
    client.select_model(&c.id, "second-model").await.unwrap();
    let source = client.get(&c.id).await.unwrap();
    assert!(source.metadata.manually_named);
    assert!(source.metadata.activity_at > 0);
    let fork = client.fork(&c.id).await.unwrap();
    assert_ne!(fork.id, c.id);
    assert_eq!(fork.messages, source.messages);
    assert_eq!(fork.configuration, source.configuration);
    assert_eq!(client.get(&c.id).await.unwrap(), source);
    client.submit(&fork.id, "Fork-only input").await.unwrap();
    settled(&client, &fork.id).await;
    assert_eq!(client.get(&c.id).await.unwrap().messages, source.messages);
    assert_eq!(p.requests.lock().unwrap()[1].model, "second-model");
    let mut order = config.clone();
    order.order = vec![fork.id.clone(), c.id.clone()];
    client.update_library(order.clone()).await.unwrap();
    assert_eq!(client.list().await.unwrap()[0]["id"], fork.id);
    service.close().await.unwrap();
    let service = start_persistent_service(
        root.path(),
        p,
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    assert_eq!(client.library().await.unwrap(), order);
    assert_eq!(client.get(&c.id).await.unwrap(), source);
    assert_eq!(client.list().await.unwrap()[0]["id"], fork.id);
    service.close().await.unwrap();
}

#[tokio::test]
async fn busy_sessions_reject_mutations_but_fork_without_waiting() {
    let entered = CancellationToken::new();
    let signal = entered.clone();
    let p = FakeProvider::new(vec![script(move |request| {
        Box::pin(async_stream::try_stream! {
            yield ProviderEvent::Text("Partial answer".into());
            signal.cancel();
            request.cancel.cancelled().await;
            Err(Error::Cancelled)?;
        })
    })]);
    let manager = Arc::new(AgentManager::default());
    let c = manager.create(options(p.clone(), vec![])).await.unwrap();
    let run = c.submit("work".into()).unwrap();
    entered.cancelled().await;
    assert_eq!(
        manager.rename(&c.id, "rename".into()).await.unwrap_err(),
        Error::Busy
    );
    assert_eq!(
        manager
            .select_model(&c.id, "other".into())
            .await
            .unwrap_err(),
        Error::Busy
    );
    c.steer(&run.operation_id, "queued input".into()).unwrap();
    let source = c.snapshot();
    let fork = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        manager.fork(&c.id, p.clone(), vec![]),
    )
    .await
    .unwrap()
    .unwrap();
    let snapshot = fork.snapshot();
    assert_eq!(snapshot.messages, source.messages[..1]);
    assert!(snapshot.pending_input.is_empty());
    assert!(!snapshot.operation.unwrap().state.active());
    assert_eq!(c.snapshot(), source);
    assert!(c.busy());
    c.cancel(&run.operation_id);
    complete(run).await;
    let idle_fork = manager.fork(&c.id, p, vec![]).await.unwrap();
    assert!(idle_fork.snapshot().pending_input.is_empty());
    manager.close().await.unwrap();
}

#[tokio::test]
async fn active_fork_preserves_completed_tool_pieces_and_continues_independently() {
    let entered = CancellationToken::new();
    let blocked = entered.clone();
    let tools = vec![tool(None, move |context| {
        let entered = blocked.clone();
        async move {
            if context.call_id == "second" {
                entered.cancel();
                context.cancel.cancelled().await;
                return Err(Error::Cancelled);
            }
            Ok("finished first tool".into())
        }
    })];
    let p = FakeProvider::new(vec![
        response(vec![
            ProviderEvent::Text("Completed tool request".into()),
            call("first"),
            call("second"),
            ProviderEvent::Done,
        ]),
        answer(),
    ]);
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let manager = AgentManager::open(store, |_| (p.clone(), tools.clone()))
        .await
        .unwrap();
    let c = manager
        .create(options(p.clone(), tools.clone()))
        .await
        .unwrap();
    let run = c.submit("work".into()).unwrap();
    entered.cancelled().await;
    let source = c.snapshot();
    let fork = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        manager.fork(&c.id, p.clone(), tools.clone()),
    )
    .await
    .unwrap()
    .unwrap();
    let snapshot = fork.snapshot();
    assert_eq!(snapshot.messages.len(), 3);
    assert_eq!(snapshot.messages[0], source.messages[0]);
    assert_eq!(snapshot.messages[2], source.messages[2]);
    assert!(
        matches!(&snapshot.messages[1], Message::Assistant { text, calls, status: MessageStatus::Completed, .. }
        if text == "Completed tool request" && calls.len() == 1 && calls[0].id == "first")
    );
    fork.record().validate().unwrap();
    assert!(fork.record().provider_state.is_none());
    assert!(snapshot.approval.is_none() && snapshot.active_tool_call_id.is_none());
    assert_eq!(c.snapshot(), source);
    assert!(c.busy());
    complete(fork.submit("Continue fork".into()).unwrap()).await;
    assert_eq!(c.snapshot(), source);
    let saved = fork.snapshot();
    c.cancel(&run.operation_id);
    complete(run).await;
    manager.close().await.unwrap();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let restored = AgentManager::open(store, |_| (p.clone(), tools.clone()))
        .await
        .unwrap();
    assert_eq!(restored.get(&fork.id).unwrap().snapshot(), saved);
    restored.close().await.unwrap();
}

#[tokio::test]
async fn fork_during_approval_does_not_copy_or_resolve_the_live_action() {
    let tools = vec![tool(Some("Confirm"), |_| async {
        panic!("must not execute")
    })];
    let p = FakeProvider::new(vec![response(vec![call("pending"), ProviderEvent::Done])]);
    let manager = Arc::new(AgentManager::default());
    let c = manager
        .create(options(p.clone(), tools.clone()))
        .await
        .unwrap();
    let run = c.submit("work".into()).unwrap();
    let pending = approval(&c).await;
    let fork = manager.fork(&c.id, p, tools).await.unwrap();
    assert_eq!(
        fork.record().tool_availability,
        c.record().tool_availability
    );
    assert_eq!(fork.record().tool_availability.len(), 1);
    fork.record().validate().unwrap();
    let snapshot = fork.snapshot();
    assert!(snapshot.approval.is_none());
    assert!(matches!(&snapshot.messages[1], Message::Assistant { calls, .. } if calls.is_empty()));
    assert_eq!(c.snapshot().approval.unwrap().id, pending.id);
    c.cancel(&run.operation_id);
    complete(run).await;
    manager.close().await.unwrap();
}

#[tokio::test]
async fn library_corruption_or_symlink_fails_closed_without_overwriting_data() {
    for linked in [false, true] {
        let root = directory();
        let path = root.path().join("library.json");
        if linked {
            std::os::unix::fs::symlink("missing", &path).unwrap();
        } else {
            fs::write(&path, b"not json").unwrap();
        }
        let store = JsonConversationStore::open(root.path()).await.unwrap();
        assert!(
            AgentManager::open(store, |_| (FakeProvider::new(vec![]), vec![]))
                .await
                .is_err()
        );
        if linked {
            assert!(fs::symlink_metadata(path).unwrap().file_type().is_symlink());
        } else {
            assert_eq!(fs::read(path).unwrap(), b"not json");
        }
    }
}
