mod support;
use exec_agent::{core::*, manager::AgentManager, storage::JsonConversationStore};
use std::{sync::Arc, time::Duration};
use support::*;

fn latest(rx: &mut tokio::sync::watch::Receiver<ChangeNotification>) -> ChangeNotification {
    rx.borrow_and_update().clone()
}
fn summary_matches(c: &Conversation) {
    let mut old = serde_json::to_value(c.snapshot()).unwrap();
    old.as_object_mut().unwrap().remove("messages");
    old.as_object_mut().unwrap().remove("approval");
    assert_eq!(serde_json::to_value(c.summary()).unwrap(), old);
}

#[tokio::test]
async fn provider_metadata_refresh_invalidates_derived_context_usage() {
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio_util::sync::CancellationToken;

    struct MetadataProvider(AtomicBool);
    #[async_trait::async_trait]
    impl ChatProvider for MetadataProvider {
        fn stream(
            &self,
            _: ProviderRequest,
        ) -> futures_util::stream::BoxStream<'static, exec_agent::Result<ProviderEvent>> {
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
        async fn models(&self, _: CancellationToken) -> exec_agent::Result<Vec<ChatModel>> {
            self.0.store(true, Ordering::SeqCst);
            Ok(vec![])
        }
        fn context_window(&self, _: &str) -> Option<u64> {
            self.0.load(Ordering::SeqCst).then_some(1_000)
        }
        async fn set_credential(&self, _: &str, _: Option<String>) -> exec_agent::Result<()> {
            self.0.store(false, Ordering::SeqCst);
            Ok(())
        }
    }

    let provider = Arc::new(MetadataProvider(AtomicBool::new(false)));
    let manager = Arc::new(AgentManager::default());
    let c = manager
        .create(options(provider.clone(), vec![]))
        .await
        .unwrap();
    complete(c.submit("usage".into()).unwrap()).await;
    assert!(c.snapshot().context_usage.is_none());
    let mut rx = manager.subscribe_changes();
    let before = latest(&mut rx);
    manager
        .discover_models(provider.clone(), CancellationToken::new())
        .await
        .unwrap();
    let discovered = latest(&mut rx);
    assert_ne!(discovered.catalog, before.catalog);
    assert_ne!(discovered.conversations[&c.id], before.conversations[&c.id]);
    assert_eq!(c.snapshot().context_usage.unwrap().limit, 1_000);
    manager
        .set_credential(provider, "test", None)
        .await
        .unwrap();
    let signed_out = latest(&mut rx);
    assert_ne!(signed_out.catalog, discovered.catalog);
    assert_ne!(
        signed_out.conversations[&c.id],
        discovered.conversations[&c.id]
    );
    assert!(c.snapshot().context_usage.is_none());
    manager.close().await.unwrap();
}

#[tokio::test]
async fn idle_catalog_metadata_library_and_delete_notifications() {
    let manager = Arc::new(AgentManager::default());
    let mut rx = manager.subscribe_changes();
    let initial = latest(&mut rx);
    assert!(initial.conversations.is_empty());
    assert!(!rx.has_changed().unwrap());
    let c = manager
        .create(options(FakeProvider::new(vec![]), vec![]))
        .await
        .unwrap();
    let created = latest(&mut rx);
    assert_ne!(created.catalog, initial.catalog);
    assert!(created.conversations.contains_key(&c.id));
    summary_matches(&c);
    manager.rename(&c.id, "Renamed".into()).await.unwrap();
    let renamed = latest(&mut rx);
    assert_ne!(renamed.catalog, created.catalog);
    assert_ne!(renamed.conversations[&c.id], created.conversations[&c.id]);
    let mut settings = c.snapshot().configuration.settings;
    settings.system_prompt = "New configuration".into();
    manager.update_settings(&c.id, settings).await.unwrap();
    let configured = latest(&mut rx);
    assert_ne!(configured.catalog, renamed.catalog);
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    let updated = latest(&mut rx);
    assert_ne!(updated.catalog, configured.catalog);
    assert_eq!(updated.conversations, configured.conversations);
    for _ in 0..10 {
        manager.summaries().unwrap();
        manager.sync(&c.id, SyncCursor::Latest).unwrap();
        manager.snapshot(&c.id).unwrap();
    }
    assert!(
        tokio::time::timeout(Duration::from_millis(25), rx.changed())
            .await
            .is_err()
    );
    manager.delete(&c.id).await.unwrap();
    let deleted = latest(&mut rx);
    assert_ne!(deleted.catalog, updated.catalog);
    assert!(deleted.conversations.is_empty());
    manager.close().await.unwrap();
    assert_ne!(
        initial.epoch,
        AgentManager::default().subscribe_changes().borrow().epoch
    );
}

#[tokio::test]
async fn token_and_text_replacement_changes_do_not_invalidate_catalog() {
    let (send, mut events) = tokio::sync::mpsc::unbounded_channel();
    let (ack, mut processed) = tokio::sync::mpsc::unbounded_channel();
    let provider = FakeProvider::new(vec![script(move |_| {
        Box::pin(async_stream::stream! {
            ack.send(()).unwrap();
            while let Some(event) = events.recv().await {
                yield Ok(event);
                ack.send(()).unwrap();
            }
        })
    })]);
    let manager = AgentManager::default();
    let c = manager.create(options(provider, vec![])).await.unwrap();
    let run = c.submit("first".into()).unwrap();
    processed.recv().await.unwrap();
    let mut rx = manager.subscribe_changes();
    let mut previous = latest(&mut rx);
    for event in [
        ProviderEvent::Text("token".into()),
        ProviderEvent::TextSnapshot("replacement".into()),
        ProviderEvent::Text(" tail".into()),
    ] {
        send.send(event).unwrap();
        processed.recv().await.unwrap();
        let next = latest(&mut rx);
        assert_eq!(next.catalog, previous.catalog);
        assert_ne!(next.conversations[&c.id], previous.conversations[&c.id]);
        assert!(
            !serde_json::to_string(&next)
                .unwrap()
                .contains("replacement")
        );
        summary_matches(&c);
        previous = next;
    }
    send.send(ProviderEvent::Done).unwrap();
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_ne!(latest(&mut rx).catalog, previous.catalog);
    manager.close().await.unwrap();
}

