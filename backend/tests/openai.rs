//! Isolated protocol/authentication regressions, not live-service verification.
mod support;
use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use exec_agent::{
    Error, ProviderFailure, Result,
    core::*,
    providers::{
        HttpResponse,
        credential_store::DeepSeekCredentials,
        openai::{
            OpenAIProvider,
            auth::{Authentication, CLIENT_ID, Session, verify_identity},
            transport::{Endpoint, Request, Transport},
        },
    },
};
use futures_util::{future::BoxFuture, stream};
use serde_json::{Value, json};
use std::{
    os::unix::fs::PermissionsExt,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};
use tokio_util::sync::CancellationToken;
struct Fake {
    requests: Mutex<Vec<Request>>,
    send: Arc<dyn Fn(Request) -> BoxFuture<'static, Result<HttpResponse>> + Send + Sync>,
}
impl Fake {
    fn new<F, Fut>(f: F) -> Arc<Self>
    where
        F: Fn(Request) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = Result<HttpResponse>> + Send + 'static,
    {
        Arc::new(Self {
            requests: Mutex::new(vec![]),
            send: Arc::new(move |r| Box::pin(f(r))),
        })
    }
}
#[async_trait]
impl Transport for Fake {
    async fn send(&self, request: Request, _: CancellationToken) -> Result<HttpResponse> {
        self.requests.lock().unwrap().push(request.clone());
        (self.send)(request).await
    }
}
fn response(value: Value) -> HttpResponse {
    HttpResponse {
        status: 200,
        content_type: Some("application/json".into()),
        body: Box::pin(stream::iter([Ok(bytes::Bytes::from(value.to_string()))])),
    }
}
fn wire(events: Vec<Value>) -> HttpResponse {
    let text = events
        .into_iter()
        .map(|v| format!("data: {v}\n\n"))
        .collect::<String>();
    raw_wire(text)
}
fn raw_wire(body: impl Into<bytes::Bytes>) -> HttpResponse {
    HttpResponse {
        status: 200,
        content_type: Some("text/event-stream".into()),
        body: Box::pin(stream::iter([Ok(body.into())])),
    }
}
fn access(account: &str) -> String {
    format!(
        "{}.{}.synthetic",
        B64.encode(br#"{"alg":"RS256"}"#),
        B64.encode(
            json!({"https://api.openai.com/auth":{"chatgpt_account_id":account}}).to_string()
        )
    )
}
fn session(expired: bool) -> Session {
    Session {
        access_token: access("synthetic-account"),
        refresh_token: "synthetic-refresh".into(),
        account_id: "synthetic-account".into(),
        subject: "synthetic-subject".into(),
        expires_at: if expired {
            1
        } else {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs()
                + 3600
        },
        requires_reconnect: false,
    }
}
fn save(path: &std::path::Path, value: &Session) {
    std::fs::write(
        path,
        json!({"deepseek":{"apiKey":"synthetic-deepseek"},"openai":value}).to_string(),
    )
    .unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}
#[tokio::test]
async fn automatic_titles_use_valid_openai_requests_without_polluting_chat_context() {
    let root = support::directory();
    let workspace = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(false));
    let transport = Fake::new(|request| async move {
        if matches!(request.endpoint, Endpoint::Models) {
            return Ok(response(
                json!({"models":[{"slug":"test","context_window":10000}]}),
            ));
        }
        assert!(matches!(request.endpoint, Endpoint::Responses));
        let body: Value = serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
        let input = body["input"].as_array().unwrap();
        let content = input.last().unwrap()["content"].as_str().unwrap();
        let text = if let Ok(fields) = serde_json::from_str::<Value>(content) {
            assert_eq!(input.len(), 1);
            assert_eq!(body["tools"], json!([]));
            match fields["latest_user_message"].as_str().unwrap() {
                "Plan a garden" => {
                    assert_eq!(fields["current_title"], "");
                    "Vegetable Garden Plan"
                }
                "Now plan a trip" => {
                    assert_eq!(fields["current_title"], "Vegetable Garden Plan");
                    "Weekend Travel Plan"
                }
                _ => panic!("Unexpected title request"),
            }
        } else {
            assert!(matches!(content, "Plan a garden" | "Now plan a trip"));
            assert!(!body["input"].to_string().contains("latest_user_message"));
            assert!(!body["input"].to_string().contains("Vegetable Garden Plan"));
            "Completed answer"
        };
        Ok(wire(vec![
            json!({"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":text}]}]}}),
        ]))
    });
    let auth = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    let provider = Arc::new(OpenAIProvider::new(auth, transport.clone()));
    let manager = exec_agent::manager::AgentManager::default();
    let conversation = manager
        .create(ConversationOptions::new(
            provider,
            "test",
            workspace.path().to_str().unwrap(),
        ))
        .await
        .unwrap();
    for (message, title) in [
        ("Plan a garden", "Vegetable Garden Plan"),
        ("Now plan a trip", "Weekend Travel Plan"),
    ] {
        let operation = support::complete(
            manager
                .submit(&conversation.id, message.into())
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(operation.state, OperationState::Completed);
        assert_eq!(
            conversation.snapshot().metadata.title.as_deref(),
            Some(title)
        );
    }
    assert_eq!(conversation.snapshot().messages.len(), 4);
    let requests = transport.requests.lock().unwrap();
    let inference: Vec<_> = requests
        .iter()
        .filter(|r| matches!(r.endpoint, Endpoint::Responses))
        .map(|r| serde_json::from_str::<Value>(r.body.as_ref().unwrap()).unwrap())
        .collect();
    assert_eq!(inference.len(), 4);
    assert_ne!(
        inference[0]["prompt_cache_key"],
        inference[1]["prompt_cache_key"]
    );
    assert_ne!(
        inference[0]["prompt_cache_key"],
        inference[2]["prompt_cache_key"]
    );
}

