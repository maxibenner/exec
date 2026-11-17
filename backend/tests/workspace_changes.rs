mod support;

use exec_agent::{
    Error, ProviderFailure, core::*, manager::AgentManager, storage::JsonConversationStore,
};
use std::{fs, sync::Arc};
use support::*;
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn workspace_changes_survive_reload_and_freeze_only_at_first_acceptance() {
    let profile = directory();
    let old = directory();
    let new = directory();
    fs::write(old.path().join("AGENTS.md"), b"invalid\0instructions").unwrap();
    fs::write(new.path().join("AGENTS.md"), "before selection").unwrap();
    let provider = FakeProvider::new(vec![answer()]);
    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    let c = manager
        .create_session(
            provider.clone(),
            vec![],
            Some("fake".into()),
            old.path().to_string_lossy().into_owned(),
            None,
            vec![],
        )
        .await
        .unwrap();
    let id = c.id.clone();
    // Rejection before acceptance must not lock the workspace.
    assert!(manager.submit(&id, "not accepted".into()).await.is_err());
    assert!(!c.snapshot().configuration.instructions_frozen);
    let changed = manager
        .select_workspace(&id, new.path().join(".").to_string_lossy().into_owned())
        .await
        .unwrap();
    let canonical = fs::canonicalize(new.path())
        .unwrap()
        .to_string_lossy()
        .into_owned();
    assert_eq!(changed.id, id);
    assert_eq!(changed.workspace, canonical);
    assert!(!changed.configuration.instructions_frozen);
    assert_eq!(changed.configuration.workspace_instructions, None);
    assert_eq!(provider.count(), 0);
    manager.close().await.unwrap();

    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    assert_eq!(manager.get(&id).unwrap().snapshot().workspace, canonical);
    // Still editable after reload, including repeated selection.
    manager
        .select_workspace(&id, old.path().to_string_lossy().into_owned())
        .await
        .unwrap();
    manager
        .select_workspace(&id, canonical.clone())
        .await
        .unwrap();
    fs::write(new.path().join("AGENTS.md"), "loaded at acceptance").unwrap();
    complete(manager.submit(&id, "first".into()).await.unwrap()).await;
    let snapshot = manager.get(&id).unwrap().snapshot();
    assert_eq!(
        snapshot.configuration.workspace_instructions.as_deref(),
        Some("loaded at acceptance")
    );
    assert_eq!(
        manager
            .select_workspace(&id, canonical.clone())
            .await
            .unwrap_err(),
        Error::WorkspaceLocked
    );
    let fork = manager.fork(&id, provider.clone(), vec![]).await.unwrap();
    assert_eq!(
        manager
            .select_workspace(&fork.id, canonical.clone())
            .await
            .unwrap_err(),
        Error::WorkspaceLocked
    );
    assert!(
        provider.requests.lock().unwrap()[0]
            .instructions
            .contains(&canonical)
    );
    manager.close().await.unwrap();

    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    assert_eq!(
        manager.select_workspace(&id, canonical).await.unwrap_err(),
        Error::WorkspaceLocked
    );
    manager.close().await.unwrap();
}

#[tokio::test]
async fn workspace_write_blocks_submission_and_finishes_after_caller_detaches() {
    let old = directory();
    let new = directory();
    let new_path = fs::canonicalize(new.path())
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = entered.clone();
    let held = release.clone();
    let expected = new_path.clone();
    let provider = FakeProvider::new(vec![answer()]);
    let mut options = ConversationOptions::new(provider, "fake", old.path().to_string_lossy());
    options.checkpoint = Some(checkpoint(move |record| {
        let ready = ready.clone();
        let held = held.clone();
        let wait = record.workspace == expected && record.messages.is_empty();
        async move {
            if wait {
                ready.cancel();
                held.cancelled().await;
            }
            Ok(())
        }
    }));
    let manager = Arc::new(AgentManager::default());
    let c = manager.create(options).await.unwrap();
    let id = c.id.clone();
    let updating = manager.clone();
    let target = new_path.clone();
    let task = tokio::spawn(async move { updating.select_workspace(&id, target).await });
    entered.cancelled().await;
    assert_ne!(c.snapshot().workspace, new_path);
    assert!(matches!(
        manager.submit(&c.id, "busy".into()).await,
        Err(Error::Busy)
    ));
    assert_eq!(
        manager
            .select_workspace(&c.id, old.path().to_string_lossy().into_owned())
            .await
            .unwrap_err(),
        Error::Busy
    );
    task.abort();
    release.cancel();
    until(&c, |s| s.workspace == new_path).await;
    assert!(!c.snapshot().configuration.instructions_frozen);
    // Use embedded submission so this fixture does not invoke automatic titles.
    complete(c.submit("ready".into()).unwrap()).await;
    assert_eq!(
        manager.select_workspace(&c.id, new_path).await.unwrap_err(),
        Error::WorkspaceLocked
    );
    manager.close().await.unwrap();
}

#[tokio::test]
async fn failed_workspace_save_keeps_published_folder_and_never_retries() {
    let old = directory();
    let new = directory();
    let expected = fs::canonicalize(new.path())
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let mut options = ConversationOptions::new(
        FakeProvider::new(vec![]),
        "fake",
        old.path().to_string_lossy(),
    );
    options.checkpoint = Some(checkpoint(move |record| {
        let fail = record.workspace == expected;
        async move { if fail { Err(Error::Storage) } else { Ok(()) } }
    }));
    let manager = AgentManager::default();
    let c = manager.create(options).await.unwrap();
    let initial = c.snapshot().workspace;
    assert_eq!(
        manager
            .select_workspace(&c.id, new.path().to_string_lossy().into_owned())
            .await
            .unwrap_err(),
        Error::Storage
    );
    assert_eq!(c.snapshot().workspace, initial);
    assert!(c.snapshot().storage_error.is_some());
    assert_eq!(
        manager.select_workspace(&c.id, initial).await.unwrap_err(),
        Error::Storage
    );
    assert!(matches!(
        manager.submit(&c.id, "blocked".into()).await,
        Err(Error::Storage)
    ));
    manager.close().await.unwrap();
}

#[tokio::test]
async fn failed_or_cancelled_first_turn_never_unlocks_workspace() {
    for cancel in [false, true] {
        let workspace = directory();
        let entered = CancellationToken::new();
        let script = if cancel {
            waiting(entered.clone())
        } else {
            script(|_| {
                Box::pin(futures_util::stream::once(async {
                    Err(Error::Provider(ProviderFailure::Request))
                }))
            })
        };
        let manager = AgentManager::default();
        let c = manager
            .create(ConversationOptions::new(
                FakeProvider::new(vec![script]),
                "fake",
                workspace.path().to_string_lossy(),
            ))
            .await
            .unwrap();
        let run = c.submit("first".into()).unwrap();
        if cancel {
            entered.cancelled().await;
            assert!(c.cancel(&run.operation_id));
        }
        let operation = complete(run).await;
        assert_eq!(
            operation.state,
            if cancel {
                OperationState::Interrupted
            } else {
                OperationState::Failed
            }
        );
        assert_eq!(
            manager
                .select_workspace(&c.id, workspace.path().to_string_lossy().into_owned())
                .await
                .unwrap_err(),
            Error::WorkspaceLocked
        );
        manager.close().await.unwrap();
    }
}
