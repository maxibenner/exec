#[path = "support/gated_store.rs"]
mod gated_store;
mod support;
use exec_agent::{
    Error,
    core::*,
    manager::AgentManager,
    storage::{ConversationStore, JsonConversationStore},
};
use gated_store::*;
use std::sync::atomic::Ordering;
use support::*;

#[tokio::test]
async fn detached_library_update_and_patch_publish_and_release_the_reservation() {
    for patch in [false, true] {
        let root = directory();
        let store = GatedStore::new(JsonConversationStore::open(root.path()).await.unwrap());
        let manager = AgentManager::open(store.clone(), |_| (FakeProvider::new(vec![]), vec![]))
            .await
            .unwrap();
        let mut changes = manager.subscribe_changes();
        let gate = store.gate(Write::Library);
        let owner = manager.clone();
        let caller = tokio::spawn(async move {
            if patch {
                owner
                    .patch_library(serde_json::json!({"defaultModel":"accepted"}))
                    .await
            } else {
                let library = LibraryConfiguration {
                    default_model: Some("accepted".into()),
                    ..Default::default()
                };
                owner.update_library(library).await
            }
        });
        entered(&gate).await;
        caller.abort();
        assert!(caller.await.unwrap_err().is_cancelled());
        assert_eq!(manager.library_configuration().unwrap_err(), Error::Busy);
        assert_eq!(
            manager
                .update_library(Default::default())
                .await
                .unwrap_err(),
            Error::Busy
        );
        gate.release.cancel();
        eventually(|| {
            manager
                .library_configuration()
                .is_ok_and(|library| library.default_model.as_deref() == Some("accepted"))
        })
        .await;
        changes.changed().await.unwrap();
        assert_eq!(
            store.load_library().await.unwrap(),
            manager.library_configuration().unwrap()
        );
        manager
            .patch_library(serde_json::json!({"automaticTitles":false}))
            .await
            .unwrap();
        manager.close().await.unwrap();
    }
}

#[tokio::test]
async fn detached_create_publishes_the_committed_session_and_releases_mutating() {
    let root = directory();
    let store = GatedStore::new(JsonConversationStore::open(root.path()).await.unwrap());
    let provider = FakeProvider::new(vec![]);
    let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let mut changes = manager.subscribe_changes();
    let gate = store.gate(Write::Record);
    let owner = manager.clone();
    let caller = tokio::spawn(async move { owner.create(options(provider, vec![])).await });
    entered(&gate).await;
    let id = store.load().await.unwrap()[0].id.clone();
    caller.abort();
    assert!(caller.await.is_err());
    assert!(manager.list().unwrap().is_empty());
    assert!(manager.close().await.is_err());
    gate.release.cancel();
    eventually(|| manager.get(&id).is_ok()).await;
    changes.changed().await.unwrap();
    manager.rename(&id, "settled".into()).await.unwrap();
    manager.delete(&id).await.unwrap();
    manager.close().await.unwrap();
}

#[tokio::test]
async fn detached_delete_owns_confirmation_publication_and_reservation_release() {
    let root = directory();
    let store = GatedStore::new(JsonConversationStore::open(root.path()).await.unwrap());
    let provider = FakeProvider::new(vec![]);
    let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let conversation = manager.create(options(provider, vec![])).await.unwrap();
    let gate = store.gate(Write::Delete);
    let (_, mut events) = conversation.subscribe();
    let owner = manager.clone();
    let id = conversation.id.clone();
    let caller = tokio::spawn(async move { owner.delete(&id).await });
    entered(&gate).await;
    caller.abort();
    assert!(caller.await.unwrap_err().is_cancelled());
    assert!(manager.snapshot(&conversation.id).is_ok());
    assert!(conversation.submit("cannot resurrect".into()).is_err());
    // Replacing the busy reservation with disposal must wake settlement observers.
    let event = tokio::time::timeout(std::time::Duration::from_secs(5), events.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(event.as_ref(), ServiceEvent::Snapshot { .. }));
    assert!(!conversation.busy());
    assert!(manager.close().await.is_err());
    assert_eq!(store.load_deletions().await.unwrap().len(), 1);
    gate.release.cancel();
    eventually(|| manager.snapshot(&conversation.id).is_err()).await;
    eventually(|| manager.unreadable_sessions().is_empty()).await;
    assert_eq!(store.delete_attempts.load(Ordering::SeqCst), 1);
    assert!(store.load_deletions().await.unwrap().is_empty());
    manager.close().await.unwrap();
}

