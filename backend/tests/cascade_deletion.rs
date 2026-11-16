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
