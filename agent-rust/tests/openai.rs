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
    HttpResponse {
        status: 200,
        content_type: Some("text/event-stream".into()),
        body: Box::pin(stream::iter([Ok(bytes::Bytes::from(text))])),
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
