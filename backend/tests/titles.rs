mod support;
use exec_agent::{core::*, manager::AgentManager, storage::JsonConversationStore};
use support::*;

#[tokio::test]
async fn automatic_titles_are_isolated_and_manual_names_survive_restart() {
    let root = directory();
    let workspace = directory();
    let provider = FakeProvider::new(vec![answer(), answer(), answer(), answer(), answer()]);
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    let c = manager
        .create(ConversationOptions::new(
            provider.clone(),
            "fake",
            workspace.path().to_str().unwrap(),
        ))
        .await
        .unwrap();
    complete(manager.submit(&c.id, "Plan a garden".into()).await.unwrap()).await;
    assert_eq!(
        c.snapshot().metadata.title.as_deref(),
        Some("Completed answer")
    );
    assert_eq!(c.snapshot().messages.len(), 2);
    {
        let requests = provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[0].tools.is_empty());
        assert!(requests[0].provider_state.is_none());
        assert_eq!(requests[0].message_ids.len(), requests[0].messages.len());
        assert!(valid_id(&requests[0].message_ids[0]));
        assert_ne!(requests[0].message_ids[0], requests[1].message_ids[0]);
        let ContextMessage::User { text } = &requests[0].messages[0] else {
            panic!()
        };
        let fields: serde_json::Value = serde_json::from_str(text).unwrap();
        assert_eq!(fields["current_title"], "");
        assert_eq!(fields["latest_user_message"], "Plan a garden");
        assert_eq!(
            requests[1].messages,
            vec![ContextMessage::User {
                text: "Plan a garden".into()
            }]
        );
    }
    complete(manager.submit(&c.id, "Add tomatoes".into()).await.unwrap()).await;
    assert_eq!(provider.count(), 4);
    manager
        .rename(&c.id, "My chosen name".into())
        .await
        .unwrap();
    manager.close().await.unwrap();
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    complete(
        manager
            .submit(&c.id, "Different topic".into())
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(provider.count(), 5);
    let snapshot = manager.get(&c.id).unwrap().snapshot();
    assert_eq!(snapshot.metadata.title.as_deref(), Some("My chosen name"));
    assert!(snapshot.metadata.manually_named);
}

#[tokio::test]
async fn forks_of_manual_names_can_generate_titles_until_explicitly_renamed() {
    let root = directory();
    let workspace = directory();
    let provider = FakeProvider::new(vec![
        answer(),
        response(vec![
            ProviderEvent::Text("New fork topic".into()),
            ProviderEvent::Done,
        ]),
        answer(),
        answer(),
    ]);
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    let source = manager
        .create(ConversationOptions::new(
            provider.clone(),
            "fake",
            workspace.path().to_str().unwrap(),
        ))
        .await
        .unwrap();
    complete(source.submit("Original topic".into()).unwrap()).await;
    manager
        .rename(&source.id, "Chosen name".into())
        .await
        .unwrap();
    let original = source.snapshot();
    let fork = manager
        .fork(&source.id, provider.clone(), vec![])
        .await
        .unwrap();
    assert_eq!(
        fork.snapshot().metadata.title.as_deref(),
        Some("Chosen name (fork)")
    );
    assert!(!fork.snapshot().metadata.manually_named);
    manager.close().await.unwrap();

    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    let fork = manager.get(&fork.id).unwrap();
    assert!(!fork.snapshot().metadata.manually_named);
    assert_eq!(
        complete(
            manager
                .submit(&fork.id, "Different topic".into())
                .await
                .unwrap()
        )
        .await
        .state,
        OperationState::Completed
    );
    assert_eq!(
        fork.snapshot().metadata.title.as_deref(),
        Some("New fork topic")
    );
    assert!(!fork.snapshot().metadata.manually_named);
    assert_eq!(manager.get(&source.id).unwrap().snapshot(), original);
    {
        let requests = provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 3);
        let ContextMessage::User { text } = &requests[1].messages[0] else {
            panic!()
        };
        let fields: serde_json::Value = serde_json::from_str(text).unwrap();
        assert_eq!(fields["current_title"], "Chosen name (fork)");
        assert_eq!(fields["latest_user_message"], "Different topic");
    }

    manager
        .rename(&fork.id, "Fork's chosen name".into())
        .await
        .unwrap();
    complete(
        manager
            .submit(&fork.id, "Another topic".into())
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(provider.count(), 4);
    assert_eq!(
        fork.snapshot().metadata.title.as_deref(),
        Some("Fork's chosen name")
    );
    assert!(fork.snapshot().metadata.manually_named);
    manager.close().await.unwrap();
}

#[tokio::test]
async fn disabled_naming_and_incomplete_titles_do_not_disrupt_chat() {
    let workspace = directory();
    let provider = FakeProvider::new(vec![
        response(vec![ProviderEvent::Text("Incomplete".into())]),
        answer(),
        answer(),
    ]);
    let manager = AgentManager::default();
    let c = manager
        .create(ConversationOptions::new(
            provider.clone(),
            "fake",
            workspace.path().to_str().unwrap(),
        ))
        .await
        .unwrap();
    let op = complete(
        manager
            .submit(&c.id, "Original topic".into())
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(op.state, OperationState::Completed);
    assert_eq!(
        c.snapshot().metadata.title.as_deref(),
        Some("Original topic")
    );
    let mut config = manager.library_configuration().unwrap();
    config.automatic_titles = false;
    manager.update_library(config).await.unwrap();
    complete(manager.submit(&c.id, "Follow-up".into()).await.unwrap()).await;
    assert_eq!(provider.count(), 3);
    assert_eq!(
        c.snapshot().metadata.title.as_deref(),
        Some("Original topic")
    );
}

#[tokio::test]
async fn cancellation_during_title_generation_does_not_start_chat_or_retry() {
    let workspace = directory();
    let entered = tokio_util::sync::CancellationToken::new();
    let provider = FakeProvider::new(vec![waiting(entered.clone())]);
    let manager = AgentManager::default();
    let c = manager
        .create(ConversationOptions::new(
            provider.clone(),
            "fake",
            workspace.path().to_str().unwrap(),
        ))
        .await
        .unwrap();
    let run = manager.submit(&c.id, "Topic".into()).await.unwrap();
    entered.cancelled().await;
    assert!(c.cancel(&run.operation_id));
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(provider.count(), 1);
    assert!(!c.busy());
}
