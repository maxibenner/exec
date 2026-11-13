mod support;
use exec_agent::{
    Error,
    client::AgentClient,
    core::*,
    manager::AgentManager,
    service::*,
    terminal::{Transcript, terminal_text},
};
use futures_util::{StreamExt, stream::BoxStream};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::*;
use tokio_util::sync::CancellationToken;
struct Fixture {
    root: tempfile::TempDir,
    service: Service,
    client: AgentClient,
}
async fn setup(provider: Arc<dyn ChatProvider>, tools: Vec<Arc<dyn Tool>>) -> Fixture {
    let root = directory();
    let service = start_service(ServiceOptions {
        manager: Arc::new(AgentManager::default()),
        provider,
        tools,
        socket_path: profile_socket(root.path()),
    })
    .await
    .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    Fixture {
        root,
        service,
        client,
    }
}
async fn until_api(
    client: &AgentClient,
    id: &str,
    predicate: impl Fn(&ConversationSnapshot) -> bool,
) -> ConversationSnapshot {
    let mut events = client.events(id, CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(frame) = events.next().await {
            match frame.unwrap() {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } if predicate(&snapshot) => return snapshot,
                _ => {}
            }
        }
        panic!("Missing expected snapshot")
    })
    .await
    .unwrap()
}
async fn terminal(client: &AgentClient, id: &str) -> ConversationSnapshot {
    until_api(client, id, |s| {
        s.operation.as_ref().is_some_and(|o| !o.state.active())
    })
    .await
}
fn snapshot(frame: ServiceEvent) -> Option<ConversationSnapshot> {
    match frame {
        ServiceEvent::Snapshot { snapshot }
        | ServiceEvent::Runtime {
            snapshot: Some(snapshot),
            ..
        } => Some(snapshot),
        _ => None,
    }
}
#[tokio::test]
async fn api_default_auto_and_durable_settings_updates_reconcile_observers() {
    let root = directory();
    let p = FakeProvider::new(vec![answer()]);
    let service = start_persistent_service(root.path(), p.clone(), false)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    let c = client
        .create("fake", root.path().to_str().unwrap())
        .await
        .unwrap();
    assert!(c.configuration.settings.auto_approve);
    let mut events = client.events(&c.id, CancellationToken::new());
    events.next().await.unwrap().unwrap();
    let settings = SessionSettings {
        auto_approve: false,
        system_prompt: "Use concise answers".into(),
        effort: None,
    };
    let updated = client
        .update_settings(&c.id, settings.clone())
        .await
        .unwrap();
    let frame = tokio::time::timeout(Duration::from_secs(3), events.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(snapshot(frame).unwrap(), updated);
    drop(events);
    for invalid in [
        json!({"autoApprove":true}),
        json!({"autoApprove":true,"systemPrompt":"", "extra":true}),
        json!({"autoApprove":false,"systemPrompt":"x".repeat(INSTRUCTION_LIMIT + 1)}),
    ] {
        assert_eq!(
            client
                .call(
                    "PUT",
                    &format!("/v1/conversations/{}/settings", c.id),
                    Some(invalid)
                )
                .await
                .unwrap_err(),
            Error::Api(400)
        );
    }
    service.close().await.unwrap();
    let service = start_persistent_service(root.path(), p.clone(), false)
        .await
        .unwrap();
    assert_eq!(
        client.get(&c.id).await.unwrap().configuration.settings,
        settings
    );
    client.submit(&c.id, "hello").await.unwrap();
    terminal(&client, &c.id).await;
    assert!(
        p.requests.lock().unwrap()[0]
            .instructions
            .contains("Use concise answers")
    );
    service.close().await.unwrap();
}

#[tokio::test]
async fn api_delete_is_durable_and_does_not_repeat() {
    let root = directory();
    let provider = FakeProvider::new(vec![]);
    let service = start_persistent_service(root.path(), provider.clone(), false)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    let conversation = client
        .create_with_settings(
            "fake",
            root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    client.delete(&conversation.id).await.unwrap();
    assert_eq!(
        client.get(&conversation.id).await.unwrap_err(),
        Error::Api(404)
    );
    assert_eq!(
        client.delete(&conversation.id).await.unwrap_err(),
        Error::Api(404)
    );
    service.close().await.unwrap();
    let service = start_persistent_service(root.path(), provider, false)
        .await
        .unwrap();
    assert_eq!(client.list().await.unwrap(), json!([]));
    service.close().await.unwrap();
}

#[tokio::test]
async fn api_create_stream_reconnect_and_durable_continuation() {
    let root = directory();
    let p = FakeProvider::new(vec![answer(), answer()]);
    let service = start_persistent_service(root.path(), p.clone(), false)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    assert_eq!(
        client.health().await.unwrap(),
        json!({"version":1,"toolsEnabled":false})
    );
    let c = client
        .create_with_settings(
            "fake",
            root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    let op = client.submit(&c.id, "Hi").await.unwrap();
    let saved = terminal(&client, &c.id).await;
    assert_eq!(saved.operation.as_ref().unwrap().id, op);
    assert_eq!(saved.messages.last().unwrap().text(), "Completed answer");
    let mut reconnect = client.events(&c.id, CancellationToken::new());
    assert_eq!(
        snapshot(reconnect.next().await.unwrap().unwrap()).unwrap(),
        saved
    );
    drop(reconnect);
    let list = client.list().await.unwrap();
    assert_eq!(list[0]["id"], c.id);
    assert!(list[0].get("messages").is_none());
    assert_eq!(
        fs::metadata(profile_socket(root.path()))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    service.close().await.unwrap();
    let service = start_persistent_service(root.path(), p.clone(), false)
        .await
        .unwrap();
    assert_eq!(client.get(&c.id).await.unwrap(), saved);
    assert_eq!(p.count(), 1);
    client.submit(&c.id, "Continue explicitly").await.unwrap();
    assert_eq!(terminal(&client, &c.id).await.messages.len(), 4);
    assert_eq!(p.count(), 2);
    let disk: Value = serde_json::from_slice(
        &fs::read(
            root.path()
                .join("conversations")
                .join(format!("{}.json", c.id)),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(disk["operation"]["state"], "completed");
    service.close().await.unwrap();
}
#[tokio::test]
async fn same_conversation_exclusion_cross_conversation_concurrency_explicit_cancel() {
    let entered = CancellationToken::new();
    let ready = entered.clone();
    let p = FakeProvider::new(vec![
        script(move |r| {
            Box::pin(
                async_stream::try_stream! {yield ProviderEvent::Text("partial".into());ready.cancel();r.cancel.cancelled().await;Err(Error::Cancelled)?;},
            )
        }),
        answer(),
    ]);
    let f = setup(p.clone(), vec![]).await;
    let a = f
        .client
        .create_with_settings(
            "fake",
            f.root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    let b = f
        .client
        .create_with_settings(
            "fake",
            f.root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    let op = f.client.submit(&a.id, "hold").await.unwrap();
    entered.cancelled().await;
    assert_eq!(
        f.client.disconnect("deepseek").await.unwrap_err(),
        Error::Api(409)
    );
    assert_eq!(
        f.client
            .update_settings(&a.id, SessionSettings::default())
            .await
            .unwrap_err(),
        Error::Api(409)
    );
    assert_eq!(f.client.delete(&a.id).await.unwrap_err(), Error::Api(409));
    assert_eq!(
        f.client.submit(&a.id, "duplicate").await.unwrap_err(),
        Error::Api(409)
    );
    assert_eq!(
        f.client.cancel(&a.id, &new_id()).await.unwrap_err(),
        Error::Api(409)
    );
    f.client.submit(&b.id, "independent").await.unwrap();
    assert_eq!(
        terminal(&f.client, &b.id).await.operation.unwrap().state,
        OperationState::Completed
    );
    let mut observer = f.client.events(&a.id, CancellationToken::new());
    observer.next().await.unwrap().unwrap();
    drop(observer);
    assert_eq!(
        f.client.get(&a.id).await.unwrap().operation.unwrap().state,
        OperationState::Running
    );
    assert_eq!(
        f.client.steer(&a.id, &new_id(), "stale").await.unwrap_err(),
        Error::Api(409)
    );
    let steered = f.client.steer(&a.id, &op, "new direction").await.unwrap();
    assert_eq!(steered["operationID"], op);
    assert_eq!(f.client.get(&a.id).await.unwrap().pending_input.len(), 1);
    f.client.cancel(&a.id, &op).await.unwrap();
    let interrupted = terminal(&f.client, &a.id).await;
    assert_eq!(
        interrupted.operation.unwrap().state,
        OperationState::Interrupted
    );
    assert_eq!(interrupted.messages.last().unwrap().text(), "partial");
    assert_eq!(p.count(), 2);
    f.service.close().await.unwrap();
}
async fn approval_case(approved: bool) {
    let executed = Arc::new(AtomicUsize::new(0));
    let counter = executed.clone();
    let f = setup(
        FakeProvider::new(vec![
            response(vec![call("call-1"), ProviderEvent::Done]),
            answer(),
        ]),
        vec![tool(Some("Exact test effect"), move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
            async { Ok("done".into()) }
        })],
    )
    .await;
    let c = f
        .client
        .create_with_settings(
            "fake",
            f.root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    f.client.submit(&c.id, "Act").await.unwrap();
    let pending = until_api(&f.client, &c.id, |s| s.approval.is_some()).await;
    let a = pending.approval.unwrap();
    assert_eq!(executed.load(Ordering::SeqCst), 0);
    assert_eq!(a.description, "Exact test effect");
    assert_eq!(
        f.client.get(&c.id).await.unwrap().operation.unwrap().state,
        OperationState::AwaitingApproval
    );
    let mut reconnect = f.client.events(&c.id, CancellationToken::new());
    let initial = snapshot(reconnect.next().await.unwrap().unwrap()).unwrap();
    drop(reconnect);
    assert_eq!(initial.approval.unwrap().id, a.id);
    assert!(initial.active_tool_call_id.is_none());
    for (action, body) in [
        (
            "cancel",
            json!({"operationID":a.operation_id,"unexpected":true}),
        ),
        (
            "approvals",
            json!({"operationID":a.operation_id,"approvalID":a.id,"approved":true,"unexpected":true}),
        ),
    ] {
        assert_eq!(
            f.client
                .call(
                    "POST",
                    &format!("/v1/conversations/{}/{action}", c.id),
                    Some(body)
                )
                .await
                .unwrap_err(),
            Error::Api(400)
        );
    }
    assert_eq!(
        f.client.get(&c.id).await.unwrap().approval.unwrap().id,
        a.id
    );
    assert_eq!(
        f.client
            .approve(&c.id, &new_id(), &a.id, true)
            .await
            .unwrap_err(),
        Error::Api(409)
    );
    assert_eq!(
        f.client
            .approve(&c.id, &a.operation_id, &new_id(), true)
            .await
            .unwrap_err(),
        Error::Api(409)
    );
    f.client
        .approve(&c.id, &a.operation_id, &a.id, approved)
        .await
        .unwrap();
    assert_eq!(
        f.client
            .approve(&c.id, &a.operation_id, &a.id, true)
            .await
            .unwrap_err(),
        Error::Api(409)
    );
    let final_state = terminal(&f.client, &c.id).await;
    assert!(final_state.messages.iter().any(|m|matches!(m,Message::Tool{outcome,..} if *outcome==if approved{ToolOutcome::Completed}else{ToolOutcome::Denied})));
    assert_eq!(executed.load(Ordering::SeqCst), usize::from(approved));
    f.service.close().await.unwrap();
}
#[tokio::test]
async fn api_approval_exact_single_use_executes() {
    approval_case(true).await;
}
#[tokio::test]
async fn api_approval_exact_single_use_denies() {
    approval_case(false).await;
}
#[tokio::test]
async fn shutdown_persists_pending_approval_without_execution_or_restart() {
    let root = directory();
    let p=FakeProvider::new(vec![response(vec![ProviderEvent::ToolCall(ToolCall{id:"write".into(),name:"edit_file".into(),arguments:json!({"path":"must-not-exist.txt","expected_revision":"new","old_text":"","new_text":"test"}).as_object().unwrap().clone()}),ProviderEvent::Done])]);
    let service = start_persistent_service(root.path(), p.clone(), true)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    let c = client
        .create_with_settings(
            "fake",
            root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    client.submit(&c.id, "Write").await.unwrap();
    until_api(&client, &c.id, |s| s.approval.is_some()).await;
    service.close().await.unwrap();
    let service = start_persistent_service(root.path(), p.clone(), true)
        .await
        .unwrap();
    let restored = client.get(&c.id).await.unwrap();
    assert_eq!(
        restored.operation.unwrap().state,
        OperationState::Interrupted
    );
    assert!(restored.approval.is_none());
    assert_eq!(p.count(), 1);
    assert!(!root.path().join("must-not-exist.txt").exists());
    service.close().await.unwrap();
}
#[tokio::test]
async fn http_validation_rejects_malformed_unknown_browser_origin_without_inference() {
    let p = FakeProvider::new(vec![]);
    let f = setup(p.clone(), vec![]).await;
    let root = f.root.path().to_str().unwrap();
    assert_eq!(
        f.client.create("fake", "relative").await.unwrap_err(),
        Error::Api(400)
    );
    assert_eq!(
        f.client
            .call(
                "POST",
                "/v1/conversations",
                Some(json!({"model":"fake","workspace":root,"apiKey":"never-read"}))
            )
            .await
            .unwrap_err(),
        Error::Api(400)
    );
    assert_eq!(f.client.get("bad/id").await.unwrap_err(), Error::Api(400));
    assert_eq!(f.client.get(&new_id()).await.unwrap_err(), Error::Api(404));
    assert_eq!(
        f.client
            .call("POST", "/v1/conversations", Some(json!({"model":"fake"})))
            .await
            .unwrap_err(),
        Error::Api(400)
    );
    let c = f.client.create("fake", root).await.unwrap();
    assert_eq!(
        f.client.submit(&c.id, " ").await.unwrap_err(),
        Error::Api(400)
    );
    assert_eq!(
        f.client
            .call(
                "POST",
                &format!("/v1/conversations/{}/approvals", c.id),
                Some(json!({"operationID":new_id(),"approvalID":new_id(),"approved":"true"}))
            )
            .await
            .unwrap_err(),
        Error::Api(400)
    );
    let raw = reqwest::Client::builder()
        .unix_socket(profile_socket(f.root.path()))
        .no_proxy()
        .build()
        .unwrap();
    assert_eq!(
        raw.get("http://localhost/v1/health")
            .header("Origin", "https://example.com")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        raw.post("http://localhost/v1/conversations")
            .header("Content-Type", "application/json")
            .body("{malformed")
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    assert_eq!(
        raw.post("http://localhost/v1/conversations")
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        415
    );
    assert_eq!(p.count(), 0);
    f.service.close().await.unwrap();
}
#[tokio::test]
async fn socket_directory_refuses_insecure_permissions_symlinks_existing_endpoints() {
    let root = directory();
    let insecure = root.path().join("public");
    fs::create_dir(&insecure).unwrap();
    fs::set_permissions(&insecure, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(private_directory(&insecure).await.is_err());
    let link = root.path().join("link");
    symlink(&insecure, &link).unwrap();
    assert!(private_directory(&link).await.is_err());
    let socket = profile_socket(root.path());
    fs::write(&socket, "do not replace").unwrap();
    let manager = Arc::new(AgentManager::default());
    assert!(
        start_service(ServiceOptions {
            manager: manager.clone(),
            provider: FakeProvider::new(vec![]),
            tools: vec![],
            socket_path: socket.clone()
        })
        .await
        .is_err()
    );
    manager.close().await.unwrap();
    assert_eq!(fs::read_to_string(socket).unwrap(), "do not replace");
}
struct Failing;
#[async_trait::async_trait]
impl ChatProvider for Failing {
    fn stream(&self, _: ProviderRequest) -> BoxStream<'static, exec_agent::Result<ProviderEvent>> {
        Box::pin(futures_util::stream::once(async {
            Err(Error::Tool("synthetic-private-error".into()))
        }))
    }
    async fn models(&self, _: CancellationToken) -> exec_agent::Result<Vec<ChatModel>> {
        Err(Error::Tool("synthetic-private-error".into()))
    }
}
#[tokio::test]
async fn discovery_and_provider_failures_do_not_leak_internal_credentials() {
    let f = setup(Arc::new(Failing), vec![]).await;
    assert_eq!(f.client.models().await.unwrap_err(), Error::Api(500));
    let c = f
        .client
        .create_with_settings(
            "fake",
            f.root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    f.client.submit(&c.id, "Fail once").await.unwrap();
    let failed = terminal(&f.client, &c.id).await;
    assert_eq!(
        failed.operation.as_ref().unwrap().state,
        OperationState::Failed
    );
    assert!(
        !serde_json::to_string(&failed)
            .unwrap()
            .contains("synthetic-private-error")
    );
    f.service.close().await.unwrap();
}
#[tokio::test]
async fn terminal_renderer_reconciles_snapshot_deltas_escapes_controls() {
    let p = FakeProvider::new(vec![response(vec![
        ProviderEvent::Text("Hello 🌍".into()),
        ProviderEvent::Done,
    ])]);
    let c = conversation(p, vec![]);
    let (initial, mut events) = c.subscribe();
    let mut transcript = Transcript::default();
    let mut output = transcript.snapshot(&initial);
    complete(c.submit("Hi".into()).unwrap()).await;
    while let Ok(frame) = events.try_recv() {
        output.push_str(&transcript.frame(&frame));
    }
    output.push_str(&transcript.snapshot(&c.snapshot()));
    assert_eq!(output.matches("Hello 🌍").count(), 1);
    assert_eq!(
        terminal_text("\x1b]52;c;clipboard\x07\r\u{202e}evil"),
        "\\u{1b}]52;c;clipboard\\u{7}\\u{d}\\u{202e}evil"
    );
}
async fn cli(root: &std::path::Path, args: &[&str]) -> std::process::Output {
    tokio::time::timeout(
        Duration::from_secs(5),
        tokio::process::Command::new(env!("CARGO_BIN_EXE_exec-agent"))
            .arg("--profile")
            .arg(root)
            .args(args)
            .kill_on_drop(true)
            .output(),
    )
    .await
    .unwrap()
    .unwrap()
}
#[tokio::test]
async fn real_cli_creates_sends_lists_resumes_only_through_service() {
    let f = setup(FakeProvider::new(vec![answer(), answer()]), vec![]).await;
    let output = cli(
        f.root.path(),
        &["new", "fake", f.root.path().to_str().unwrap()],
    )
    .await;
    assert!(output.status.success());
    let created: ConversationSnapshot = serde_json::from_slice(&output.stdout).unwrap();
    assert!(created.configuration.settings.auto_approve);
    let configured = cli(
        f.root.path(),
        &["configure", &created.id, "manual", "Concise answers"],
    )
    .await;
    assert!(configured.status.success());
    let configured: ConversationSnapshot = serde_json::from_slice(&configured.stdout).unwrap();
    assert!(!configured.configuration.settings.auto_approve);
    assert_eq!(
        configured.configuration.settings.system_prompt,
        "Concise answers"
    );
    let manual = cli(
        f.root.path(),
        &["new", "fake", f.root.path().to_str().unwrap(), "--manual"],
    )
    .await;
    assert!(manual.status.success());
    let manual: ConversationSnapshot = serde_json::from_slice(&manual.stdout).unwrap();
    assert!(!manual.configuration.settings.auto_approve);
    assert!(
        cli(f.root.path(), &["delete", &manual.id])
            .await
            .status
            .success()
    );
    let output = cli(f.root.path(), &["send", &created.id, "Hi"]).await;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("Completed answer"));
    assert_eq!(
        serde_json::from_slice::<Value>(&cli(f.root.path(), &["list"]).await.stdout).unwrap()[0]["id"],
        created.id
    );
    let resumed: ConversationSnapshot =
        serde_json::from_slice(&cli(f.root.path(), &["show", &created.id]).await.stdout).unwrap();
    assert_eq!(resumed.operation.unwrap().state, OperationState::Completed);
    assert!(
        cli(f.root.path(), &["send", &created.id, "Continue"])
            .await
            .status
            .success()
    );
    assert!(
        String::from_utf8_lossy(&cli(f.root.path(), &["chat", &created.id]).await.stderr)
            .contains("interactive terminal")
    );
    assert!(
        String::from_utf8_lossy(
            &cli(
                f.root.path(),
                &["new", "fake", f.root.path().to_str().unwrap(), "unexpected"]
            )
            .await
            .stderr
        )
        .contains("Invalid command arguments")
    );
    f.service.close().await.unwrap();
}
#[tokio::test]
async fn service_shutdown_aborts_inference_disconnects_observers_without_retries() {
    let entered = CancellationToken::new();
    let p = FakeProvider::new(vec![waiting(entered.clone())]);
    let f = setup(p.clone(), vec![]).await;
    let c = f
        .client
        .create_with_settings(
            "fake",
            f.root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    f.client.submit(&c.id, "Wait").await.unwrap();
    entered.cancelled().await;
    let mut events = f.client.events(&c.id, CancellationToken::new());
    events.next().await.unwrap().unwrap();
    tokio::time::timeout(Duration::from_secs(5), f.service.close())
        .await
        .unwrap()
        .unwrap();
    assert!(events.next().await.unwrap().is_err());
    assert!(p.requests.lock().unwrap()[0].cancel.is_cancelled());
    assert_eq!(p.count(), 1);
}
#[tokio::test]
async fn lost_mutation_responses_never_replayed_and_client_errors_hide_raw_bodies() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let root = directory();
    let listener = tokio::net::UnixListener::bind(profile_socket(root.path())).unwrap();
    let attempts = Arc::new(AtomicUsize::new(0));
    let count = attempts.clone();
    let server = tokio::spawn(async move {
        for index in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            count.fetch_add(1, Ordering::SeqCst);
            let mut request = vec![];
            loop {
                let mut chunk = [0; 4096];
                let size = socket.read(&mut chunk).await.unwrap();
                if size == 0 {
                    break;
                }
                request.extend_from_slice(&chunk[..size]);
                if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&request[..end]).to_lowercase();
                    let length = headers
                        .lines()
                        .find_map(|l| {
                            l.strip_prefix("content-length:")
                                .map(|s| s.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            if index == 1 {
                let body = "{\"error\":\"synthetic-secret\"}";
                socket.write_all(format!("HTTP/1.1 500 Internal Server Error\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await.unwrap();
            }
        }
    });
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    assert!(
        client
            .submit(&new_id(), "Once only")
            .await
            .unwrap_err()
            .to_string()
            .contains("may have taken effect")
    );
    assert_eq!(attempts.load(Ordering::SeqCst), 1);
    assert_eq!(client.health().await.unwrap_err(), Error::Api(500));
    assert_eq!(attempts.load(Ordering::SeqCst), 2);
    server.await.unwrap();
}
#[tokio::test]
async fn attached_client_receives_live_deltas_before_terminal_completion() {
    let finish = CancellationToken::new();
    let held = finish.clone();
    let p = FakeProvider::new(vec![script(move |r| {
        Box::pin(
            async_stream::try_stream! {yield ProviderEvent::Text("Live 🌍".into());tokio::select!{_=held.cancelled()=>{},_=r.cancel.cancelled()=>{}}yield ProviderEvent::Done;},
        )
    })]);
    let f = setup(p, vec![]).await;
    let c = f
        .client
        .create_with_settings(
            "fake",
            f.root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    let mut events = f.client.events(&c.id, CancellationToken::new());
    assert!(matches!(
        events.next().await.unwrap().unwrap(),
        ServiceEvent::Snapshot { .. }
    ));
    f.client.submit(&c.id, "Stream now").await.unwrap();
    let delta = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let ServiceEvent::Runtime {
                event:
                    RuntimeEvent {
                        kind: EventKind::Text { delta, .. },
                        ..
                    },
                ..
            } = events.next().await.unwrap().unwrap()
            {
                break delta;
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(delta, "Live 🌍");
    assert_eq!(
        f.client.get(&c.id).await.unwrap().operation.unwrap().state,
        OperationState::Running
    );
    finish.cancel();
    let final_state = terminal(&f.client, &c.id).await;
    assert_eq!(final_state.messages.last().unwrap().text(), delta);
    drop(events);
    f.service.close().await.unwrap();
}
#[tokio::test]
async fn api_tool_entry_reconnect_cancel_acceptance_and_settled_results() {
    let cleanup = CancellationToken::new();
    let held = cleanup.clone();
    let p = FakeProvider::new(vec![response(vec![call("effect-1"), ProviderEvent::Done])]);
    let f = setup(
        p.clone(),
        vec![tool(Some("Exact action"), move |_| {
            let held = held.clone();
            async move {
                held.cancelled().await;
                Ok("settled".into())
            }
        })],
    )
    .await;
    let c = f
        .client
        .create_with_settings(
            "fake",
            f.root.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    let op = f.client.submit(&c.id, "Act").await.unwrap();
    let pending = until_api(&f.client, &c.id, |s| s.approval.is_some()).await;
    let mut observer = f.client.events(&c.id, CancellationToken::new());
    observer.next().await.unwrap().unwrap();
    f.client
        .approve(&c.id, &op, &pending.approval.unwrap().id, true)
        .await
        .unwrap();
    let current = until_api(&f.client, &c.id, |s| s.active_tool_call_id.is_some()).await;
    assert_eq!(current.active_tool_call_id.as_deref(), Some("effect-1"));
    assert!(current.approval.is_none());
    assert_eq!(
        f.client.cancel(&c.id, &op).await.unwrap(),
        json!({"accepted":true,"operationID":op})
    );
    let cancelling = f.client.get(&c.id).await.unwrap();
    assert_eq!(
        cancelling.operation.unwrap().state,
        OperationState::Cancelling
    );
    assert_eq!(cancelling.active_tool_call_id.as_deref(), Some("effect-1"));
    assert_eq!(
        f.client.submit(&c.id, "Too early").await.unwrap_err(),
        Error::Api(409)
    );
    cleanup.cancel();
    let mut starts = 0;
    let mut finishes = 0;
    let final_state = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let frame = observer.next().await.unwrap().unwrap();
            if let ServiceEvent::Runtime {
                event,
                snapshot: Some(snapshot),
            } = &frame
            {
                match &event.kind {
                    EventKind::ToolStarted { .. } => {
                        starts += 1;
                        assert_eq!(snapshot.active_tool_call_id.as_deref(), Some("effect-1"));
                    }
                    EventKind::ToolFinished {
                        call_id,
                        message_id,
                        outcome,
                    } => {
                        finishes += 1;
                        assert!(snapshot.active_tool_call_id.is_none());
                        assert_eq!(call_id, "effect-1");
                        assert_eq!(*outcome, ToolOutcome::Interrupted);
                        assert!(snapshot.messages.iter().any(|m| m.id() == message_id));
                        assert_eq!(event.operation_id, op);
                    }
                    _ => {}
                }
            }
            if let Some(s) = snapshot(frame)
                && s.operation
                    .as_ref()
                    .is_some_and(|o| o.state == OperationState::Interrupted)
            {
                break s;
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(starts, 1);
    assert_eq!(finishes, 1);
    assert!(final_state.active_tool_call_id.is_none());
    assert_eq!(p.count(), 1);
    assert_eq!(
        f.client.cancel(&c.id, &op).await.unwrap_err(),
        Error::Api(409)
    );
    drop(observer);
    f.service.close().await.unwrap();
}
