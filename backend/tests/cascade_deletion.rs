#[path = "support/gated_store.rs"]
mod gated_store;
mod support;
use exec_agent::{
    core::*,
    files::FileStore,
    images::ImageStore,
    manager::AgentManager,
    service::*,
    shell_logs::ShellLogStore,
    storage::{ConversationStore, JsonConversationStore},
};
use std::{path::PathBuf, sync::Arc};
use support::{client::AgentClient, *};

async fn assets(profile: &std::path::Path, session: &str) -> (Vec<ResourceRef>, Vec<PathBuf>) {
    let files = FileStore::open(profile.join("session-files"))
        .await
        .unwrap();
    let file = files
        .put(
            session.into(),
            new_id(),
            "notes.txt".into(),
            b"isolated notes".to_vec(),
        )
        .await
        .unwrap();
    let images = ImageStore::open(profile.join("images")).await.unwrap();
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgba8(1, 1)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let image = images
        .put(new_id(), "pixel.png".into(), png.into_inner())
        .await
        .unwrap();
    let logs = ShellLogStore::open(profile.join("shell-logs"))
        .await
        .unwrap();
    let log_id = new_id();
    drop(logs.writer(&log_id).await.unwrap());
    let paths = vec![
        PathBuf::from(file.path),
        profile.join("images").join(format!("{}.image", image.id)),
        logs.path(&log_id).unwrap(),
    ];
    (
        vec![
            ResourceRef {
                id: file.id,
                call_id: String::new(),
                kind: ResourceKind::File,
            },
            ResourceRef {
                id: image.id,
                call_id: String::new(),
                kind: ResourceKind::Image,
            },
            ResourceRef {
                id: log_id,
                call_id: "asset".into(),
                kind: ResourceKind::ShellLog,
            },
        ],
        paths,
    )
}

#[tokio::test]
async fn cascade_deletes_all_asset_types_but_preserves_an_independent_forks_references() {
    let profile = directory();
    let workspace = directory();
    let provider = FakeProvider::new(vec![
        response(vec![call("asset"), ProviderEvent::Done]),
        answer(),
    ]);
    let c = conversation(provider, vec![]);
    complete(c.submit("fixture".into()).unwrap()).await;
    let mut parent = c.record();
    parent.workspace = workspace.path().to_string_lossy().into_owned();
    let mut child = parent.clone();
    child.id = new_id();
    child.metadata.parent = Some(SessionParent {
        session_id: parent.id.clone(),
        operation_id: parent.operation.as_ref().unwrap().id.clone(),
        tool_call_id: "delegate".into(),
    });
    let (shared, shared_paths) = assets(profile.path(), &child.id).await;
    let (exclusive, exclusive_paths) = assets(profile.path(), &parent.id).await;
    parent.resources = exclusive.clone();
    child.resources = [shared.clone(), exclusive].concat();
    let mut fork = child.clone();
    fork.id = new_id();
    fork.metadata.parent = None;
    fork.resources = shared;
    let mut sibling = child.clone();
    sibling.id = new_id();
    let store = JsonConversationStore::open(profile.path().join("conversations"))
        .await
        .unwrap();
    for record in [&parent, &child, &sibling, &fork] {
        store.save(record.clone()).await.unwrap();
    }
    ConversationStore::close(store.as_ref()).await.unwrap();
    let provider = FakeProvider::new(vec![]);
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        true,
        "127.0.0.1:0".parse().unwrap(),
        http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    client.delete(&parent.id).await.unwrap();
    for id in [&parent.id, &child.id, &sibling.id] {
        assert!(client.get(id).await.is_err());
    }
    assert!(client.get(&fork.id).await.is_ok());
    assert!(exclusive_paths.iter().all(|path| !path.exists()));
    assert!(shared_paths.iter().all(|path| path.exists()));
    service.close().await.unwrap();
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        true,
        "127.0.0.1:0".parse().unwrap(),
        http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    for id in [&parent.id, &child.id, &sibling.id] {
        assert!(client.get(id).await.is_err());
    }
    client.delete(&fork.id).await.unwrap();
    assert!(shared_paths.iter().all(|path| !path.exists()));
    assert_eq!(provider.count(), 0);
    service.close().await.unwrap();
}