#[tokio::test]
async fn rotating_refresh_is_single_flight_and_persists_before_releasing_credentials() {
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(true));
    let check = path.clone();
    let transport = Fake::new(move |request| {
        let path = check.clone();
        async move {
            assert!(matches!(request.endpoint, Endpoint::Token));
            let saved: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
            assert_eq!(saved["openai"]["requiresReconnect"], true);
            assert!(request.body.unwrap().contains("grant_type=refresh_token"));
            Ok(response(
                json!({"access_token":access("synthetic-account"),"refresh_token":"rotated-once","expires_in":3600}),
            ))
        }
    });
    let auth = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    let (a, b) = tokio::join!(
        auth.credentials(CancellationToken::new()),
        auth.credentials(CancellationToken::new())
    );
    assert_eq!(a.unwrap().refresh_token, "rotated-once");
    assert_eq!(b.unwrap().refresh_token, "rotated-once");
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    let deepseek = DeepSeekCredentials::open(path.clone(), None).await.unwrap();
    deepseek.set(Some("updated-deepseek".into())).await.unwrap();
    let reopened = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    assert_eq!(
        reopened
            .credentials(CancellationToken::new())
            .await
            .unwrap()
            .refresh_token,
        "rotated-once"
    );
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    auth.settle().await;
    reopened.settle().await;
}
#[tokio::test]
async fn present_malformed_refresh_tokens_never_fall_back_to_the_consumed_token() {
    for refresh in [
        None,
        Some(Value::Null),
        Some(json!(42)),
        Some(json!(false)),
        Some(json!([])),
        Some(json!({})),
        Some(json!("")),
        Some(json!("invalid token")),
    ] {
        let root = support::directory();
        let path = root.path().join("credentials.json");
        save(&path, &session(true));
        let mut value = json!({"access_token":access("synthetic-account"),"expires_in":3600});
        let absent = refresh.is_none();
        if let Some(refresh) = refresh {
            value["refresh_token"] = refresh;
        }
        let transport = Fake::new(move |_| {
            let value = value.clone();
            async move { Ok(response(value)) }
        });
        let auth = Authentication::open(path.clone(), None, transport.clone())
            .await
            .unwrap();
        let result = auth.credentials(CancellationToken::new()).await;
        if absent {
            assert_eq!(result.unwrap().refresh_token, "synthetic-refresh");
        } else {
            assert!(matches!(
                result,
                Err(Error::Provider(ProviderFailure::Authentication))
            ));
            assert!(auth.credentials(CancellationToken::new()).await.is_err());
        }
        let reopened = Authentication::open(path.clone(), None, transport.clone())
            .await
            .unwrap();
        assert_eq!(reopened.connection().blocked, !absent);
        assert_eq!(
            reopened.credentials(CancellationToken::new()).await.is_ok(),
            absent
        );
        let saved: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(saved["openai"]["requiresReconnect"], !absent);
        assert_eq!(transport.requests.lock().unwrap().len(), 1);
        auth.settle().await;
        reopened.settle().await;
    }
}

#[tokio::test]
async fn independent_authentication_owners_reload_under_shared_ownership() {
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(true));
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let e = entered.clone();
    let r = release.clone();
    let transport = Fake::new(move |request| {
        let entered = e.clone();
        let release = r.clone();
        async move {
            if matches!(request.endpoint, Endpoint::Revoke) {
                assert!(request.body.unwrap().contains("token=shared-rotation"));
                return Ok(response(json!({})));
            }
            assert!(matches!(request.endpoint, Endpoint::Token));
            entered.cancel();
            release.cancelled().await;
            Ok(response(
                json!({"access_token":access("synthetic-account"),"refresh_token":"shared-rotation","expires_in":3600}),
            ))
        }
    });
    let first = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    let second = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    let a = {
        let auth = first.clone();
        tokio::spawn(async move { auth.credentials(CancellationToken::new()).await })
    };
    entered.cancelled().await;
    let b = {
        let auth = second.clone();
        tokio::spawn(async move { auth.credentials(CancellationToken::new()).await })
    };
    // A provider lease must not block the other provider's field updates.
    let deepseek = DeepSeekCredentials::open(path.clone(), None).await.unwrap();
    deepseek
        .set(Some("updated-during-refresh".into()))
        .await
        .unwrap();
    assert!(!b.is_finished());
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    release.cancel();
    assert_eq!(a.await.unwrap().unwrap().refresh_token, "shared-rotation");
    assert_eq!(b.await.unwrap().unwrap().refresh_token, "shared-rotation");
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    // A stale owner must not return a removed session or revoke an old token.
    first.disconnect().await.unwrap();
    assert!(second.credentials(CancellationToken::new()).await.is_err());
    let saved: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert!(saved.get("openai").is_none());
    assert_eq!(saved["deepseek"]["apiKey"], "updated-during-refresh");
    assert_eq!(transport.requests.lock().unwrap().len(), 2);
    first.settle().await;
    second.settle().await;
}

