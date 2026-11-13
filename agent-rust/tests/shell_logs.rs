use support::client::AgentClient;
mod support;
use exec_agent::{Error, core::*, service::*};
use futures_util::StreamExt;
use serde_json::json;
use std::{fs, os::unix::fs::PermissionsExt};
use support::*;
use tokio_util::sync::CancellationToken;
async fn until_api(
    client: &AgentClient,
    id: &str,
    predicate: impl Fn(&ConversationSnapshot) -> bool,
) -> ConversationSnapshot {
    let mut events = client.events(id, CancellationToken::new());
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while let Some(frame) = events.next().await {
            let snapshot = match frame.unwrap() {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } => snapshot,
                _ => continue,
            };
            if predicate(&snapshot) {
                return snapshot;
            }
        }
        panic!("missing state");
    })
    .await
    .unwrap()
}
fn shell(command: &str) -> Script {
    response(vec![
        ProviderEvent::ToolCall(ToolCall {
            id: new_id(),
            name: "shell".into(),
            arguments: json!({"command":command,"description":"Inspect generated output"})
                .as_object()
                .unwrap()
                .clone(),
        }),
        ProviderEvent::Done,
    ])
}
#[tokio::test]
async fn full_logs_are_private_readable_and_shared_until_the_last_fork_is_deleted() {
    let profile = directory();
    let workspace = directory();
    let p = FakeProvider::new(vec![
        shell("printf BEGIN; head -c 200000 /dev/zero | tr '\\0' x; printf END"),
        answer(),
    ]);
    let service = start_persistent_service(profile.path(), p, true, "0.0.0.0:0".parse().unwrap())
        .await
        .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    // These fixtures exercise chat requests, not optional metadata inference.
    let mut library = client.library().await.unwrap();
    library.automatic_titles = false;
    client.update_library(library).await.unwrap();
    let c = client
        .create("fake", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    client.submit(&c.id, "run").await.unwrap();
    let terminal = until_api(&client, &c.id, |s| {
        s.operation.as_ref().is_some_and(|o| !o.state.active())
    })
    .await;
    assert_eq!(terminal.operation.unwrap().state, OperationState::Completed);
    assert_eq!(terminal.resources.len(), 1);
    assert!(
        terminal
            .messages
            .iter()
            .any(|m| m.text().contains("Full captured output"))
    );
    let id = &terminal.resources[0].id;
    let path = profile.path().join("shell-logs").join(format!("{id}.log"));
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let mut offset = 0;
    let mut all = String::new();
    loop {
        let chunk = client.read_log(id, offset, 32768).await.unwrap();
        all.push_str(&chunk.text);
        offset = chunk.next_offset;
        if chunk.end_of_file {
            break;
        }
    }
    assert_eq!(all.len(), 200008);
    assert!(all.starts_with("BEGIN") && all.ends_with("END"));
    assert_eq!(
        client.read_log(&new_id(), 0, 10).await.unwrap_err(),
        Error::Api(404)
    );
    let fork = client.fork(&c.id).await.unwrap();
    assert_eq!(fork.resources, terminal.resources);
    service.close().await.unwrap();
    let service = start_persistent_service(
        profile.path(),
        FakeProvider::new(vec![]),
        true,
        "0.0.0.0:0".parse().unwrap(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    assert_eq!(
        client.get(&fork.id).await.unwrap().resources,
        fork.resources
    );
    client.delete(&c.id).await.unwrap();
    assert!(path.exists());
    assert_eq!(client.read_log(id, 0, 5).await.unwrap().text, "BEGIN");
    client.delete(&fork.id).await.unwrap();
    assert!(!path.exists());
    service.close().await.unwrap();
}
#[tokio::test]
async fn denial_creates_no_log_and_cancellation_keeps_diagnostics() {
    let profile = directory();
    let workspace = directory();
    let p = FakeProvider::new(vec![
        shell("printf denied"),
        answer(),
        shell("printf started; sleep 30"),
    ]);
    let service = start_persistent_service(profile.path(), p, true, "0.0.0.0:0".parse().unwrap())
        .await
        .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    // These fixtures exercise chat requests, not optional metadata inference.
    let mut library = client.library().await.unwrap();
    library.automatic_titles = false;
    client.update_library(library).await.unwrap();
    let c = client
        .create_with_settings(
            "fake",
            workspace.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    client.submit(&c.id, "deny").await.unwrap();
    let pending = until_api(&client, &c.id, |s| s.approval.is_some())
        .await
        .approval
        .unwrap();
    client
        .approve(&c.id, &pending.operation_id, &pending.id, false)
        .await
        .unwrap();
    let terminal = until_api(&client, &c.id, |s| {
        s.operation.as_ref().is_some_and(|o| !o.state.active())
    })
    .await;
    assert!(terminal.resources.is_empty());
    assert_eq!(
        fs::read_dir(profile.path().join("shell-logs"))
            .unwrap()
            .count(),
        0
    );
    client
        .update_settings(&c.id, SessionSettings::default())
        .await
        .unwrap();
    let op = client.submit(&c.id, "cancel").await.unwrap();
    let running = until_api(&client, &c.id, |s| s.active_tool_call_id.is_some()).await;
    let log = running.resources[0].id.clone();
    // Wait for observable output, not merely executor entry.
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            if let Ok(chunk) = client.read_log(&log, 0, 32768).await
                && chunk.text.contains("started")
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    client.cancel(&c.id, &op).await.unwrap();
    let terminal = until_api(&client, &c.id, |s| {
        s.operation.as_ref().is_some_and(|o| !o.state.active())
    })
    .await;
    assert_eq!(
        terminal.operation.unwrap().state,
        OperationState::Interrupted
    );
    assert!(
        client
            .read_log(&log, 0, 32768)
            .await
            .unwrap()
            .text
            .contains("started")
    );
    service.close().await.unwrap();
}