struct FailingDeleteStore {
    records: Vec<ConversationRecord>,
    attempts: std::sync::Mutex<Vec<String>>,
}
#[async_trait::async_trait]
impl Checkpoint for FailingDeleteStore {
    async fn save(&self, _: ConversationRecord) -> exec_agent::Result<()> {
        Ok(())
    }
}
#[async_trait::async_trait]
impl ConversationStore for FailingDeleteStore {
    async fn load(&self) -> exec_agent::Result<Vec<ConversationRecord>> {
        Ok(self.records.clone())
    }
    async fn prepare_delete(
        &self,
        _: exec_agent::storage::DeletionManifest,
    ) -> exec_agent::Result<()> {
        Ok(()) // This fault fixture has no asset storage or durable writes.
    }
    async fn delete(&self, id: String) -> exec_agent::Result<()> {
        self.attempts.lock().unwrap().push(id);
        Err(exec_agent::Error::Storage)
    }
    async fn close(&self) -> exec_agent::Result<()> {
        Ok(())
    }
}
#[tokio::test]
async fn failed_child_delete_retains_parent_and_never_retries() {
    let provider = FakeProvider::new(vec![]);
    let parent = conversation(provider.clone(), vec![]).record();
    let mut child = parent.clone();
    child.id = new_id();
    child.metadata.parent = Some(SessionParent {
        session_id: parent.id.clone(),
        operation_id: new_id(),
        tool_call_id: "delegate".into(),
    });
    let store = Arc::new(FailingDeleteStore {
        records: vec![parent.clone(), child.clone()],
        attempts: Default::default(),
    });
    let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    assert!(matches!(
        manager.delete(&parent.id).await,
        Err(exec_agent::Error::Storage)
    ));
    assert_eq!(*store.attempts.lock().unwrap(), vec![child.id.clone()]);
    assert!(manager.get(&parent.id).is_ok() && manager.get(&child.id).is_ok());
    manager.close().await.unwrap(); // All catalog reservations were released.
}

