mod support;
use exec_agent::{
    Error, client::AgentClient, core::*, manager::AgentManager, service::*,
    storage::JsonConversationStore,
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
    let service = start_persistent_service(root.path(), p.clone(), false)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
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
    let service = start_persistent_service(root.path(), p, false)
        .await
        .unwrap();
    assert_eq!(client.library().await.unwrap(), order);
    assert_eq!(client.get(&c.id).await.unwrap(), source);
    assert_eq!(client.list().await.unwrap()[0]["id"], fork.id);
    service.close().await.unwrap();
}

#[tokio::test]
async fn busy_sessions_reject_rename_model_and_fork() {
    let entered = CancellationToken::new();
    let p = FakeProvider::new(vec![waiting(entered.clone())]);
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
    assert!(matches!(
        manager.fork(&c.id, p, vec![]).await,
        Err(Error::Busy)
    ));
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
