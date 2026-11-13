use support::client::AgentClient;
#[path = "support/http.rs"]
mod http;
mod support;
use exec_agent::{
    Error,
    core::*,
    providers::{DeepSeekProvider, credential_store::DeepSeekCredentials},
    service::*,
};
use serde_json::json;
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    sync::Arc,
    time::Duration,
};
use support::*;
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn private_json_connect_disconnect_and_environment_precedence() {
    let root = directory();
    let path = root.path().join("credentials.json");
    let store = DeepSeekCredentials::open(path.clone(), None).await.unwrap();
    assert!(!store.connection().connected);
    store.set(Some("synthetic-test-key".into())).await.unwrap();
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(store.connection().connected);
    let reopened = DeepSeekCredentials::open(path.clone(), None).await.unwrap();
    assert_eq!(
        reopened.key(&CancellationToken::new()).unwrap(),
        "synthetic-test-key"
    );
    let env = DeepSeekCredentials::open(path.clone(), Some("environment-test-key".into()))
        .await
        .unwrap();
    assert_eq!(env.connection().source, "environment");
    assert!(!env.connection().manageable);
    assert!(env.set(None).await.is_err());
    assert!(
        fs::read_to_string(&path)
            .unwrap()
            .contains("synthetic-test-key")
    );
    store.set(None).await.unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&fs::read(&path).unwrap()).unwrap(),
        json!({})
    );
    assert!(
        !DeepSeekCredentials::open(path, None)
            .await
            .unwrap()
            .connection()
            .connected
    );
}

#[tokio::test]
async fn insecure_credentials_are_never_repaired_or_overwritten() {
    for kind in [
        "permissions",
        "symlink",
        "directory",
        "oversize",
        "malformed",
    ] {
        let root = directory();
        let path = root.path().join("credentials.json");
        match kind {
            "symlink" => symlink("missing", &path).unwrap(),
            "directory" => fs::create_dir(&path).unwrap(),
            "oversize" => fs::write(&path, vec![b'x'; 16385]).unwrap(),
            _ => fs::write(&path, b"malformed").unwrap(),
        }
        if kind == "permissions" {
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        } else if path.is_file() {
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        assert!(
            DeepSeekCredentials::open(path.clone(), None).await.is_err(),
            "{kind}"
        );
        // Environment-backed startup ignores JSON, but is externally managed.
        let env = DeepSeekCredentials::open(path.clone(), Some("environment-test-key".into()))
            .await
            .unwrap();
        assert!(env.set(None).await.is_err());
        assert!(fs::symlink_metadata(&path).is_ok());
    }
    let root = directory();
    let path = root.path().join("credentials.json");
    let store = DeepSeekCredentials::open(path.clone(), None).await.unwrap();
    symlink("missing", &path).unwrap();
    assert!(store.set(Some("synthetic-test-key".into())).await.is_err());
    assert!(store.connection().blocked);
    assert_eq!(
        store.key(&CancellationToken::new()).unwrap_err(),
        Error::Storage
    );
    assert!(fs::symlink_metadata(path).unwrap().file_type().is_symlink());
}

#[tokio::test]
async fn api_credentials_change_at_runtime_without_exposing_secrets_or_network_validation() {
    use futures_util::StreamExt;
    let root = directory();
    let workspace = directory();
    let store = DeepSeekCredentials::open(root.path().join("credentials.json"), None)
        .await
        .unwrap();
    let transport = http::Transport::new(|request| async move {
        assert_eq!(request.key, "synthetic-test-key");
        Ok(http::wire(
            http::event(http::delta(json!({"content":"Hello"}), Some("stop")))
                + &http::event(json!("[DONE]")),
        ))
    });
    let provider = Arc::new(
        DeepSeekProvider::with_authentication(store, transport.clone(), Duration::from_secs(3))
            .unwrap(),
    );
    let service =
        start_persistent_service(root.path(), provider, false, "127.0.0.1:0".parse().unwrap())
            .await
            .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    // These fixtures exercise chat requests, not optional metadata inference.
    let mut library = client.library().await.unwrap();
    library.automatic_titles = false;
    client.update_library(library).await.unwrap();
    let c = client
        .create("deepseek-chat", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    assert!(!client.connections().await.unwrap()[0].connected);
    let connected = client
        .connect_api_key("deepseek", "synthetic-test-key")
        .await
        .unwrap();
    assert!(connected[0].connected);
    assert_eq!(transport.count(), 0);
    assert!(
        !serde_json::to_string(&connected)
            .unwrap()
            .contains("synthetic-test-key")
    );
    client.submit(&c.id, "hello").await.unwrap();
    let mut events = client.events(&c.id, CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(frame) = events.next().await {
            let snapshot = match frame.unwrap() {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } => snapshot,
                _ => continue,
            };
            if snapshot.operation.is_some_and(|o| !o.state.active()) {
                break;
            }
        }
    })
    .await
    .unwrap();
    drop(events);
    assert_eq!(transport.count(), 1);
    assert!(!client.disconnect("deepseek").await.unwrap()[0].connected);
    assert!(
        !serde_json::to_string(&client.get(&c.id).await.unwrap())
            .unwrap()
            .contains("synthetic-test-key")
    );
    service.close().await.unwrap();
}
