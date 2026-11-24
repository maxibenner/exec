mod support;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use exec_agent::{core::*, files::FileStore, service::*};
use serde_json::json;
use std::{
    os::unix::fs::{PermissionsExt, symlink},
    path::Path,
    time::Duration,
};
use support::{FakeProvider, client::AgentClient};
use tokio_util::sync::CancellationToken;

async fn upload(client: &AgentClient, id: &str, name: &str, bytes: &[u8]) -> FileRef {
    serde_json::from_value(
        client
            .call(
                "POST",
                &format!("/v1/conversations/{id}/files"),
                Some(json!({"name":name,"base64":B64.encode(bytes)})),
            )
            .await
            .unwrap(),
    )
    .unwrap()
}
async fn terminal(client: &AgentClient, id: &str) -> ConversationSnapshot {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let snapshot: ConversationSnapshot = serde_json::from_value(
                client
                    .call("GET", &format!("/v1/conversations/{id}"), None)
                    .await
                    .unwrap(),
            )
            .unwrap();
            if snapshot
                .operation
                .as_ref()
                .is_some_and(|o| !o.state.active())
            {
                return snapshot;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn file_cleanup_accepts_committed_unlinks_but_never_follows_replacement_links() {
    for removed in 1..=3 {
        let root = support::directory();
        let store = FileStore::open(root.path().to_owned()).await.unwrap();
        let file = store
            .put(new_id(), new_id(), "owned.txt".into(), b"owned".to_vec())
            .await
            .unwrap();
        let path = Path::new(&file.path);
        let asset = path.parent().unwrap();
        let session = asset.parent().unwrap();
        std::fs::remove_file(path).unwrap();
        if removed >= 2 {
            std::fs::remove_dir(asset).unwrap();
        }
        if removed >= 3 {
            std::fs::remove_dir(session).unwrap();
        }
        assert!(store.resolve(vec![file.id.clone()]).await.is_err());
        store.delete(vec![file.id.clone()]).await.unwrap();
        assert!(!root.path().join(format!("{}.json", file.id)).exists());
        assert!(!session.exists());
    }
    for target in ["index", "session", "asset", "payload"] {
        let root = support::directory();
        let outside = support::directory();
        let external = outside.path().join("preserve.txt");
        std::fs::write(&external, b"not owned").unwrap();
        let store = FileStore::open(root.path().to_owned()).await.unwrap();
        let file = store
            .put(new_id(), new_id(), "owned.txt".into(), b"owned".to_vec())
            .await
            .unwrap();
        let path = Path::new(&file.path);
        let asset = path.parent().unwrap();
        let session = asset.parent().unwrap();
        let index = root.path().join(format!("{}.json", file.id));
        match target {
            "index" => {
                std::fs::remove_file(&index).unwrap();
                symlink(&external, &index).unwrap();
            }
            "payload" => {
                std::fs::remove_file(path).unwrap();
                symlink(&external, path).unwrap();
            }
            "asset" | "session" => {
                let directory = if target == "asset" { asset } else { session };
                std::fs::rename(directory, root.path().join("retained")).unwrap();
                symlink(outside.path(), directory).unwrap();
            }
            _ => unreachable!(),
        }
        assert!(store.delete(vec![file.id]).await.is_err());
        assert!(std::fs::symlink_metadata(index).is_ok());
        assert_eq!(std::fs::read(external).unwrap(), b"not owned");
    }
}

#[tokio::test]
async fn files_are_shell_readable_owned_and_retained_until_last_fork_is_deleted() {
    let profile = support::directory();
    let workspace = support::directory();
    let provider = FakeProvider::new(vec![support::answer()]);
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        true,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let mut library = client.library().await.unwrap();
    library.automatic_titles = false;
    client.update_library(library).await.unwrap();
    let c = client
        .create("fake", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    let other = client
        .create("fake", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    let name = format!("{} 'report'.csv", "a".repeat(100));
    let file = upload(&client, &c.id, &name, b"name,value\napples,12\n").await;
    let pdf = upload(&client, &c.id, "report.pdf", b"%PDF-1.7\nopaque bytes\0").await;
    assert_ne!(file.path, pdf.path);
    assert!(
        Path::new(&file.path).starts_with(
            profile
                .path()
                .canonicalize()
                .unwrap()
                .join("session-files")
                .join(&c.id)
        )
    );
    assert_eq!(
        std::fs::read(&pdf.path).unwrap(),
        b"%PDF-1.7\nopaque bytes\0"
    );
    assert_eq!(
        std::fs::metadata(&file.path).unwrap().permissions().mode() & 0o777,
        0o400
    );
    let route = format!("/v1/conversations/{}/turns", c.id);
    for (id, files) in [
        (&other.id, json!([file.id])),
        (&c.id, json!([file.id, file.id])),
        (&c.id, json!([file])),
    ] {
        assert!(
            client
                .call(
                    "POST",
                    &format!("/v1/conversations/{id}/turns"),
                    Some(json!({"text":"", "files":files}))
                )
                .await
                .is_err()
        );
    }
    assert_eq!(provider.count(), 0);
    client
        .call(
            "POST",
            &route,
            Some(json!({"text":"", "files":[file.id, pdf.id]})),
        )
        .await
        .unwrap();
    let snapshot = terminal(&client, &c.id).await;
    assert_eq!(snapshot.operation.unwrap().state, OperationState::Completed);
    assert!(snapshot.metadata.title.unwrap().chars().count() <= 80);
    assert!(
        matches!(&snapshot.messages[0], Message::User { files, text, .. } if files.len() == 2 && text.is_empty())
    );
    {
        let requests = provider.requests.lock().unwrap();
        let ContextMessage::User { text } = &requests[0].messages[0] else {
            panic!()
        };
        assert!(text.contains(&file.path));
        assert!(text.contains("untrusted data"));
        assert!(!text.contains("apples,12")); // Only paths, not document bytes, enter context.
    }
    // The existing shell reads the managed path, while still requesting approval.
    let shell = exec_agent::tools::create_shell_tool();
    let quoted = format!("'{}'", file.path.replace('\'', "'\\''"));
    let prepared = shell
        .prepare(
            json!({"command":format!("sed -n '2p' {quoted}")})
                .as_object()
                .unwrap()
                .clone(),
            ToolContext {
                available_images: vec![],
                conversation_id: c.id.clone(),
                operation_id: new_id(),
                search_model: None,
                call_id: new_id(),
                model: "fake".into(),
                workspace: workspace.path().to_str().unwrap().into(),
                cancel: CancellationToken::new(),
            },
        )
        .await
        .unwrap();
    assert!(prepared.approval().is_some());
    assert!(prepared.execute().await.unwrap().contains("apples,12"));
    let fork = client.fork(&c.id).await.unwrap();
    service.close().await.unwrap();
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        true,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    assert_eq!(provider.count(), 1); // Restart never resumes inference.
    client.delete(&c.id).await.unwrap();
    assert!(Path::new(&file.path).exists());
    let restored = client
        .call("GET", &format!("/v1/conversations/{}", fork.id), None)
        .await
        .unwrap();
    assert_eq!(restored["messages"][0]["files"][0]["path"], file.path);
    client.delete(&fork.id).await.unwrap();
    assert!(!Path::new(&file.path).exists());
    assert!(!Path::new(&pdf.path).exists());
    assert!(!profile.path().join("session-files").join(&c.id).exists());
    service.close().await.unwrap();
}

#[tokio::test]
async fn queued_file_only_input_survives_cancellation_and_restart_without_replay() {
    let profile = support::directory();
    let workspace = support::directory();
    let entered = CancellationToken::new();
    let provider = FakeProvider::new(vec![support::waiting(entered.clone())]);
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        true,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let mut library = client.library().await.unwrap();
    library.automatic_titles = false;
    client.update_library(library).await.unwrap();
    let c = client
        .create("fake", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    let op = client.submit(&c.id, "hold").await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
    let file = upload(&client, &c.id, "notes.md", b"queued notes").await;
    let route = format!("/v1/conversations/{}/steer", c.id);
    assert!(
        client
            .call(
                "POST",
                &route,
                Some(json!({"operationID":new_id(),"text":"","files":[file.id]}))
            )
            .await
            .is_err()
    );
    assert!(
        client
            .call(
                "POST",
                &route,
                Some(json!({"operationID":op,"text":" ".repeat(128 * 1024 + 1),"files":[file.id]}))
            )
            .await
            .is_err()
    );
    client
        .call(
            "POST",
            &route,
            Some(json!({"operationID":op,"text":"","files":[file.id]})),
        )
        .await
        .unwrap();
    client
        .call(
            "POST",
            &format!("/v1/conversations/{}/cancel", c.id),
            Some(json!({"operationID":op})),
        )
        .await
        .unwrap();
    let snapshot = terminal(&client, &c.id).await;
    assert!(
        matches!(&snapshot.pending_input[..], [Message::User { files, text, .. }] if files == std::slice::from_ref(&file) && text.is_empty())
    );
    assert!(
        client
            .call(
                "POST",
                &route,
                Some(json!({"operationID":op,"text":"","files":[file.id]}))
            )
            .await
            .is_err()
    );
    service.close().await.unwrap();
    let service = start_persistent_service(
        profile.path(),
        provider.clone(),
        true,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let snapshot = client
        .call("GET", &format!("/v1/conversations/{}", c.id), None)
        .await
        .unwrap();
    assert_eq!(snapshot["pendingInput"][0]["files"][0]["id"], file.id);
    assert_eq!(provider.count(), 1);
    client.delete(&c.id).await.unwrap();
    assert!(!Path::new(&file.path).exists());
    service.close().await.unwrap();
}

#[tokio::test]
async fn file_store_rejects_paths_oversized_files_and_symlinks_without_overwrite() {
    let root = support::directory();
    let store = FileStore::open(root.path().join("files")).await.unwrap();
    let session = new_id();
    for name in ["../escape", "a/b", "..", "bad\nname", ""] {
        assert!(
            store
                .put(session.clone(), new_id(), name.into(), vec![])
                .await
                .is_err()
        );
    }
    assert!(
        store
            .put(
                session.clone(),
                new_id(),
                "large".into(),
                vec![0; MAX_FILE_BYTES + 1]
            )
            .await
            .is_err()
    );
    let id = new_id();
    let file = store
        .put(session.clone(), id.clone(), "empty.txt".into(), vec![])
        .await
        .unwrap();
    assert!(
        store
            .put(
                session.clone(),
                id.clone(),
                "overwrite".into(),
                b"changed".to_vec()
            )
            .await
            .is_err()
    );
    assert!(
        store
            .put(
                new_id(),
                id.clone(),
                "collision.txt".into(),
                b"other session".to_vec()
            )
            .await
            .is_err()
    );
    assert_eq!(
        store.resolve(vec![id.clone()]).await.unwrap(),
        vec![file.clone()]
    );
    std::fs::remove_file(&file.path).unwrap();
    let outside = root.path().join("outside");
    std::fs::write(&outside, b"secret").unwrap();
    symlink(&outside, &file.path).unwrap();
    assert!(store.resolve(vec![id.clone()]).await.is_err());
    assert!(store.delete(vec![id]).await.is_err());
    assert_eq!(std::fs::read(outside).unwrap(), b"secret");
}