// Subprocess fixtures receive only a temporary path and synthetic credentials.
#[tokio::test]
async fn refresh_ownership_fixture() {
    let Some(path) = std::env::var_os("EXEC_TEST_REFRESH_OWNER_PATH") else {
        return;
    };
    let path = std::path::PathBuf::from(path);
    let root = path.parent().unwrap().to_owned();
    let crash = std::env::var_os("EXEC_TEST_REFRESH_OWNER_CRASH").is_some();
    let transport = Fake::new(move |request| {
        let root = root.clone();
        async move {
            assert!(matches!(request.endpoint, Endpoint::Token));
            tokio::fs::write(root.join("claimed"), b"ready")
                .await
                .unwrap();
            if crash {
                std::process::exit(0);
            }
            wait_for_fixture_file(&root.join("release")).await;
            Ok(response(
                json!({"access_token":access("synthetic-account"),"refresh_token":"process-rotation","expires_in":3600}),
            ))
        }
    });
    let auth = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    assert_eq!(
        auth.credentials(CancellationToken::new())
            .await
            .unwrap()
            .refresh_token,
        "process-rotation"
    );
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    auth.settle().await;
}
async fn wait_for_fixture_file(path: &std::path::Path) {
    tokio::time::timeout(std::time::Duration::from_secs(10), async {
        while !path.exists() {
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}
#[tokio::test]
async fn shared_credentials_exclude_other_processes_and_keep_crash_markers() {
    for crash in [false, true] {
        let root = support::directory();
        let path = root.path().join("credentials.json");
        save(&path, &session(true));
        let transport = Fake::new(|_| async { panic!("a second owner reused a rotating token") });
        // Load stale credentials before the other process claims its refresh.
        let auth = Authentication::open(path.clone(), None, transport.clone())
            .await
            .unwrap();
        let mut command = tokio::process::Command::new(std::env::current_exe().unwrap());
        command
            .args(["--exact", "refresh_ownership_fixture", "--nocapture"])
            .env_clear()
            .env("EXEC_TEST_REFRESH_OWNER_PATH", &path)
            .kill_on_drop(true);
        if crash {
            command.env("EXEC_TEST_REFRESH_OWNER_CRASH", "1");
        }
        let mut child = command.spawn().unwrap();
        wait_for_fixture_file(&root.path().join("claimed")).await;
        assert!(auth.credentials(CancellationToken::new()).await.is_err());
        let deepseek = DeepSeekCredentials::open(path.clone(), None).await.unwrap();
        deepseek
            .set(Some("shared-process-update".into()))
            .await
            .unwrap();
        tokio::fs::write(root.path().join("release"), b"ready")
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(10), child.wait())
                .await
                .unwrap()
                .unwrap()
                .success()
        );
        let result = auth.credentials(CancellationToken::new()).await;
        if crash {
            assert!(result.is_err());
            assert!(auth.connection().blocked);
        } else {
            assert_eq!(result.unwrap().refresh_token, "process-rotation");
        }
        let saved: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(saved["openai"]["requiresReconnect"], crash);
        assert_eq!(saved["deepseek"]["apiKey"], "shared-process-update");
        assert!(transport.requests.lock().unwrap().is_empty());
        auth.settle().await;
    }
}

#[tokio::test]
async fn ambiguous_refresh_blocks_reuse_across_restart_and_environment_never_rotates() {
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(true));
    let transport = Fake::new(|_| async { Err(Error::Provider(ProviderFailure::Transport)) });
    let auth = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    assert!(auth.credentials(CancellationToken::new()).await.is_err());
    assert!(auth.credentials(CancellationToken::new()).await.is_err());
    let reopened = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    assert!(
        reopened
            .credentials(CancellationToken::new())
            .await
            .is_err()
    );
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    assert!(reopened.connection().blocked);
    let external = Authentication::open(
        path,
        Some(serde_json::to_string(&session(true)).unwrap()),
        transport.clone(),
    )
    .await
    .unwrap();
    assert!(
        external
            .credentials(CancellationToken::new())
            .await
            .is_err()
    );
    assert!(external.disconnect().await.is_err());
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    auth.settle().await;
    reopened.settle().await;
    external.settle().await;
}
#[tokio::test]
async fn cancellation_detaches_from_rotation_but_shutdown_waits_for_its_persistence() {
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(true));
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let e = entered.clone();
    let r = release.clone();
    let transport = Fake::new(move |_| {
        let e = e.clone();
        let r = r.clone();
        async move {
            e.cancel();
            r.cancelled().await;
            Ok(response(
                json!({"access_token":access("synthetic-account"),"refresh_token":"retained-after-cancel","expires_in":3600}),
            ))
        }
    });
    let auth = Authentication::open(path.clone(), None, transport)
        .await
        .unwrap();
    let cancel = CancellationToken::new();
    let task = {
        let auth = auth.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move { auth.credentials(cancel).await })
    };
    entered.cancelled().await;
    cancel.cancel();
    assert!(matches!(task.await.unwrap(), Err(Error::Cancelled)));
    let settle = {
        let auth = auth.clone();
        tokio::spawn(async move { auth.settle().await })
    };
    tokio::task::yield_now().await;
    assert!(!settle.is_finished());
    release.cancel();
    settle.await.unwrap();
    let saved: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(saved["openai"]["refreshToken"], "retained-after-cancel");
    assert_eq!(saved["openai"]["requiresReconnect"], false);
}
#[tokio::test]
async fn responses_keep_encrypted_context_private_and_failures_never_release_calls() {
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(false));
    let count = Arc::new(AtomicUsize::new(0));
    let c = count.clone();
    let transport = Fake::new(move |request| {
        let n = c.fetch_add(1, Ordering::SeqCst);
        async move {
            if matches!(request.endpoint, Endpoint::Models) {
                return Ok(response(
                    json!({"models":[{"slug":"test","context_window":1000,"input_modalities":["text","image"]}]}),
                ));
            }
            assert!(matches!(request.endpoint, Endpoint::Responses));
            let body: Value = serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
            assert_eq!(body["store"], false);
            assert_eq!(body["include"], json!(["reasoning.encrypted_content"]));
            if n == 1 {
                Ok(wire(vec![
                    json!({"type":"response.output_text.delta","delta":"partial"}),
                    json!({"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":"opaque-never-in-ui"},{"type":"message","content":[{"type":"output_text","text":"Final answer"}]}],"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}),
                ]))
            } else {
                assert!(
                    body["input"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|v| v["encrypted_content"] == "opaque-never-in-ui")
                );
                Ok(wire(vec![
                    json!({"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"never-run","name":"change","arguments":"{}"}}),
                    json!({"type":"response.incomplete","response":{"status":"incomplete"}}),
                ]))
            }
        }
    });
    let auth = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    let p = Arc::new(OpenAIProvider::new(auth, transport));
    let mut options = support::options(
        p,
        vec![support::tool(None, |_| async {
            panic!("unfinished call executed")
        })],
    );
    options.model = "test".into();
    let conversation = Conversation::new(options, None).unwrap();
    assert_eq!(
        support::complete(conversation.submit("hello".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert_eq!(conversation.snapshot().messages[1].text(), "Final answer");
    assert_eq!(conversation.snapshot().context_usage.unwrap().limit, 1000);
    assert!(
        !serde_json::to_string(&conversation.snapshot())
            .unwrap()
            .contains("opaque-never-in-ui")
    );
    assert_eq!(
        support::complete(conversation.submit("again".into()).unwrap())
            .await
            .state,
        OperationState::Failed
    );
    assert!(support::outcomes(&conversation).is_empty());
}
async fn assert_response_failure(
    reply: HttpResponse,
    failure: ProviderFailure,
    partial_text: Option<&str>,
) {
    use futures_util::StreamExt;
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(false));
    let reply = Mutex::new(Some(reply));
    let transport = Fake::new(move |request| {
        assert!(matches!(request.endpoint, Endpoint::Responses));
        let reply = reply
            .lock()
            .unwrap()
            .take()
            .expect("Responses must not retry");
        async move { Ok(reply) }
    });
    let auth = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    let provider = OpenAIProvider::new(auth, transport.clone());
    let request = ProviderRequest {
        model: "test".into(),
        message_ids: vec![new_id()],
        incomplete_message_ids: Default::default(),
        messages: vec![ContextMessage::User {
            text: "synthetic user content".into(),
        }],
        images: Default::default(),
        instructions: String::new(),
        effort: None,
        provider_state: None,
        tools: vec![],
        cancel: CancellationToken::new(),
    };
    let events: Vec<_> = provider.stream(request).collect().await;
    // Only incremental text may escape a failed response, never calls, final
    // snapshots, opaque metadata, or Done. The error itself contains no wire text.
    let mut expected = Vec::new();
    if let Some(text) = partial_text {
        expected.push(Ok(ProviderEvent::Text(text.into())));
    }
    expected.push(Err(Error::Provider(failure)));
    assert_eq!(events, expected);
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn completed_empty_and_reasoning_only_responses_are_failures_not_noops() {
    for event_type in ["response.completed", "response.done"] {
        for output in [
            json!([]),
            json!([{"type":"reasoning","encrypted_content":"synthetic opaque reasoning"}]),
        ] {
            assert_response_failure(
                wire(vec![json!({"type":event_type,"response":{
                    "status":"completed","output":output,
                    "usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}
                }})]),
                ProviderFailure::EmptyResponse,
                None,
            )
            .await;
        }
    }
    // A streamed delta does not make an explicitly empty final output complete.
    assert_response_failure(
        wire(vec![
            json!({"type":"response.output_text.delta","delta":"synthetic partial"}),
            json!({"type":"response.completed","response":{"status":"completed","output":[]}}),
        ]),
        ProviderFailure::EmptyResponse,
        Some("synthetic partial"),
    )
    .await;
}

#[tokio::test]
async fn response_failure_events_withhold_staged_calls_and_metadata() {
    for (event_type, status, failure) in [
        (
            "response.incomplete",
            "incomplete",
            ProviderFailure::IncompleteResponse,
        ),
        ("response.failed", "failed", ProviderFailure::FailedResponse),
        ("error", "failed", ProviderFailure::FailedResponse),
        (
            "response.done",
            "incomplete",
            ProviderFailure::IncompleteResponse,
        ),
        ("response.done", "failed", ProviderFailure::FailedResponse),
    ] {
        assert_response_failure(
            wire(vec![
                json!({"type":"response.output_text.delta","delta":"synthetic partial"}),
                json!({"type":"response.output_item.done","output_index":0,"item":{
                    "type":"function_call","call_id":"never-release","name":"shell","arguments":"{}"
                }}),
                json!({"type":event_type,"response":{
                    "status":status,
                    "incomplete_details":{"reason":"synthetic private reason"},
                    "error":{"code":"rate_limit_exceeded","message":"synthetic private provider text"}
                },"message":"synthetic private provider text"}),
            ]),
            failure,
            Some("synthetic partial"),
        )
        .await;
    }
}

#[tokio::test]
async fn response_eof_framing_and_content_type_failures_are_distinct() {
    assert_response_failure(wire(vec![]), ProviderFailure::StreamEnded, None).await;
    assert_response_failure(
        wire(vec![
            json!({"type":"response.output_text.delta","delta":"synthetic partial"}),
            json!({"type":"response.output_item.done","output_index":0,"item":{
                "type":"function_call","call_id":"never-release","name":"shell","arguments":"{}"
            }}),
        ]),
        ProviderFailure::StreamEnded,
        Some("synthetic partial"),
    )
    .await;
    // An unterminated SSE event is not dispatched or treated as EOF completion.
    assert_response_failure(
        raw_wire("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n"),
        ProviderFailure::StreamEnded,
        None,
    )
    .await;
    for body in [
        b"data: {synthetic malformed JSON}\n\n".as_slice(),
        b"data: \xff\n\n".as_slice(),
        b"data: \xff".as_slice(),
    ] {
        assert_response_failure(raw_wire(body), ProviderFailure::MalformedResponse, None).await;
    }
    assert_response_failure(
        response(json!({"error":{"message":"synthetic private provider text"}})),
        ProviderFailure::UnexpectedContentType,
        None,
    )
    .await;
    // Keep size limits and ordinary shape validation generic.
    assert_response_failure(
        raw_wire(format!("data: {}\n\n", "x".repeat(5 * 1024 * 1024))),
        ProviderFailure::Response,
        None,
    )
    .await;
    assert_response_failure(
        wire(vec![json!({"type":"response.completed","response":{
            "status":"completed","output":{}
        }})]),
        ProviderFailure::Response,
        None,
    )
    .await;
}

#[tokio::test]
async fn missing_response_content_type_still_requires_a_valid_completed_stream() {
    for (content_type, completed, expected) in [
        (None, true, OperationState::Completed),
        (None, false, OperationState::Failed),
        (Some("text/html"), true, OperationState::Failed),
        (
            Some("Text/Event-Stream; charset=utf-8"),
            true,
            OperationState::Completed,
        ),
    ] {
        let root = support::directory();
        let path = root.path().join("credentials.json");
        save(&path, &session(false));
        let transport = Fake::new(move |request| async move {
            if matches!(request.endpoint, Endpoint::Models) {
                return Ok(response(
                    json!({"models":[{"slug":"test","context_window":1000}]}),
                ));
            }
            assert!(matches!(request.endpoint, Endpoint::Responses));
            let mut events = vec![json!({"type":"response.output_text.delta","delta":"OK"})];
            if completed {
                events.push(json!({"type":"response.completed","response":{"status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"OK"}]}]}}));
            }
            let mut result = wire(events);
            result.content_type = content_type.map(str::to_owned);
            Ok(result)
        });
        let auth = Authentication::open(path, None, transport.clone())
            .await
            .unwrap();
        let provider = Arc::new(OpenAIProvider::new(auth, transport.clone()));
        let mut options = support::options(provider, vec![]);
        options.model = "test".into();
        let conversation = Conversation::new(options, None).unwrap();
        assert_eq!(
            support::complete(conversation.submit("hello".into()).unwrap())
                .await
                .state,
            expected
        );
        assert_eq!(
            transport
                .requests
                .lock()
                .unwrap()
                .iter()
                .filter(|r| matches!(r.endpoint, Endpoint::Responses))
                .count(),
            1
        );
    }
}

#[test]
fn oidc_signature_and_claims_are_verified_with_an_isolated_generated_key() {
    // OpenSSL is a test-fixture generator only, not an application dependency.
    let root = support::directory();
    let key = root.path().join("test.pem");
    let status = std::process::Command::new("openssl")
        .args(["genrsa", "-out"])
        .arg(&key)
        .arg("2048")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    let modulus = std::process::Command::new("openssl")
        .args(["rsa", "-in"])
        .arg(&key)
        .args(["-modulus", "-noout"])
        .output()
        .unwrap();
    assert!(modulus.status.success());
    let hex = String::from_utf8(modulus.stdout).unwrap();
    let hex = hex.trim().strip_prefix("Modulus=").unwrap();
    let n: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect();
    let jwks = json!({"keys":[{"kid":"test","kty":"RSA","alg":"RS256","use":"sig","n":B64.encode(n),"e":"AQAB"}]});
    let claims = json!({"iss":"https://auth.openai.com","aud":CLIENT_ID,"exp":1000,"nbf":1,"nonce":"nonce","sub":"synthetic-subject"});
    let signed = format!(
        "{}.{}",
        B64.encode(json!({"alg":"RS256","kid":"test"}).to_string()),
        B64.encode(claims.to_string())
    );
    let input = root.path().join("input");
    std::fs::write(&input, &signed).unwrap();
    let signature = std::process::Command::new("openssl")
        .args(["dgst", "-sha256", "-sign"])
        .arg(key)
        .arg(input)
        .output()
        .unwrap();
    assert!(signature.status.success());
    let jwt = format!("{signed}.{}", B64.encode(signature.stdout));
    assert_eq!(
        verify_identity(&jwt, "nonce", &jwks, 10).unwrap().0,
        "synthetic-subject"
    );
    assert!(verify_identity(&jwt, "wrong", &jwks, 10).is_err());
    assert!(verify_identity(&jwt, "nonce", &jwks, 1000).is_err());
    let altered = jwt.replacen(".", ".x", 1);
    assert!(verify_identity(&altered, "nonce", &jwks, 10).is_err());
}

#[tokio::test]
async fn openai_services_and_compaction_use_separate_context_and_keep_only_compaction_items() {
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(false));
    let transport = Fake::new(|request| async move {
        match request.endpoint {
            Endpoint::Usage => Ok(response(
                json!({"rate_limit":{"primary_window":{"used_percent":25.0,"limit_window_seconds":18000,"reset_at":1900000000}}}),
            )),
            Endpoint::Images => {
                let body: Value = serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
                assert_eq!(body["model"], "gpt-image-2");
                assert_eq!(body["background"], "transparent");
                use base64::engine::general_purpose::STANDARD;
                let mut bytes = std::io::Cursor::new(Vec::new());
                image::DynamicImage::new_rgb8(2, 2)
                    .write_to(&mut bytes, image::ImageFormat::Png)
                    .unwrap();
                Ok(response(
                    json!({"data":[{"b64_json":STANDARD.encode(bytes.into_inner())}]}),
                ))
            }
            Endpoint::Responses => {
                let body: Value = serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
                let output = if body["tool_choice"] == "required" {
                    assert_eq!(body["tools"][0]["type"], "web_search");
                    json!([{"type":"web_search_call","status":"completed","action":{"sources":[{"title":"Source","url":"https://example.com/"}]}},{"type":"message","content":[{"type":"output_text","text":"Sourced answer"}]}])
                } else if body["input"].as_array().unwrap().last().unwrap()["type"]
                    == "compaction_trigger"
                {
                    json!([{"type":"compaction","encrypted_content":"opaque-summary"},{"type":"function_call","call_id":"must-not-execute","name":"change","arguments":"{}"}])
                } else {
                    let input = body["input"].as_array().unwrap();
                    assert_eq!(input.len(), 2);
                    assert_eq!(input[0]["encrypted_content"], "opaque-summary");
                    assert_eq!(input[1]["content"], "new input");
                    json!([{"type":"message","content":[{"type":"output_text","text":"After compaction"}]}])
                };
                Ok(wire(vec![
                    json!({"type":"response.completed","response":{"status":"completed","output":output}}),
                ]))
            }
            _ => panic!("Unexpected provider request"),
        }
    });
    let auth = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    let p = OpenAIProvider::new(auth, transport.clone());
    let search = p
        .search_web("test", "public query".into(), CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(search.sources[0].url, "https://example.com/");
    assert_eq!(
        p.account_usage("openai", CancellationToken::new())
            .await
            .unwrap()
            .windows[0]
            .used_percent,
        25.0
    );
    assert!(
        !p.generate_image(
            ImageGeneration {
                prompt: "small cat".into(),
                transparent_background: true
            },
            CancellationToken::new()
        )
        .await
        .unwrap()
        .bytes
        .is_empty()
    );
    let mut request = ProviderRequest {
        model: "test".into(),
        message_ids: vec![new_id(), new_id()],
        incomplete_message_ids: Default::default(),
        messages: vec![
            ContextMessage::User {
                text: "original".into(),
            },
            ContextMessage::Assistant {
                text: "answer".into(),
                calls: vec![],
            },
        ],
        images: Default::default(),
        instructions: String::new(),
        effort: None,
        provider_state: None,
        tools: vec![],
        cancel: CancellationToken::new(),
    };
    let compacted = p.compact(request.clone()).await.unwrap();
    assert_eq!(compacted["prefix"]["output"].as_array().unwrap().len(), 1);
    assert!(!compacted.to_string().contains("must-not-execute"));
    request.provider_state = Some(compacted);
    request.message_ids.push(new_id());
    request.messages.push(ContextMessage::User {
        text: "new input".into(),
    });
    use futures_util::StreamExt;
    let events: Vec<_> = p.stream(request).collect().await;
    assert!(events.iter().all(Result::is_ok));
    assert!(matches!(events.last(), Some(Ok(ProviderEvent::Done))));
    assert_eq!(transport.requests.lock().unwrap().len(), 5);
}

#[tokio::test]
async fn idle_and_active_forks_keep_compaction_without_replaying_omitted_live_work() {
    use exec_agent::{
        manager::AgentManager, providers::ProviderRegistry, storage::JsonConversationStore,
    };

    for pending_tool in [false, true] {
        let root = support::directory();
        let workspace = support::directory();
        let path = root.path().join("credentials.json");
        save(&path, &session(false));
        let entered = CancellationToken::new();
        let signal = entered.clone();
        let transport = Fake::new(move |request| {
            let entered = signal.clone();
            async move {
                if matches!(request.endpoint, Endpoint::Models) {
                    return Ok(response(
                        json!({"models":[{"slug":"test","context_window":1000}]}),
                    ));
                }
                assert!(matches!(request.endpoint, Endpoint::Responses));
                let body: Value = serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
                let input = body["input"].as_array().unwrap();
                if input.last().unwrap()["type"] == "compaction_trigger" {
                    return Ok(wire(vec![json!({"type":"response.completed","response":{
                        "status":"completed","output":[{"type":"compaction","encrypted_content":"saved-summary"}]
                    }})]));
                }
                let question = input
                    .iter()
                    .rev()
                    .find(|item| item["role"] == "user")
                    .unwrap()["content"]
                    .as_str()
                    .unwrap();
                if question != "Original lengthy history" {
                    assert_eq!(input[0]["encrypted_content"], "saved-summary");
                    assert!(
                        !body["input"]
                            .to_string()
                            .contains("Original lengthy history")
                    );
                }
                if matches!(question, "Short idle question" | "Short active question") {
                    assert!(
                        input
                            .iter()
                            .any(|item| item["encrypted_content"] == "retained-reasoning")
                    );
                    assert!(!body["input"].to_string().contains("omitted-live-work"));
                }
                if question == "Hold source" {
                    if pending_tool {
                        return Ok(wire(vec![json!({"type":"response.completed","response":{
                            "status":"completed","output":[
                                {"type":"reasoning","encrypted_content":"omitted-live-work"},
                                {"type":"function_call","call_id":"omitted-live-work","name":"change","arguments":"{}"}
                            ],"usage":{"input_tokens":350,"output_tokens":10,"total_tokens":360}
                        }})]));
                    }
                    return Ok(HttpResponse {
                        status: 200,
                        content_type: Some("text/event-stream".into()),
                        body: Box::pin(async_stream::try_stream! {
                            yield bytes::Bytes::from("data: {\"type\":\"response.output_text.delta\",\"delta\":\"omitted-live-work\"}\n\n");
                            entered.cancel();
                            std::future::pending::<()>().await;
                        }),
                    });
                }
                let tokens = if question.starts_with("Short ") {
                    365
                } else {
                    360
                };
                Ok(wire(vec![json!({"type":"response.completed","response":{
                    "status":"completed","output":[
                        {"type":"reasoning","encrypted_content":"retained-reasoning"},
                        {"type":"message","content":[{"type":"output_text","text":"Completed answer"}]}
                    ],"usage":{"input_tokens":tokens-10,"output_tokens":10,"total_tokens":tokens}
                }})]))
            }
        });
        let auth = Authentication::open(path, None, transport.clone())
            .await
            .unwrap();
        let provider = Arc::new(
            ProviderRegistry::new(
                "openai",
                vec![(
                    "openai".into(),
                    Arc::new(OpenAIProvider::new(auth, transport.clone())),
                )],
            )
            .unwrap(),
        );
        let signal = entered.clone();
        let tools = vec![support::tool(None, move |context| {
            let entered = signal.clone();
            async move {
                entered.cancel();
                context.cancel.cancelled().await;
                Err(Error::Cancelled)
            }
        })];
        let profile = root.path().join("profile");
        let manager =
            AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
                (provider.clone(), tools.clone())
            })
            .await
            .unwrap();
        let mut options = ConversationOptions::new(
            provider.clone(),
            "openai/test",
            workspace.path().to_str().unwrap(),
        );
        options.tools = tools.clone();
        let source = manager.create(options).await.unwrap();
        assert_eq!(
            support::complete(source.submit("Original lengthy history".into()).unwrap())
                .await
                .state,
            OperationState::Completed
        );
        assert_eq!(
            support::complete(source.compact().unwrap()).await.state,
            OperationState::Completed
        );
        assert_eq!(
            support::complete(source.submit("After compaction".into()).unwrap())
                .await
                .state,
            OperationState::Completed
        );
        assert_eq!(source.snapshot().context_usage.unwrap().tokens, 360);
        let original = source.record();
        let idle_fork = manager
            .fork(&source.id, provider.clone(), tools.clone())
            .await
            .unwrap();
        assert_eq!(idle_fork.record().provider_state, original.provider_state);
        assert_eq!(
            idle_fork.snapshot().context_usage,
            source.snapshot().context_usage
        );
        assert_eq!(
            support::complete(idle_fork.submit("Short idle question".into()).unwrap())
                .await
                .state,
            OperationState::Completed
        );
        assert_eq!(idle_fork.snapshot().context_usage.unwrap().tokens, 365);
        assert_eq!(source.record(), original);

        let run = source.submit("Hold source".into()).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(3), entered.cancelled())
            .await
            .unwrap();
        assert_eq!(source.snapshot().context_usage.unwrap().tokens, 360);
        let original = source.record();
        let fork = manager
            .fork(&source.id, provider.clone(), tools.clone())
            .await
            .unwrap();
        fork.record().validate().unwrap();
        let fork_state = fork.record().provider_state.unwrap();
        assert_eq!(
            fork_state["contexts"]["openai"]["prefix"],
            original.provider_state.as_ref().unwrap()["contexts"]["openai"]["prefix"]
        );
        assert!(fork_state.to_string().contains("retained-reasoning"));
        assert!(!fork_state.to_string().contains("omitted-live-work"));
        assert!(
            !serde_json::to_string(&fork.snapshot())
                .unwrap()
                .contains("omitted-live-work")
        );
        assert_eq!(source.record(), original);
        assert!(source.cancel(&run.operation_id));
        assert_eq!(
            support::complete(run).await.state,
            OperationState::Interrupted
        );
        manager.close().await.unwrap();

        let manager =
            AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
                (provider.clone(), tools.clone())
            })
            .await
            .unwrap();
        let fork = manager.get(&fork.id).unwrap();
        assert_eq!(fork.record().provider_state, Some(fork_state));
        assert_eq!(
            support::complete(fork.submit("Short active question".into()).unwrap())
                .await
                .state,
            OperationState::Completed
        );
        let usage = fork.snapshot().context_usage.unwrap();
        assert_eq!((usage.tokens, usage.limit), (365, 1000));
        manager.close().await.unwrap();
    }
}

#[tokio::test]
async fn recovered_incomplete_reply_does_not_replay_completed_opaque_output() {
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(false));
    let transport = Fake::new(|request| async move {
        if matches!(request.endpoint, Endpoint::Models) {
            return Ok(response(
                json!({"models":[{"slug":"fake","context_window":10000}]}),
            ));
        }
        Ok(wire(vec![json!({"type":"response.completed","response":{
            "status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Partial attempt"}]}]
        }})]))
    });
    let auth = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    let provider = Arc::new(OpenAIProvider::new(auth, transport.clone()));
    let c = support::conversation(provider.clone(), vec![]);
    support::complete(c.submit("first".into()).unwrap()).await;
    // Older runtimes could checkpoint opaque metadata before finalizing the reply.
    let mut record = c.record();
    let Message::Assistant { status, .. } = &mut record.messages[1] else {
        panic!()
    };
    *status = MessageStatus::Streaming;
    record.operation.as_mut().unwrap().state = OperationState::Running;
    let recovered = Conversation::new(support::options(provider, vec![]), Some(record)).unwrap();
    assert_eq!(
        support::complete(recovered.submit("Continue explicitly".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    let requests = transport.requests.lock().unwrap();
    let body: Value =
        serde_json::from_str(requests.last().unwrap().body.as_ref().unwrap()).unwrap();
    let text = body["input"][1]["content"].as_str().unwrap();
    assert!(
        text.contains("was interrupted before completion") && text.ends_with("Partial attempt")
    );
    assert_eq!(body["input"].as_array().unwrap().len(), 3);
}

#[tokio::test]
async fn legacy_compaction_supplements_incomplete_replies_until_recompacted() {
    use futures_util::StreamExt;
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(false));
    let transport = Fake::new(|request| async move {
        let body: Value = serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
        let output =
            if body["input"].as_array().unwrap().last().unwrap()["type"] == "compaction_trigger" {
                json!([{"type":"compaction","encrypted_content":"opaque-summary"}])
            } else {
                json!([{"type":"message","content":[{"type":"output_text","text":"answer"}]}])
            };
        Ok(wire(vec![
            json!({"type":"response.completed","response":{"status":"completed","output":output}}),
        ]))
    });
    let auth = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    let provider = OpenAIProvider::new(auth, transport.clone());
    let mut request = ProviderRequest {
        model: "test".into(),
        message_ids: vec![new_id(), new_id(), new_id()],
        incomplete_message_ids: Default::default(),
        messages: vec![
            ContextMessage::User {
                text: "first".into(),
            },
            ContextMessage::User {
                text: "next".into(),
            },
            ContextMessage::Assistant {
                text: "answer".into(),
                calls: vec![],
            },
        ],
        images: Default::default(),
        instructions: String::new(),
        effort: None,
        provider_state: None,
        tools: vec![],
        cancel: CancellationToken::new(),
    };
    let mut legacy = provider.compact(request.clone()).await.unwrap();
    legacy["prefix"]
        .as_object_mut()
        .unwrap()
        .remove("includes_incomplete");
    request.provider_state = Some(legacy);
    let failed = Message::Assistant {
        id: new_id(),
        text: "Partial attempt".into(),
        calls: vec![],
        status: MessageStatus::Failed,
    };
    request
        .incomplete_message_ids
        .insert(failed.id().to_owned());
    request.message_ids.insert(1, failed.id().to_owned());
    request.messages.insert(1, context(&[failed]).remove(0));
    request.message_ids.push(new_id());
    request.messages.push(ContextMessage::User {
        text: "new input".into(),
    });
    let events: Vec<_> = provider.stream(request.clone()).collect().await;
    assert!(events.iter().all(Result::is_ok));
    let compacted = provider.compact(request.clone()).await.unwrap();
    assert_eq!(compacted["prefix"]["includes_incomplete"], true);
    request.provider_state = Some(compacted);
    request.message_ids.push(new_id());
    request.messages.push(ContextMessage::User {
        text: "latest input".into(),
    });
    let events: Vec<_> = provider.stream(request).collect().await;
    assert!(events.iter().all(Result::is_ok));
    let requests = transport.requests.lock().unwrap();
    let bodies: Vec<Value> = requests
        .iter()
        .map(|r| serde_json::from_str(r.body.as_ref().unwrap()).unwrap())
        .collect();
    for body in &bodies[1..3] {
        assert_eq!(body["input"][0]["encrypted_content"], "opaque-summary");
        assert!(
            body["input"][1]["content"]
                .as_str()
                .unwrap()
                .contains("failed before completion")
        );
        assert_eq!(body["input"][2]["content"], "new input");
    }
    assert_eq!(bodies[3]["input"].as_array().unwrap().len(), 2);
    assert_eq!(bodies[3]["input"][1]["content"], "latest input");
}

#[tokio::test]
async fn failed_refresh_intent_save_prevents_exchange_and_workspace_changes_are_rejected() {
    for storage_failure in [true, false] {
        let root = support::directory();
        let path = root.path().join("credentials.json");
        save(&path, &session(true));
        let transport = Fake::new(|_| async {
            Ok(response(
                json!({"access_token":access("different-workspace"),"refresh_token":"rotated","expires_in":3600}),
            ))
        });
        let auth = Authentication::open(path.clone(), None, transport.clone())
            .await
            .unwrap();
        if storage_failure {
            std::fs::remove_file(&path).unwrap();
            std::fs::create_dir(&path).unwrap();
        }
        assert!(auth.credentials(CancellationToken::new()).await.is_err());
        assert!(auth.credentials(CancellationToken::new()).await.is_err());
        assert_eq!(
            transport.requests.lock().unwrap().len(),
            usize::from(!storage_failure)
        );
        auth.settle().await;
    }
}
#[tokio::test]
async fn disconnect_accepts_empty_revocation_response_clears_model_cache_and_preserves_deepseek() {
    let root = support::directory();
    let path = root.path().join("credentials.json");
    save(&path, &session(false));
    let transport = Fake::new(|request| async move {
        match request.endpoint {
            Endpoint::Models => Ok(response(
                json!({"models":[{"slug":"model","context_window":100}]}),
            )),
            Endpoint::Revoke => Ok(HttpResponse {
                status: 204,
                content_type: None,
                body: Box::pin(stream::empty()),
            }),
            _ => panic!("unexpected request"),
        }
    });
    let auth = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    let provider = OpenAIProvider::new(auth, transport.clone());
    provider.models(CancellationToken::new()).await.unwrap();
    assert_eq!(provider.context_window("model"), Some(100));
    provider.set_credential("openai", None).await.unwrap();
    assert_eq!(provider.context_window("model"), None);
    let saved: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert!(saved.get("openai").is_none());
    assert_eq!(saved["deepseek"]["apiKey"], "synthetic-deepseek");
    assert_eq!(transport.requests.lock().unwrap().len(), 2);
}