#[tokio::test]
async fn deleting_parent_cancels_busy_children_and_preserves_independent_forks() {
    let manager = Arc::new(AgentManager::default());
    let provider = FakeProvider::new(vec![]);
    let parent = manager
        .create(options(provider.clone(), vec![]))
        .await
        .unwrap();
    let entered = tokio_util::sync::CancellationToken::new();
    let mut child_options = options(FakeProvider::new(vec![waiting(entered.clone())]), vec![]);
    child_options.metadata.parent = Some(SessionParent {
        session_id: parent.id.clone(),
        operation_id: new_id(),
        tool_call_id: "delegate".into(),
    });
    let child = manager.create(child_options).await.unwrap();
    let run = child.submit("work".into()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
    let fork = manager.fork(&parent.id, provider, vec![]).await.unwrap();
    manager.delete(&parent.id).await.unwrap();
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(manager.list().unwrap().len(), 1);
    assert!(manager.get(&fork.id).is_ok());
}

async fn record_with_assets(profile: &std::path::Path) -> (ConversationRecord, Vec<PathBuf>) {
    let c = conversation(
        FakeProvider::new(vec![
            response(vec![call("asset"), ProviderEvent::Done]),
            answer(),
        ]),
        vec![],
    );
    complete(c.submit("resource fixture".into()).unwrap()).await;
    let mut record = c.record();
    let (resources, paths) = assets(profile, &record.id).await;
    record.resources = resources;
    (record, paths)
}
#[tokio::test]
async fn uncertain_fork_ownership_cannot_retire_the_sources_durable_cleanup_intent() {
    use gated_store::*;
    use std::sync::atomic::Ordering;
    for committed in [false, true] {
        let profile = directory();
        let (source, paths) = record_with_assets(profile.path()).await;
        let store = GatedStore::new(
            JsonConversationStore::open(profile.path().join("conversations"))
                .await
                .unwrap(),
        );
        store.save(source.clone()).await.unwrap();
        let provider = FakeProvider::new(vec![]);
        let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
            .await
            .unwrap();
        if committed {
            *store.fail_after.lock().unwrap() = Some(Write::Record);
        } else {
            *store.fail_before.lock().unwrap() = Some(Write::Record);
        }
        assert!(matches!(
            manager.fork(&source.id, provider.clone(), vec![]).await,
            Err(exec_agent::Error::Storage)
        ));
        assert_eq!(store.record_attempts.load(Ordering::SeqCst), 2);
        let fork = manager
            .list()
            .unwrap()
            .into_iter()
            .find(|s| s.id != source.id)
            .unwrap();
        assert!(
            manager
                .get(&fork.id)
                .unwrap()
                .submit("uncertain fork".into())
                .is_err()
        );
        manager.delete(&source.id).await.unwrap();
        assert!(paths.iter().all(|p| p.exists()));
        assert_eq!(store.load_deletions().await.unwrap()[0].id, source.id);
        assert_eq!(
            store.record_attempts.load(Ordering::SeqCst),
            2,
            "no mutation retry"
        );
        assert_eq!(provider.count(), 0);
        manager.close().await.unwrap();

        let service = persistent(profile.path()).await;
        let client = AgentClient::new(service.address).unwrap();
        assert!(
            paths.iter().all(|p| p.exists()),
            "startup cannot perform cleanup"
        );
        client.delete(&source.id).await.unwrap();
        if committed {
            assert!(client.get(&fork.id).await.is_ok());
            assert!(paths.iter().all(|p| p.exists()));
            client.delete(&fork.id).await.unwrap();
        } else {
            assert!(client.get(&fork.id).await.is_err());
        }
        assert!(paths.iter().all(|p| !p.exists()));
        service.close().await.unwrap();
    }
}

#[tokio::test]
async fn interrupted_file_cleanup_keeps_its_manifest_until_an_explicit_retry() {
    let profile = directory();
    let (record, paths) = record_with_assets(profile.path()).await;
    let store = JsonConversationStore::open(profile.path().join("conversations"))
        .await
        .unwrap();
    store.save(record.clone()).await.unwrap();
    ConversationStore::close(store.as_ref()).await.unwrap();
    let asset_directory = paths[0].parent().unwrap();
    let unknown = asset_directory.join("not-owned-by-the-manager");
    std::fs::write(&unknown, b"retain unknown files").unwrap();
    let service = persistent(profile.path()).await;
    let client = AgentClient::new(service.address).unwrap();
    assert!(client.delete(&record.id).await.is_err());
    assert!(!paths[0].exists(), "the first unlink committed");
    assert!(unknown.exists());
    service.close().await.unwrap();

    let service = persistent(profile.path()).await;
    let client = AgentClient::new(service.address).unwrap();
    assert!(
        unknown.exists(),
        "startup must not retry cleanup or sweep unknown data"
    );
    assert!(
        profile
            .path()
            .join("conversations")
            .join(format!(".{}.deleting", record.id))
            .exists()
    );
    // Explicitly repair the fixture; only the subsequent DELETE retries cleanup.
    std::fs::remove_file(&unknown).unwrap();
    client.delete(&record.id).await.unwrap();
    assert!(paths.iter().all(|p| !p.exists()));
    assert!(!asset_directory.exists());
    assert!(
        !profile
            .path()
            .join("conversations")
            .join(format!(".{}.deleting", record.id))
            .exists()
    );
    service.close().await.unwrap();
}

#[tokio::test]
async fn cancelled_fork_and_concurrent_clear_keep_shared_assets_until_publication_and_last_delete()
{
    use gated_store::*;
    let profile = directory();
    let (record, paths) = record_with_assets(profile.path()).await;
    let store = GatedStore::new(
        JsonConversationStore::open(profile.path().join("conversations"))
            .await
            .unwrap(),
    );
    store.save(record.clone()).await.unwrap();
    let provider = FakeProvider::new(vec![]);
    let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let gate = store.gate(Write::Record);
    let owner = manager.clone();
    let id = record.id.clone();
    let caller = tokio::spawn(async move { owner.fork(&id, provider, vec![]).await });
    entered(&gate).await;
    caller.abort();
    assert!(caller.await.is_err());
    manager.clear(&record.id).await.unwrap();
    assert_eq!(
        manager.delete(&record.id).await.unwrap_err(),
        exec_agent::Error::Busy
    );
    assert!(paths.iter().all(|p| p.exists()));
    gate.release.cancel();
    eventually(|| manager.list().unwrap().len() == 2).await;
    let fork = manager
        .list()
        .unwrap()
        .into_iter()
        .find(|c| c.id != record.id)
        .unwrap();
    assert_eq!(fork.resources, record.resources);
    manager.delete(&record.id).await.unwrap();
    assert!(paths.iter().all(|p| p.exists()));
    assert!(store.load_deletions().await.unwrap().is_empty());
    manager.close().await.unwrap();
    let service = persistent(profile.path()).await;
    let client = AgentClient::new(service.address).unwrap();
    client.delete(&fork.id).await.unwrap();
    assert!(paths.iter().all(|p| !p.exists()));
    service.close().await.unwrap();
}

#[tokio::test]
async fn missing_child_transcript_keeps_family_cleanup_recoverable_after_restart() {
    use exec_agent::storage::DeletionManifest;
    let profile = directory();
    let (mut child, paths) = record_with_assets(profile.path()).await;
    let mut parent = child.clone();
    parent.id = new_id();
    parent.resources.clear();
    child.metadata.parent = Some(SessionParent {
        session_id: parent.id.clone(),
        operation_id: new_id(),
        tool_call_id: "delegate".into(),
    });
    let store = JsonConversationStore::open(profile.path().join("conversations"))
        .await
        .unwrap();
    store.save(parent.clone()).await.unwrap();
    store.save(child.clone()).await.unwrap();
    let mut resources = child.resources.clone();
    for resource in &mut resources {
        resource.call_id.clear();
    }
    store
        .prepare_delete(DeletionManifest {
            id: child.id.clone(),
            parent_id: Some(parent.id.clone()),
            resources,
        })
        .await
        .unwrap();
    store.delete(child.id.clone()).await.unwrap();
    // Simulate stopping precisely after transcript unlink, before asset cleanup.
    ConversationStore::close(store.as_ref()).await.unwrap();
    let service = persistent(profile.path()).await;
    let client = AgentClient::new(service.address).unwrap();
    assert!(paths.iter().all(|p| p.exists()));
    client.delete(&parent.id).await.unwrap();
    assert!(paths.iter().all(|p| !p.exists()));
    assert!(client.list().await.unwrap().as_array().unwrap().is_empty());
    service.close().await.unwrap();
}

async fn persistent(profile: &std::path::Path) -> Service {
    start_persistent_service(
        profile,
        FakeProvider::new(vec![]),
        false,
        "127.0.0.1:0".parse().unwrap(),
        http_access(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn clear_retains_durable_cleanup_ownership_without_inheriting_it_in_new_forks() {
    let profile = directory();
    let (mut source, shared_paths) = record_with_assets(profile.path()).await;
    let mut shared_fork = source.clone();
    shared_fork.id = new_id();
    let (exclusive, exclusive_paths) = assets(profile.path(), &source.id).await;
    source.resources.extend(exclusive);
    let store = JsonConversationStore::open(profile.path().join("conversations"))
        .await
        .unwrap();
    store.save(source.clone()).await.unwrap();
    store.save(shared_fork.clone()).await.unwrap();
    ConversationStore::close(store.as_ref()).await.unwrap();
    let service = persistent(profile.path()).await;
    let client = AgentClient::new(service.address).unwrap();
    let cleared = client
        .call(
            "POST",
            &format!("/v1/conversations/{}/clear", source.id),
            Some(serde_json::json!({})),
        )
        .await
        .unwrap();
    assert_eq!(cleared["resources"], serde_json::json!([]));
    let empty_fork = client.fork(&source.id).await.unwrap();
    service.close().await.unwrap();

    let store = JsonConversationStore::open(profile.path().join("conversations"))
        .await
        .unwrap();
    let records = store.load().await.unwrap();
    let cleared = records.iter().find(|r| r.id == source.id).unwrap();
    assert!(cleared.resources.is_empty());
    assert_eq!(cleared.cleanup_resources.len(), 6);
    assert!(
        records
            .iter()
            .find(|r| r.id == empty_fork.id)
            .unwrap()
            .cleanup_resources
            .is_empty()
    );
    ConversationStore::close(store.as_ref()).await.unwrap();
    let service = persistent(profile.path()).await;
    let client = AgentClient::new(service.address).unwrap();
    client.delete(&source.id).await.unwrap();
    assert!(exclusive_paths.iter().all(|p| !p.exists()));
    assert!(shared_paths.iter().all(|p| p.exists()));
    client.delete(&shared_fork.id).await.unwrap();
    assert!(shared_paths.iter().all(|p| !p.exists()));
    assert!(client.get(&empty_fork.id).await.is_ok());
    service.close().await.unwrap();
}

#[tokio::test]
async fn unreadable_records_defer_cleanup_durably_until_an_explicit_retry_without_asset_scans() {
    let profile = directory();
    let (record, paths) = record_with_assets(profile.path()).await;
    let (_, orphan_paths) = assets(profile.path(), &new_id()).await;
    let conversations = profile.path().join("conversations");
    let store = JsonConversationStore::open(&conversations).await.unwrap();
    store.save(record.clone()).await.unwrap();
    ConversationStore::close(store.as_ref()).await.unwrap();
    let corrupt_id = new_id();
    let corrupt = conversations.join(format!("{corrupt_id}.json"));
    std::fs::write(&corrupt, b"unreadable; do not overwrite or scan its assets").unwrap();
    let service = persistent(profile.path()).await;
    let client = AgentClient::new(service.address).unwrap();
    client
        .call(
            "POST",
            &format!("/v1/conversations/{}/clear", record.id),
            Some(serde_json::json!({})),
        )
        .await
        .unwrap();
    client.delete(&record.id).await.unwrap();
    assert!(paths.iter().all(|p| p.exists()));
    service.close().await.unwrap();

    let service = persistent(profile.path()).await;
    let client = AgentClient::new(service.address).unwrap();
    assert!(
        paths.iter().all(|p| p.exists()),
        "startup must not retry cleanup"
    );
    assert_eq!(
        std::fs::read(&corrupt).unwrap(),
        b"unreadable; do not overwrite or scan its assets"
    );
    assert!(
        client
            .list()
            .await
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == record.id && r["unreadable"] == true)
    );
    client.delete(&corrupt_id).await.unwrap();
    assert!(
        paths.iter().all(|p| p.exists()),
        "removing an unreadable record is not authorization to retry another deletion"
    );
    client.delete(&record.id).await.unwrap();
    assert!(paths.iter().all(|p| !p.exists()));
    assert!(
        orphan_paths.iter().all(|p| p.exists()),
        "unmanifested assets are never swept"
    );
    service.close().await.unwrap();
}

#[tokio::test]
async fn lost_unlink_acknowledgement_is_explicitly_recoverable_in_process_and_after_restart() {
    use gated_store::{GatedStore, Write};
    use std::sync::atomic::Ordering;
    for retry_before_restart in [false, true] {
        let profile = directory();
        let (record, paths) = record_with_assets(profile.path()).await;
        let store = GatedStore::new(
            JsonConversationStore::open(profile.path().join("conversations"))
                .await
                .unwrap(),
        );
        store.save(record.clone()).await.unwrap();
        let manager = AgentManager::open(store.clone(), |_| (FakeProvider::new(vec![]), vec![]))
            .await
            .unwrap();
        *store.fail_after.lock().unwrap() = Some(Write::Delete);
        assert_eq!(
            manager.delete(&record.id).await.unwrap_err(),
            exec_agent::Error::Storage
        );
        assert_eq!(store.delete_attempts.load(Ordering::SeqCst), 1);
        assert!(store.load().await.unwrap().is_empty());
        assert_eq!(store.load_deletions().await.unwrap()[0].resources.len(), 3);
        assert!(manager.snapshot(&record.id).is_ok());
        assert!(
            manager
                .get(&record.id)
                .unwrap()
                .submit("must stay disposed".into())
                .is_err()
        );
        assert!(paths.iter().all(|p| p.exists()));
        if retry_before_restart {
            manager.delete(&record.id).await.unwrap();
            assert!(manager.snapshot(&record.id).is_err());
            assert_eq!(store.delete_attempts.load(Ordering::SeqCst), 2);
            // No asset stores attached to this embedded manager: retain the manifest.
            assert_eq!(manager.unreadable_sessions(), vec![record.id.clone()]);
        }
        manager.close().await.unwrap();
        let service = persistent(profile.path()).await;
        let client = AgentClient::new(service.address).unwrap();
        assert!(paths.iter().all(|p| p.exists()));
        assert!(
            client
                .list()
                .await
                .unwrap()
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["id"] == record.id)
        );
        client.delete(&record.id).await.unwrap();
        assert!(paths.iter().all(|p| !p.exists()));
        service.close().await.unwrap();
        let store = JsonConversationStore::open(profile.path().join("conversations"))
            .await
            .unwrap();
        assert!(store.load_deletions().await.unwrap().is_empty());
        assert!(
            store.delete(record.id.clone()).await.is_err(),
            "missing records without owned intent are not retried"
        );
        ConversationStore::close(store.as_ref()).await.unwrap();
    }
}