#[tokio::test]
async fn lost_create_or_library_acknowledgements_release_reservations_without_retries() {
    for write in [Write::Record, Write::Library] {
        let root = directory();
        let store = GatedStore::new(JsonConversationStore::open(root.path()).await.unwrap());
        let provider = FakeProvider::new(vec![]);
        let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
            .await
            .unwrap();
        *store.fail_after.lock().unwrap() = Some(write);
        let mut created = None;
        if write == Write::Record {
            assert!(matches!(
                manager.create(options(provider.clone(), vec![])).await,
                Err(Error::Storage)
            ));
            let id = store.load().await.unwrap()[0].id.clone();
            assert_eq!(store.record_attempts.load(Ordering::SeqCst), 1);
            assert_eq!(manager.list().unwrap().len(), 1);
            assert!(
                manager
                    .get(&id)
                    .unwrap()
                    .submit("do not resume uncertain work".into())
                    .is_err()
            );
            created = Some(id);
        } else {
            let library = LibraryConfiguration {
                default_model: Some("committed".into()),
                ..Default::default()
            };
            assert_eq!(
                manager.update_library(library).await.unwrap_err(),
                Error::Storage
            );
            assert_eq!(store.library_attempts.load(Ordering::SeqCst), 1);
            assert_eq!(manager.library_configuration().unwrap_err(), Error::Storage);
            assert_eq!(
                manager
                    .patch_library(serde_json::json!({"automaticTitles":false}))
                    .await
                    .unwrap_err(),
                Error::Storage
            );
            assert_eq!(store.library_attempts.load(Ordering::SeqCst), 1);
        }
        manager.close().await.unwrap();
        let manager = AgentManager::open(
            JsonConversationStore::open(root.path()).await.unwrap(),
            |_| (provider.clone(), vec![]),
        )
        .await
        .unwrap();
        assert_eq!(provider.count(), 0, "reload must not resume inference");
        if let Some(id) = created {
            assert!(manager.get(&id).is_ok());
            manager.delete(&id).await.unwrap();
        } else {
            assert_eq!(
                manager
                    .library_configuration()
                    .unwrap()
                    .default_model
                    .as_deref(),
                Some("committed")
            );
        }
        manager.close().await.unwrap();
    }
}

#[tokio::test]
async fn lost_manifest_acknowledgements_do_not_retry_mutations_and_allow_explicit_recovery() {
    for write in [Write::PrepareDelete, Write::CompleteDelete] {
        for retry_in_process in [false, true] {
            let root = directory();
            let store = GatedStore::new(JsonConversationStore::open(root.path()).await.unwrap());
            let provider = FakeProvider::new(vec![]);
            let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
                .await
                .unwrap();
            let conversation = manager
                .create(options(provider.clone(), vec![]))
                .await
                .unwrap();
            *store.fail_after.lock().unwrap() = Some(write);
            assert_eq!(
                manager.delete(&conversation.id).await.unwrap_err(),
                Error::Storage
            );
            assert_eq!(store.prepare_attempts.load(Ordering::SeqCst), 1);
            assert_eq!(
                store.delete_attempts.load(Ordering::SeqCst),
                usize::from(write == Write::CompleteDelete)
            );
            assert_eq!(
                store.complete_attempts.load(Ordering::SeqCst),
                usize::from(write == Write::CompleteDelete)
            );
            assert!(conversation.submit("cannot resurrect".into()).is_err());
            if retry_in_process {
                manager.delete(&conversation.id).await.unwrap();
                assert_eq!(store.prepare_attempts.load(Ordering::SeqCst), 2);
                assert!(manager.unreadable_sessions().is_empty());
            }
            manager.close().await.unwrap(); // Every error released its reservation.
            let store = GatedStore::new(JsonConversationStore::open(root.path()).await.unwrap());
            let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
                .await
                .unwrap();
            assert_eq!(store.prepare_attempts.load(Ordering::SeqCst), 0);
            assert_eq!(store.delete_attempts.load(Ordering::SeqCst), 0);
            assert_eq!(store.complete_attempts.load(Ordering::SeqCst), 0);
            assert_eq!(store.record_attempts.load(Ordering::SeqCst), 0);
            assert_eq!(provider.count(), 0);
            if write == Write::PrepareDelete && !retry_in_process {
                assert!(manager.snapshot(&conversation.id).is_ok());
                assert!(
                    manager
                        .get(&conversation.id)
                        .unwrap()
                        .submit("still closed".into())
                        .is_err()
                );
                assert_eq!(store.load_deletions().await.unwrap().len(), 1);
                manager.delete(&conversation.id).await.unwrap();
            } else {
                assert!(manager.snapshot(&conversation.id).is_err());
            }
            assert!(store.load_deletions().await.unwrap().is_empty());
            manager.close().await.unwrap();
        }
    }
}