#[tokio::test]
async fn approval_and_terminal_states_are_visible_to_notification_only_observers() {
    let provider = FakeProvider::new(vec![
        response(vec![call("call"), ProviderEvent::Done]),
        answer(),
    ]);
    let manager = AgentManager::default();
    let c = manager
        .create(options(
            provider,
            vec![tool(Some("Confirm"), |_| async { Ok("done".into()) })],
        ))
        .await
        .unwrap();
    let mut rx = manager.subscribe_changes();
    let before = latest(&mut rx);
    let run = c.submit("work".into()).unwrap();
    let approval = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            rx.changed().await.unwrap();
            let _ = latest(&mut rx);
            if let Some(approval) = c.snapshot().approval {
                break approval;
            }
        }
    })
    .await
    .unwrap();
    let waiting = latest(&mut rx);
    assert_ne!(waiting.catalog, before.catalog);
    summary_matches(&c);
    assert!(c.resolve_approval(&run.operation_id, &approval.id, true));
    complete(run).await;
    let terminal = latest(&mut rx);
    assert_ne!(terminal.catalog, waiting.catalog);
    assert!(c.snapshot().approval.is_none());
    summary_matches(&c);
    manager.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn subscribe_then_read_cannot_miss_concurrent_metadata_updates() {
    let manager = Arc::new(AgentManager::default());
    let c = manager
        .create(options(FakeProvider::new(vec![]), vec![]))
        .await
        .unwrap();
    for i in 0..100 {
        let manager2 = manager.clone();
        let id = c.id.clone();
        let title = format!("title {i}");
        let next = title.clone();
        let update = tokio::spawn(async move {
            manager2.rename(&id, next).await.unwrap();
        });
        let mut rx = manager.subscribe_changes();
        latest(&mut rx);
        let read = manager.snapshot(&c.id).unwrap();
        update.await.unwrap();
        if read.metadata.title.as_deref() != Some(&title) {
            assert!(
                rx.has_changed().unwrap(),
                "old state requires a catch-up notification"
            );
        }
        assert_eq!(
            manager.snapshot(&c.id).unwrap().metadata.title.as_deref(),
            Some(title.as_str())
        );
    }
    manager.close().await.unwrap();
}

#[tokio::test]
async fn child_creation_changes_and_cascade_deletion_update_the_global_map() {
    let manager = AgentManager::default();
    let provider = FakeProvider::new(vec![]);
    let parent = manager
        .create(options(provider.clone(), vec![]))
        .await
        .unwrap();
    let mut rx = manager.subscribe_changes();
    latest(&mut rx);
    let mut child_options = options(provider, vec![]);
    child_options.metadata.parent = Some(SessionParent {
        session_id: parent.id.clone(),
        operation_id: new_id(),
        tool_call_id: "delegate".into(),
    });
    let child = manager.create(child_options).await.unwrap();
    let created = latest(&mut rx);
    assert_eq!(created.conversations.len(), 2);
    manager
        .rename(&child.id, "child title".into())
        .await
        .unwrap();
    let updated = latest(&mut rx);
    assert_ne!(
        created.conversations[&child.id],
        updated.conversations[&child.id]
    );
    manager.delete(&parent.id).await.unwrap();
    let deleted = latest(&mut rx);
    assert!(deleted.conversations.is_empty());
    assert_ne!(deleted.catalog, updated.catalog);
    manager.close().await.unwrap();
}

#[tokio::test]
async fn restored_forked_and_cleared_conversations_remain_attached() {
    let root = directory();
    let provider = FakeProvider::new(vec![answer()]);
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let manager = AgentManager::open(store, |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let c = manager
        .create(options(provider.clone(), vec![]))
        .await
        .unwrap();
    complete(c.submit("first".into()).unwrap()).await;
    let mut rx = manager.subscribe_changes();
    latest(&mut rx);
    let fork = manager.fork(&c.id, provider.clone(), vec![]).await.unwrap();
    assert!(latest(&mut rx).conversations.contains_key(&fork.id));
    let before = manager.sync(&c.id, SyncCursor::Latest).unwrap();
    let anchor = before.snapshot.messages.last().unwrap().id().to_owned();
    let previous = latest(&mut rx);
    manager.clear(&c.id).await.unwrap();
    assert_ne!(
        latest(&mut rx).conversations[&c.id],
        previous.conversations[&c.id]
    );
    let reset = manager
        .sync(
            &c.id,
            SyncCursor::After {
                anchor: &anchor,
                prefix: before.prefix.as_deref().unwrap(),
            },
        )
        .unwrap();
    assert!(reset.reset);
    assert_eq!(reset.total, 0);
    assert!(reset.prefix.is_none());
    let epoch = latest(&mut rx).epoch;
    manager.close().await.unwrap();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let restored = AgentManager::open(store, |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let mut rx = restored.subscribe_changes();
    let old = latest(&mut rx);
    assert_ne!(old.epoch, epoch);
    assert_eq!(old.conversations.len(), 2);
    restored.rename(&fork.id, "restored".into()).await.unwrap();
    assert_ne!(
        latest(&mut rx).conversations[&fork.id],
        old.conversations[&fork.id]
    );
    restored.close().await.unwrap();
}
