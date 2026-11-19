//! Fake-transport regressions only; no provider calls or real credential reads.
use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use exec_agent::{
    Error, ProviderFailure, Result,
    core::{AuthenticationChallenge, ChatProvider, ConnectionMethod},
    providers::{
        HttpResponse,
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
    io::Write,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tempfile::TempDir;
use tokio::{sync::oneshot, task::JoinHandle, time::Instant};
use tokio_util::sync::CancellationToken;

fn private_directory() -> TempDir {
    let root = tempfile::tempdir().unwrap();
    std::fs::set_permissions(root.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    root
}

struct Fake {
    requests: Mutex<Vec<(Instant, Request)>>,
    send: Box<dyn Fn(Request) -> BoxFuture<'static, Result<HttpResponse>> + Send + Sync>,
}
impl Fake {
    fn new<F, Fut>(send: F) -> Arc<Self>
    where
        F: Fn(Request) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<HttpResponse>> + Send + 'static,
    {
        Arc::new(Self {
            requests: Mutex::new(vec![]),
            send: Box::new(move |request| Box::pin(send(request))),
        })
    }
    fn exchanges(&self) -> usize {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, r)| matches!(r.endpoint, Endpoint::Token))
            .count()
    }
}
#[async_trait]
impl Transport for Fake {
    async fn send(&self, request: Request, _: CancellationToken) -> Result<HttpResponse> {
        self.requests
            .lock()
            .unwrap()
            .push((Instant::now(), request.clone()));
        (self.send)(request).await
    }
}
fn raw(status: u16, body: impl Into<bytes::Bytes>) -> HttpResponse {
    HttpResponse {
        status,
        content_type: Some("application/json".into()),
        body: Box::pin(stream::iter([Ok(body.into())])),
    }
}
fn response(value: Value) -> HttpResponse {
    raw(200, value.to_string())
}
fn user_code() -> Value {
    json!({"device_auth_id":"synthetic-device-id", "user_code":"ABCD-EFGH", "interval":"2"})
}
fn approved() -> Value {
    json!({"authorization_code":"synthetic-authorization-code", "code_verifier":"v".repeat(43)})
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}
fn access(account: &str) -> String {
    format!(
        "e30.{}.synthetic",
        B64.encode(
            json!({"https://api.openai.com/auth":{"chatgpt_account_id":account}}).to_string()
        )
    )
}
fn claims() -> Value {
    json!({"iss":"https://auth.openai.com", "aud":CLIENT_ID, "exp":now()+3600,
        "nbf":now()-1, "sub":"synthetic-subject",
        "https://api.openai.com/auth":{"chatgpt_account_id":"synthetic-account"}})
}
fn tokens(id: String) -> Value {
    json!({"access_token":access("synthetic-account"), "refresh_token":"synthetic-refresh",
        "token_type":"Bearer", "expires_in":3600, "id_token":id})
}
// Like the existing OIDC regression, OpenSSL only generates/signs an isolated test key.
struct Signer {
    _root: TempDir,
    key: PathBuf,
    keys: Value,
}
impl Signer {
    fn new() -> Self {
        let root = private_directory();
        let key = root.path().join("synthetic.pem");
        assert!(
            Command::new("openssl")
                .args(["genrsa", "-out"])
                .arg(&key)
                .arg("2048")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success()
        );
        let modulus = Command::new("openssl")
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
        let keys = json!({"keys":[{"kid":"synthetic", "kty":"RSA", "alg":"RS256", "use":"sig", "n":B64.encode(n), "e":"AQAB"}]});
        Self {
            _root: root,
            key,
            keys,
        }
    }
    fn sign(&self, claims: &Value) -> String {
        let input = format!(
            "{}.{}",
            B64.encode(json!({"alg":"RS256", "kid":"synthetic"}).to_string()),
            B64.encode(claims.to_string())
        );
        let mut child = Command::new("openssl")
            .args(["dgst", "-sha256", "-sign"])
            .arg(&self.key)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        format!("{input}.{}", B64.encode(output.stdout))
    }
}
fn successful(tokens: Value, keys: Value) -> Arc<Fake> {
    Fake::new(move |request| {
        let value = match request.endpoint {
            Endpoint::DeviceUserCode => user_code(),
            Endpoint::DeviceToken => approved(),
            Endpoint::Token => tokens.clone(),
            Endpoint::Keys => keys.clone(),
            _ => panic!("Unexpected non-authentication request"),
        };
        async move { Ok(response(value)) }
    })
}
fn start(
    auth: Arc<Authentication>,
    cancel: CancellationToken,
) -> (
    JoinHandle<Result<()>>,
    oneshot::Receiver<AuthenticationChallenge>,
) {
    let (challenge, receive) = oneshot::channel();
    let task = tokio::spawn(async move {
        auth.connect(ConnectionMethod::DeviceCode, challenge, cancel)
            .await
    });
    (task, receive)
}

#[tokio::test(start_paused = true)]
async fn pending_then_success_verifies_identity_and_persists_once() {
    let root = private_directory();
    let path = root.path().join("credentials.json");
    std::fs::write(
        &path,
        br#"{"deepseek":{"apiKey":"synthetic-other-provider"}}"#,
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let signer = Signer::new();
    let id = signer.sign(&claims()); // Device identity legitimately has no nonce.
    assert!(verify_identity(&id, "browser-nonce", &signer.keys, now()).is_err());
    let keys = signer.keys.clone();
    let token_value = tokens(id);
    let polls = Arc::new(Mutex::new(0));
    let count = polls.clone();
    let transport = Fake::new(move |request| {
        let result = match request.endpoint {
            Endpoint::DeviceUserCode => response(user_code()),
            Endpoint::DeviceToken => {
                let mut count = count.lock().unwrap();
                *count += 1;
                match *count {
                    1 => raw(403, "pending"),
                    2 => raw(404, "pending"),
                    _ => response(approved()),
                }
            }
            Endpoint::Token => response(token_value.clone()),
            Endpoint::Keys => response(keys.clone()),
            _ => panic!("Unexpected non-authentication request"),
        };
        async move { Ok(result) }
    });
    let auth = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    let provider = OpenAIProvider::new(auth.clone(), transport.clone());
    let (send, receive) = oneshot::channel();
    let before = now();
    let task = tokio::spawn(async move {
        provider
            .connect(
                "openai",
                ConnectionMethod::DeviceCode,
                send,
                CancellationToken::new(),
            )
            .await
    });
    let challenge = receive.await.unwrap();
    assert_eq!(
        challenge.authorization_url,
        "https://auth.openai.com/codex/device"
    );
    let code = challenge.device_code.unwrap();
    assert_eq!(code.user_code, "ABCD-EFGH");
    assert!((before + 900..=now() + 900).contains(&code.expires_at));
    task.await.unwrap().unwrap();
    assert!(auth.connection().connected);
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(saved["openai"]["subject"], "synthetic-subject");
    assert_eq!(saved["deepseek"]["apiKey"], "synthetic-other-provider");
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(!saved.to_string().contains("synthetic-device-id"));
    let reopened = Authentication::open(path, None, transport.clone())
        .await
        .unwrap();
    assert_eq!(
        reopened
            .credentials(CancellationToken::new())
            .await
            .unwrap()
            .refresh_token,
        "synthetic-refresh"
    );
    assert_eq!(transport.exchanges(), 1);
    let requests = transport.requests.lock().unwrap();
    assert!(
        requests
            .iter()
            .all(|(_, r)| r.access.is_none() && r.account.is_none() && r.session_id.is_none())
    );
    assert_eq!(
        serde_json::from_str::<Value>(requests[0].1.body.as_ref().unwrap()).unwrap(),
        json!({"client_id":CLIENT_ID})
    );
    let polls: Vec<_> = requests
        .iter()
        .filter(|(_, r)| matches!(r.endpoint, Endpoint::DeviceToken))
        .collect();
    assert_eq!(polls.len(), 3);
    assert_eq!(polls[1].0 - polls[0].0, Duration::from_secs(2));
    assert_eq!(polls[2].0 - polls[1].0, Duration::from_secs(2));
    assert_eq!(
        serde_json::from_str::<Value>(polls[0].1.body.as_ref().unwrap()).unwrap(),
        json!({"device_auth_id":"synthetic-device-id", "user_code":"ABCD-EFGH"})
    );
    let exchange = requests
        .iter()
        .find(|(_, r)| matches!(r.endpoint, Endpoint::Token))
        .unwrap();
    let body = reqwest::Url::parse(&format!(
        "https://example.invalid/?{}",
        exchange.1.body.as_ref().unwrap()
    ))
    .unwrap();
    let fields: std::collections::HashMap<_, _> = body.query_pairs().collect();
    assert_eq!(
        fields["redirect_uri"],
        "https://auth.openai.com/deviceauth/callback"
    );
    assert_eq!(fields["grant_type"], "authorization_code");
    assert_eq!(fields["client_id"], CLIENT_ID);
    assert_eq!(fields["code"], "synthetic-authorization-code");
    assert_eq!(fields["code_verifier"], "v".repeat(43));
}

#[tokio::test(start_paused = true)]
async fn cancellation_stops_pending_polling_without_exchange_or_storage() {
    let root = private_directory();
    let path = root.path().join("credentials.json");
    let transport = Fake::new(|request| async move {
        match request.endpoint {
            Endpoint::DeviceUserCode => Ok(response(user_code())),
            Endpoint::DeviceToken => Ok(raw(403, "pending")),
            _ => panic!("Cancelled authentication must not exchange"),
        }
    });
    let auth = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    let cancel = CancellationToken::new();
    let (task, receive) = start(auth, cancel.clone());
    receive.await.unwrap();
    assert_eq!(transport.requests.lock().unwrap().len(), 2);
    cancel.cancel();
    assert!(matches!(task.await.unwrap(), Err(Error::Cancelled)));
    tokio::time::advance(Duration::from_secs(901)).await;
    assert_eq!(transport.requests.lock().unwrap().len(), 2);
    assert!(!path.exists());
}

#[tokio::test]
async fn cancellation_interrupts_issuance_and_in_flight_poll_requests() {
    for during_issuance in [true, false] {
        let root = private_directory();
        let path = root.path().join("credentials.json");
        let entered = CancellationToken::new();
        let signal = entered.clone();
        let transport = Fake::new(move |request| {
            let signal = signal.clone();
            async move {
                if !during_issuance && matches!(request.endpoint, Endpoint::DeviceUserCode) {
                    return Ok(response(user_code()));
                }
                signal.cancel();
                std::future::pending().await
            }
        });
        let auth = Authentication::open(path.clone(), None, transport.clone())
            .await
            .unwrap();
        let cancel = CancellationToken::new();
        let (task, _receive) = start(auth, cancel.clone());
        entered.cancelled().await;
        cancel.cancel();
        assert!(matches!(task.await.unwrap(), Err(Error::Cancelled)));
        assert_eq!(transport.exchanges(), 0);
        assert!(!path.exists());
    }
}

#[tokio::test]
async fn uncertain_code_exchange_is_never_retried_even_after_reopen() {
    let root = private_directory();
    let path = root.path().join("credentials.json");
    let transport = Fake::new(|request| async move {
        match request.endpoint {
            Endpoint::DeviceUserCode => Ok(response(user_code())),
            Endpoint::DeviceToken => Ok(response(approved())),
            Endpoint::Token => Err(Error::Provider(ProviderFailure::Transport)),
            _ => panic!("Failed exchange must not continue"),
        }
    });
    let auth = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    let (task, _receive) = start(auth, CancellationToken::new());
    assert!(matches!(
        task.await.unwrap(),
        Err(Error::Provider(ProviderFailure::Transport))
    ));
    let reopened = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    assert!(
        reopened
            .credentials(CancellationToken::new())
            .await
            .is_err()
    );
    assert_eq!(transport.exchanges(), 1);
    assert!(!path.exists());
}

#[tokio::test(start_paused = true)]
async fn pending_expires_at_fifteen_minutes_without_another_poll_or_exchange() {
    let root = private_directory();
    let path = root.path().join("credentials.json");
    let transport = Fake::new(|request| async move {
        match request.endpoint {
            Endpoint::DeviceUserCode => Ok(response(user_code())),
            Endpoint::DeviceToken => Ok(raw(404, "pending")),
            _ => panic!("Expired authentication must not exchange"),
        }
    });
    let auth = Authentication::open(path.clone(), None, transport.clone())
        .await
        .unwrap();
    let (task, receive) = start(auth, CancellationToken::new());
    receive.await.unwrap();
    tokio::time::advance(Duration::from_secs(900)).await;
    assert!(matches!(
        task.await.unwrap(),
        Err(Error::Provider(ProviderFailure::Timeout))
    ));
    assert_eq!(transport.requests.lock().unwrap().len(), 2);
    assert_eq!(transport.exchanges(), 0);
    assert!(!path.exists());
}

#[tokio::test]
async fn malformed_and_oversized_responses_never_reach_exchange() {
    let cases = [
        (
            true,
            json!({"device_auth_id":"", "user_code":"ABCD-EFGH"}).to_string(),
        ),
        (
            true,
            json!({"device_auth_id":"synthetic-id", "user_code":"bad\ncode"}).to_string(),
        ),
        (
            true,
            json!({"device_auth_id":"synthetic-id", "user_code":"ABCD-EFGH", "interval":"NaN"})
                .to_string(),
        ),
        (true, " ".repeat(16 * 1024 + 1)),
        (
            false,
            json!({"authorization_code":"", "code_verifier":"v".repeat(43)}).to_string(),
        ),
        (
            false,
            json!({"authorization_code":"synthetic", "code_verifier":"too-short"}).to_string(),
        ),
        (false, json!({"error":"authorization_pending"}).to_string()),
        (false, "not-json".into()),
        (false, " ".repeat(16 * 1024 + 1)),
    ];
    for (issuance, bad_body) in cases {
        let root = private_directory();
        let path = root.path().join("credentials.json");
        let transport = Fake::new(move |request| {
            let result = match request.endpoint {
                Endpoint::DeviceUserCode if issuance => raw(200, bad_body.clone()),
                Endpoint::DeviceUserCode => response(user_code()),
                Endpoint::DeviceToken => raw(200, bad_body.clone()),
                _ => panic!("Malformed authentication must not exchange"),
            };
            async move { Ok(result) }
        });
        let auth = Authentication::open(path.clone(), None, transport.clone())
            .await
            .unwrap();
        let (task, _receive) = start(auth, CancellationToken::new());
        assert!(matches!(
            task.await.unwrap(),
            Err(Error::Provider(ProviderFailure::Response))
        ));
        assert_eq!(transport.exchanges(), 0);
        assert!(!path.exists());
    }
}

#[tokio::test]
async fn only_poll_403_and_404_are_pending_and_status_errors_are_redacted() {
    for (issuance, status) in [
        (true, 403),
        (true, 404),
        (false, 400),
        (false, 401),
        (false, 429),
        (false, 500),
    ] {
        let root = private_directory();
        let path = root.path().join("credentials.json");
        let transport = Fake::new(move |request| async move {
            match request.endpoint {
                Endpoint::DeviceUserCode if !issuance => Ok(response(user_code())),
                Endpoint::DeviceUserCode | Endpoint::DeviceToken => Ok(raw(
                    status,
                    "synthetic-private-id https://example.invalid/private-link synthetic-token",
                )),
                _ => panic!("Status errors must not exchange"),
            }
        });
        let auth = Authentication::open(path.clone(), None, transport.clone())
            .await
            .unwrap();
        let (task, _receive) = start(auth, CancellationToken::new());
        let error = task.await.unwrap().unwrap_err().to_string();
        assert!(!error.contains("synthetic"));
        assert!(!error.contains("https://"));
        assert_eq!(
            transport.requests.lock().unwrap().len(),
            if issuance { 1 } else { 2 }
        );
        assert!(!path.exists());
    }
}

#[tokio::test]
async fn invalid_identity_and_account_switches_preserve_existing_private_storage() {
    let signer = Signer::new();
    for case in [
        "signature",
        "issuer",
        "audience",
        "expiry",
        "subject",
        "not_before",
        "identity_account",
        "switch_subject",
        "switch_account",
    ] {
        let root = private_directory();
        let path = root.path().join("credentials.json");
        let old = Session {
            access_token: access("synthetic-account"),
            refresh_token: "previous-refresh".into(),
            account_id: "synthetic-account".into(),
            subject: "synthetic-subject".into(),
            expires_at: now() + 3600,
            requires_reconnect: false,
        };
        let previous =
            json!({"openai":old, "deepseek":{"apiKey":"synthetic-other-provider"}}).to_string();
        std::fs::write(&path, &previous).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mut identity = claims();
        match case {
            "issuer" => identity["iss"] = json!("https://example.invalid"),
            "audience" => identity["aud"] = json!("another-client"),
            "expiry" => identity["exp"] = json!(now() - 1),
            "subject" => identity["sub"] = json!(""),
            "not_before" => identity["nbf"] = json!(now() + 3600),
            "identity_account" | "switch_account" => {
                identity["https://api.openai.com/auth"]["chatgpt_account_id"] =
                    json!("other-account")
            }
            "switch_subject" => identity["sub"] = json!("other-subject"),
            _ => {}
        }
        let mut id = signer.sign(&identity);
        if case == "signature" {
            id.push('x');
        }
        let mut value = tokens(id);
        if case == "switch_account" {
            value["access_token"] = json!(access("other-account"));
        }
        let transport = successful(value, signer.keys.clone());
        let auth = Authentication::open(path.clone(), None, transport.clone())
            .await
            .unwrap();
        let (task, _receive) = start(auth, CancellationToken::new());
        let error = task.await.unwrap().unwrap_err();
        if case.starts_with("switch_") {
            assert!(matches!(
                error,
                Error::Invalid("Disconnect before selecting another OpenAI account.")
            ));
        } else {
            assert!(
                matches!(error, Error::Provider(ProviderFailure::Authentication)),
                "{case}"
            );
        }
        assert_eq!(std::fs::read_to_string(&path).unwrap(), previous);
        assert_eq!(transport.exchanges(), 1);
    }
}
