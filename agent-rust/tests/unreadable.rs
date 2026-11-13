use support::client::AgentClient;
mod support;
use exec_agent::{
    core::*,
    manager::AgentManager,
    service::*,
    storage::{ConversationStore, JsonConversationStore},
};
use std::fs;
use support::*;

#[tokio::test]
async fn corrupt_record_does_not_hide_valid_history_and_requires_explicit_deletion() {
    let root = directory();
    let p = FakeProvider::new(vec![]);
    let service = start_persistent_service(
        root.path(),
        p.clone(),
        false,
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let valid = client
        .create("fake", root.path().to_str().unwrap())
        .await
        .unwrap();
    service.close().await.unwrap();
    let broken_id = new_id();
    let broken = root
        .path()
        .join("conversations")
        .join(format!("{broken_id}.json"));
    fs::write(&broken, b"corrupt transcript").unwrap();
    let service = start_persistent_service(root.path(), p, false, "127.0.0.1:0".parse().unwrap())
        .await
        .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let list = client.list().await.unwrap();
    assert!(
        list.as_array()
            .unwrap()
            .iter()
            .any(|item| item["id"] == valid.id)
    );
    assert!(
        list.as_array()
            .unwrap()
            .iter()
            .any(|item| item["id"] == broken_id && item["unreadable"] == true)
    );
    assert_eq!(
        client.get(&broken_id).await.unwrap_err(),
        exec_agent::Error::Api(409)
    );
    assert_eq!(fs::read(&broken).unwrap(), b"corrupt transcript");
    client.delete(&broken_id).await.unwrap();
    assert!(!broken.exists());
    assert_eq!(client.get(&valid.id).await.unwrap(), valid);
    service.close().await.unwrap();
}

#[tokio::test]
async fn unsafe_store_entries_still_fail_startup_and_release_ownership() {
    for kind in ["symlink", "directory"] {
        let root = directory();
        let path = root.path().join(format!("{}.json", new_id()));
        if kind == "symlink" {
            std::os::unix::fs::symlink("missing", path).unwrap();
        } else {
            fs::create_dir(path).unwrap();
        }
        let store = JsonConversationStore::open(root.path()).await.unwrap();
        assert!(
            AgentManager::open(store, |_| (FakeProvider::new(vec![]), vec![]))
                .await
                .is_err()
        );
        let store = JsonConversationStore::open(root.path()).await.unwrap();
        store.close().await.unwrap();
    }
}
