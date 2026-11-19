#![cfg(unix)]

use axum::{
    Router,
    body::{Body, to_bytes},
    extract::State,
    http::{Request, Response},
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    fs::File,
    io::{Read, Write},
    os::fd::{AsRawFd, FromRawFd},
    process::{ExitStatus, Output, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{io::AsyncWriteExt, process::Command};

const TOKEN: &str = "abababababababababababababababababababababababababababababababab";
const ATTEMPT: &str = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
const OTHER: &str = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb";
const PRIVATE: &str = "synthetic-private-value@example.invalid";

#[derive(Clone)]
struct Seen {
    method: String,
    path: String,
    authorization: String,
    body: Value,
}
#[derive(Default)]
struct Reply {
    status: u16,
    body: String,
    location: Option<String>,
    delay: Duration,
    fail_body: bool,
}
impl Reply {
    fn json(value: Value) -> Self {
        Self {
            status: 200,
            body: value.to_string(),
            ..Self::default()
        }
    }
    fn error(status: u16) -> Self {
        Self {
            status,
            body: PRIVATE.into(),
            ..Self::default()
        }
    }
    fn delayed(mut self) -> Self {
        self.delay = Duration::from_millis(200);
        self
    }
    fn unreadable(mut self) -> Self {
        self.fail_body = true;
        self
    }
}
#[derive(Default)]
struct Requests {
    seen: Vec<Seen>,
    replies: VecDeque<Reply>,
}
struct Fake {
    port: u16,
    profile: tempfile::TempDir,
    requests: Arc<Mutex<Requests>>,
    task: tokio::task::JoinHandle<()>,
}
impl Fake {
    async fn new(replies: Vec<Reply>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(Requests {
            seen: vec![],
            replies: replies.into(),
        }));
        let app = Router::new().fallback(respond).with_state(requests.clone());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            port,
            profile: tempfile::tempdir().unwrap(),
            requests,
            task,
        }
    }
    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_exec-agent-admin"));
        command
            .args(args)
            .env_clear()
            .env("HOME", self.profile.path())
            .env("EXEC_AGENT_PROFILE", self.profile.path())
            .env("EXEC_AGENT_TOKEN", TOKEN)
            .env("EXEC_AGENT_PORT", self.port.to_string())
            .current_dir(self.profile.path())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        command
    }
    async fn run(&self, args: &[&str]) -> Output {
        tokio::time::timeout(Duration::from_secs(8), self.command(args).output())
            .await
            .unwrap()
            .unwrap()
    }
    fn seen(&self) -> Vec<Seen> {
        self.requests.lock().unwrap().seen.clone()
    }
    async fn wait_for_requests(&self, count: usize) {
        tokio::time::timeout(Duration::from_secs(4), async {
            while self.seen().len() < count {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }
}
impl Drop for Fake {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn respond(
    State(state): State<Arc<Mutex<Requests>>>,
    request: Request<Body>,
) -> Response<Body> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 16384).await.unwrap();
    let seen = Seen {
        method: parts.method.to_string(),
        path: parts.uri.to_string(),
        authorization: parts
            .headers
            .get("authorization")
            .and_then(|s| s.to_str().ok())
            .unwrap_or("")
            .into(),
        body: if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap()
        },
    };
    let reply = {
        let mut state = state.lock().unwrap();
        state.seen.push(seen);
        state
            .replies
            .pop_front()
            .unwrap_or_else(|| Reply::error(500))
    };
    tokio::time::sleep(reply.delay).await;
    let mut response = Response::builder()
        .status(reply.status)
        .header("content-type", "application/json");
    if let Some(location) = reply.location {
        response = response.header("location", location);
    }
    let body = if reply.fail_body {
        Body::from_stream(futures_util::stream::once(async {
            Err::<bytes::Bytes, _>(std::io::Error::other("synthetic body read failure"))
        }))
    } else {
        Body::from(reply.body)
    };
    response.body(body).unwrap()
}
fn rows(connected: bool) -> Value {
    json!([{"id":"deepseek","name":PRIVATE,"connected":connected,"source":"json","manageable":true,"blocked":false,
        "email":PRIVATE,"accountID":PRIVATE,"token":PRIVATE},
        {"id":"openai","name":"OpenAI","connected":false,"source":"environment","manageable":false,"blocked":true,"email":PRIVATE}])
}
fn remote() -> Value {
    json!({"enabled":true,"relay":"wss://relay.example.invalid","localDevelopment":false,"connected":true,
        "connectionStatus":"connected","invitationActive":false,"devices":[{"id":OTHER,"name":PRIVATE}],"token":PRIVATE})
}
fn attempt(id: &str, state: &str) -> Value {
    json!({"id":id,"provider":"openai","state":state,"error":PRIVATE,"email":PRIVATE})
}
fn challenge() -> Value {
    use exec_agent::core::{ConnectionAttempt, ConnectionChallenge, DeviceCodeChallenge};
    serde_json::to_value(ConnectionChallenge {
        attempt: ConnectionAttempt {
            id: ATTEMPT.into(),
            provider: "openai".into(),
            state: "running".into(),
            error: Some(PRIVATE.into()),
        },
        authorization_url: "https://example.invalid/synthetic-login".into(),
        device_code: Some(DeviceCodeChallenge {
            user_code: "TEST-CODE".into(),
            expires_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs()
                + 120,
        }),
    })
    .unwrap()
}
fn no_secrets(output: &Output) {
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!text.contains(PRIVATE));
    assert!(!text.contains(TOKEN));
}
fn projected(output: &Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    no_secrets(output);
    serde_json::from_slice(&output.stdout).unwrap()
}

#[tokio::test]
async fn arguments_and_noninteractive_secrets_fail_before_requests() {
    let fake = Fake::new(vec![Reply::json(challenge())]).await;
    for args in [
        vec!["health", "extra"],
        vec!["--url", "https://untrusted.invalid", "health"],
        vec!["providers", "disconnect", "openai/../../remote"],
        vec![
            "providers",
            "connect",
            "deepseek",
            "synthetic-key-as-argument",
        ],
        vec![
            "providers",
            "connect",
            "deepseek",
            "--key",
            "synthetic-key-as-argument",
        ],
        vec!["providers", "connect", "deepseek"],
        vec!["providers", "connect", "openai"],
        vec!["providers", "connect", "openai", "--device-code"],
        vec!["remote", "invite"],
        vec!["remote", "revoke", "../untrusted"],
        vec!["remote", "configure", "--disable"],
        vec![
            "remote",
            "configure",
            "--relay",
            "wss://user:secret@untrusted.invalid",
        ],
        vec!["remote", "configure", "--relay", "wss://relay.invalid/path"],
        vec![
            "remote",
            "configure",
            "--relay",
            "wss://relay.invalid?token=synthetic-secret",
        ],
        vec!["remote", "configure", "--relay", "ws://127.0.0.1:1234"],
        vec![
            "remote",
            "configure",
            "--relay",
            "ws://public.invalid",
            "--local-development",
        ],
        vec![
            "remote",
            "configure",
            "--relay",
            "wss://relay.invalid",
            "--disable",
            "--disable",
        ],
    ] {
        let output = fake.run(&args).await;
        assert!(!output.status.success(), "{args:?}");
        assert!(output.stdout.is_empty());
        no_secrets(&output);
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(!error.contains("synthetic-key-as-argument"));
        assert!(!error.contains("synthetic-secret"));
        assert!(!error.contains("synthetic-login"));
        assert!(!error.contains("TEST-CODE"));
    }
    for args in [["help"], ["--help"]] {
        assert!(fake.run(&args).await.status.success());
    }
    let invalid_port = fake
        .command(&["health"])
        .env("EXEC_AGENT_PORT", "http://untrusted.invalid")
        .output()
        .await
        .unwrap();
    assert!(!invalid_port.status.success());
    assert!(fake.seen().is_empty());
}

#[tokio::test]
async fn health_and_provider_operations_use_http_and_project_no_accounts() {
    let fake = Fake::new(vec![
        Reply::json(json!({"version":1,"toolsEnabled":true,"token":PRIVATE})),
        Reply::json(rows(false)),
        Reply::json(rows(false)),
        Reply::json(rows(true)),
        Reply::json(rows(false)),
    ])
    .await;
    assert_eq!(
        projected(&fake.run(&["health"]).await),
        json!({"version":1,"toolsEnabled":true})
    );
    for command in ["list", "status"] {
        let status = projected(&fake.run(&["providers", command]).await);
        assert_eq!(
            status[0],
            json!({"id":"deepseek","name":"DeepSeek","connected":false,"source":"json","manageable":true,"blocked":false})
        );
        assert_eq!(status[1]["source"], "environment");
        assert_eq!(status[1]["manageable"], false);
        assert_eq!(status[1]["blocked"], true);
    }
    let mut child = fake
        .command(&["providers", "connect", "deepseek", "--key-stdin"])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"synthetic-stdin-key\n")
        .await
        .unwrap();
    let output = tokio::time::timeout(Duration::from_secs(8), child.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(projected(&output)[0]["connected"], true);
    assert!(!String::from_utf8_lossy(&output.stdout).contains("synthetic-stdin-key"));
    assert_eq!(
        projected(&fake.run(&["providers", "disconnect", "deepseek"]).await)[0]["connected"],
        false
    );
    let seen = fake.seen();
    assert_eq!(
        seen.iter()
            .map(|s| (s.method.as_str(), s.path.as_str()))
            .collect::<Vec<_>>(),
        vec![
            ("GET", "/v1/health"),
            ("GET", "/v1/providers"),
            ("GET", "/v1/providers"),
            ("PUT", "/v1/providers/deepseek"),
            ("DELETE", "/v1/providers/deepseek")
        ]
    );
    assert_eq!(seen[3].body, json!({"apiKey":"synthetic-stdin-key"}));
    assert!(
        seen.iter()
            .all(|s| s.authorization == format!("Bearer {TOKEN}"))
    );
    assert!(!fake.profile.path().join("credentials.json").exists());
}

#[tokio::test]
async fn stdin_key_is_bounded_and_exactly_one_token() {
    let fake = Fake::new(vec![]).await;
    for input in [
        vec![],
        b"first\nsecond\n".to_vec(),
        vec![b'x'; 8195],
        b"one\x1btwo".to_vec(),
    ] {
        let mut child = fake
            .command(&["providers", "connect", "deepseek", "--key-stdin"])
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&input).await.unwrap();
        let output = tokio::time::timeout(Duration::from_secs(8), child.wait_with_output())
            .await
            .unwrap()
            .unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        no_secrets(&output);
    }
    assert!(fake.seen().is_empty());
}

#[tokio::test]
async fn remote_status_configuration_and_revocation_project_only_pairing_ids() {
    let fake = Fake::new((0..4).map(|_| Reply::json(remote())).collect()).await;
    assert_eq!(
        projected(&fake.run(&["remote", "status"]).await)["devices"],
        json!([{"id":OTHER}])
    );
    projected(
        &fake
            .run(&[
                "remote",
                "configure",
                "--relay",
                "wss://relay.example.invalid",
                "--disable",
            ])
            .await,
    );
    projected(
        &fake
            .run(&[
                "remote",
                "configure",
                "--local-development",
                "--relay",
                "ws://127.0.0.1:9000",
            ])
            .await,
    );
    projected(&fake.run(&["remote", "revoke", OTHER]).await);
    let seen = fake.seen();
    assert_eq!(seen[1].method, "PUT");
    assert_eq!(seen[1].path, "/v1/remote");
    assert_eq!(
        seen[1].body,
        json!({"relay":"wss://relay.example.invalid","enabled":false,"localDevelopment":false})
    );
    assert_eq!(
        seen[2].body,
        json!({"relay":"ws://127.0.0.1:9000","enabled":true,"localDevelopment":true})
    );
    assert_eq!(seen[3].method, "DELETE");
    assert_eq!(seen[3].path, format!("/v1/remote/devices/{OTHER}"));
}

#[tokio::test]
async fn no_proxies_redirects_mutation_retries_or_raw_errors() {
    let trap = Fake::new(vec![]).await;
    let proxy = format!("http://127.0.0.1:{}", trap.port);
    let fake = Fake::new(vec![
        Reply::json(json!({"version":1,"toolsEnabled":false})),
        Reply {
            status: 307,
            body: PRIVATE.into(),
            location: Some(format!("{proxy}/stolen")),
            ..Reply::default()
        },
        Reply::error(503),
        Reply {
            status: 200,
            body: PRIVATE.repeat(2500),
            ..Reply::default()
        },
    ])
    .await;
    let output = fake
        .command(&["health"])
        .env("HTTP_PROXY", &proxy)
        .env("HTTPS_PROXY", &proxy)
        .env("ALL_PROXY", &proxy)
        .env("http_proxy", &proxy)
        .env("https_proxy", &proxy)
        .env("all_proxy", &proxy)
        .env("NO_PROXY", "")
        .env("no_proxy", "")
        .env("EXEC_AGENT_URL", &proxy)
        .output()
        .await
        .unwrap();
    projected(&output);
    for args in [
        vec!["health"],
        vec!["providers", "disconnect", "openai"],
        vec!["health"],
    ] {
        let output = fake.run(&args).await;
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        no_secrets(&output);
        assert!(!String::from_utf8_lossy(&output.stderr).contains("http://"));
    }
    assert_eq!(fake.seen().len(), 4);
    assert_eq!(fake.seen()[2].method, "DELETE");
    assert!(trap.seen().is_empty());
}

#[tokio::test]
async fn shared_token_file_is_used_and_conflicting_token_sources_send_nothing() {
    use std::os::unix::fs::PermissionsExt;
    let fake = Fake::new(vec![Reply::json(json!({"version":1,"toolsEnabled":false}))]).await;
    let path = fake.profile.path().join("admin-token");
    std::fs::write(&path, format!("{TOKEN}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let output = fake
        .command(&["health"])
        .env("EXEC_AGENT_TOKEN_FILE", &path)
        .output()
        .await
        .unwrap();
    assert!(!output.status.success());
    no_secrets(&output);
    assert!(fake.seen().is_empty());
    let output = fake
        .command(&["health"])
        .env_remove("EXEC_AGENT_TOKEN")
        .env("EXEC_AGENT_TOKEN_FILE", &path)
        .output()
        .await
        .unwrap();
    projected(&output);
    assert_eq!(fake.seen()[0].authorization, format!("Bearer {TOKEN}"));
    assert_eq!(std::fs::read_to_string(path).unwrap(), format!("{TOKEN}\n"));
}

#[tokio::test]
async fn lost_mutation_response_is_not_retried() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::AsyncReadExt;
    let fake = Fake::new(vec![]).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let count = Arc::new(AtomicUsize::new(0));
    let received = count.clone();
    let task = tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            received.fetch_add(1, Ordering::SeqCst);
            let mut request = Vec::new();
            let mut buffer = [0u8; 1024];
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let n = stream.read(&mut buffer).await.unwrap();
                if n == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..n]);
                assert!(request.len() <= 16384);
            }
            // Drop the socket after receiving the mutation, without a response.
        }
    });
    let output = tokio::time::timeout(
        Duration::from_secs(8),
        fake.command(&["providers", "disconnect", "openai"])
            .env("EXEC_AGENT_PORT", port.to_string())
            .output(),
    )
    .await
    .unwrap()
    .unwrap();
    task.abort();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    no_secrets(&output);
    assert_eq!(count.load(Ordering::SeqCst), 1);
}

// A real pseudoterminal checks the TTY gates and echo restoration without a live provider.
struct TerminalChild {
    child: tokio::process::Child,
    master: File,
    slave: File,
    text: Vec<u8>,
}
fn pseudoterminal() -> (File, File) {
    let (mut master, mut slave) = (-1, -1);
    // SAFETY: openpty initializes both descriptors; no optional name/termios/winsize is supplied.
    assert_eq!(
        unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        },
        0
    );
    // SAFETY: descriptors returned by openpty are distinct, valid and owned here.
    let master = unsafe { File::from_raw_fd(master) };
    let slave = unsafe { File::from_raw_fd(slave) };
    for file in [&master, &slave] {
        // SAFETY: do not leak the test's original descriptors into subprocesses; stdio uses clones.
        assert_eq!(
            unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) },
            0
        );
    }
    // SAFETY: fcntl operates on the owned master descriptor. Nonblocking reads keep tests bounded.
    let flags = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(
        unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
        0
    );
    (master, slave)
}
fn echo(slave: &File) -> bool {
    let mut term = std::mem::MaybeUninit::uninit();
    // SAFETY: valid terminal descriptor and writable termios; read only after success.
    assert_eq!(
        unsafe { libc::tcgetattr(slave.as_raw_fd(), term.as_mut_ptr()) },
        0
    );
    unsafe { term.assume_init() }.c_lflag & libc::ECHO != 0
}
impl TerminalChild {
    fn spawn(mut command: Command) -> Self {
        let (master, slave) = pseudoterminal();
        let child = command
            .stdin(Stdio::from(slave.try_clone().unwrap()))
            .stdout(Stdio::from(slave.try_clone().unwrap()))
            .stderr(Stdio::from(slave.try_clone().unwrap()))
            .spawn()
            .unwrap();
        Self {
            child,
            master,
            slave,
            text: vec![],
        }
    }
    fn drain(&mut self) {
        let mut buffer = [0u8; 2048];
        loop {
            match self.master.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => self.text.extend_from_slice(&buffer[..n]),
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.raw_os_error() == Some(libc::EIO) =>
                {
                    break;
                }
                Err(e) => panic!("PTY read: {e}"),
            }
            assert!(self.text.len() <= 65536);
        }
    }
    async fn until(&mut self, needle: &str) {
        tokio::time::timeout(Duration::from_secs(4), async {
            loop {
                self.drain();
                if String::from_utf8_lossy(&self.text).contains(needle) {
                    break;
                }
                assert!(
                    self.child.try_wait().unwrap().is_none(),
                    "{}",
                    String::from_utf8_lossy(&self.text)
                );
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }
    fn signal(&self, signal: libc::c_int) {
        // SAFETY: signal only the isolated subprocess launched by this test, never its process group.
        assert_eq!(
            unsafe { libc::kill(self.child.id().unwrap() as libc::pid_t, signal) },
            0
        );
    }
    async fn finish(&mut self) -> (ExitStatus, String) {
        let status = tokio::time::timeout(Duration::from_secs(8), self.child.wait())
            .await
            .unwrap()
            .unwrap();
        self.drain();
        let text = String::from_utf8(self.text.clone()).unwrap();
        assert!(!text.contains(PRIVATE));
        assert!(!text.contains(TOKEN));
        (status, text)
    }
}

#[tokio::test]
async fn hidden_prompt_never_echoes_and_restores_terminal_even_on_signals() {
    let fake = Fake::new(vec![Reply::json(rows(true))]).await;
    let mut terminal = TerminalChild::spawn(fake.command(&["providers", "connect", "deepseek"]));
    terminal.until("DeepSeek API key:").await;
    assert!(!echo(&terminal.slave));
    terminal
        .master
        .write_all(b"synthetic-hidden-key\n")
        .unwrap();
    let (status, text) = terminal.finish().await;
    assert!(status.success());
    assert!(!text.contains("synthetic-hidden-key"));
    assert!(echo(&terminal.slave));
    assert_eq!(
        fake.seen()[0].body,
        json!({"apiKey":"synthetic-hidden-key"})
    );
    for signal in [libc::SIGINT, libc::SIGTERM] {
        let fake = Fake::new(vec![]).await;
        let mut terminal =
            TerminalChild::spawn(fake.command(&["providers", "connect", "deepseek"]));
        terminal.until("DeepSeek API key:").await;
        terminal.signal(signal);
        assert!(!terminal.finish().await.0.success());
        assert!(echo(&terminal.slave));
        assert!(fake.seen().is_empty());
    }
    let mut terminal =
        TerminalChild::spawn(fake.command(&["providers", "connect", "deepseek", "--key-stdin"]));
    assert!(!terminal.finish().await.0.success());
    assert_eq!(fake.seen().len(), 1);
}

#[tokio::test]
async fn device_login_signals_cancel_exactly_once_and_observe_same_attempt_settlement() {
    for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        let fake = Fake::new(vec![
            Reply::json(challenge()),
            Reply::json(attempt(ATTEMPT, "running")),
            Reply::json(json!({"accepted":true})),
            Reply::json(attempt(ATTEMPT, "interrupted")),
        ])
        .await;
        let mut terminal = TerminalChild::spawn(fake.command(&[
            "providers",
            "connect",
            "openai",
            "--device-code",
        ]));
        terminal.until("TEST-CODE").await;
        fake.wait_for_requests(2).await;
        terminal.signal(signal);
        let (status, text) = terminal.finish().await;
        assert!(!status.success());
        assert!(text.contains("settled as interrupted"), "{text}");
        assert!(text.contains("providers status before another login"));
        assert!(!text.contains("outcome is unknown"));
        assert!(text.contains("https://example.invalid/synthetic-login"));
        let seen = fake.seen();
        assert_eq!(seen.len(), 4);
        assert_eq!(seen[0].path, "/v1/providers/openai/connect");
        assert_eq!(seen[0].method, "POST");
        assert_eq!(seen[0].body, json!({"method":"device_code"}));
        assert_eq!(seen[1].path, "/v1/connection-attempt");
        assert_eq!(seen[2].path, "/v1/connection-attempt/cancel");
        assert_eq!(seen[2].method, "POST");
        assert_eq!(seen[2].body, json!({"operationID":ATTEMPT}));
        assert_eq!(seen[3].path, "/v1/connection-attempt");
    }
}

#[tokio::test]
async fn device_login_only_accepts_its_own_terminal_attempt_and_never_prints_raw_errors() {
    for (id, state, success) in [
        (ATTEMPT, "completed", true),
        (ATTEMPT, "failed", false),
        (OTHER, "completed", false),
    ] {
        let mut replies = vec![Reply::json(challenge()), Reply::json(attempt(id, state))];
        if id == OTHER {
            replies.extend([
                Reply::json(json!({"accepted":true})),
                Reply::json(attempt(OTHER, "completed")),
            ]);
        }
        let fake = Fake::new(replies).await;
        let mut terminal = TerminalChild::spawn(fake.command(&[
            "providers",
            "connect",
            "openai",
            "--device-code",
        ]));
        let (status, text) = terminal.finish().await;
        assert_eq!(status.success(), success, "{text}");
        assert!(!text.contains(OTHER));
        assert_eq!(fake.seen().len(), if id == OTHER { 4 } else { 2 });
        if id == OTHER {
            assert_eq!(fake.seen()[2].body, json!({"operationID":ATTEMPT}));
        }
    }
}

#[tokio::test]
async fn invitation_is_json_only_on_a_terminal_and_redirected_stdout_is_rejected() {
    let value = json!({"version":1,"relay":"wss://relay.example.invalid","route":"synthetic-route","hostKey":"synthetic-host-key",
        "secret":"synthetic-invite-secret","expires":12345,"localDevelopment":false});
    let fake = Fake::new(vec![Reply::json(value.clone())]).await;
    let mut terminal = TerminalChild::spawn(fake.command(&["remote", "invite"]));
    let (status, text) = terminal.finish().await;
    assert!(status.success());
    assert_eq!(serde_json::from_str::<Value>(&text).unwrap(), value);
    assert_eq!(fake.seen()[0].path, "/v1/remote/invitations");
    assert_eq!(fake.seen()[0].method, "POST");
    assert_eq!(fake.seen()[0].body, json!({}));
    for args in [
        vec!["remote", "invite"],
        vec!["providers", "connect", "openai", "--device-code"],
    ] {
        let (_master, slave) = pseudoterminal();
        let output = fake
            .command(&args)
            .stdin(Stdio::from(slave))
            .output()
            .await
            .unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        no_secrets(&output);
    }
    assert_eq!(fake.seen().len(), 1);
}

#[tokio::test]
async fn uncertain_login_can_be_inspected_and_cancelled_without_replaying_it() {
    let fake = Fake::new(vec![
        Reply::json(attempt(ATTEMPT, "running")),
        Reply::json(json!({"accepted":true})),
        Reply::json(attempt(ATTEMPT, "interrupted")),
    ])
    .await;
    let status = projected(&fake.run(&["providers", "login-status"]).await);
    assert_eq!(
        status,
        json!({"id":ATTEMPT,"provider":"openai","state":"running"})
    );
    let result = projected(&fake.run(&["providers", "cancel-login", ATTEMPT]).await);
    assert_eq!(
        result,
        json!({"attemptID":ATTEMPT,"cancellationRequested":true,"state":"interrupted"})
    );
    let seen = fake.seen();
    assert_eq!(seen.len(), 3);
    assert_eq!(seen[1].path, "/v1/connection-attempt/cancel");
    assert_eq!(seen[1].body, json!({"operationID":ATTEMPT}));
    assert!(
        seen.iter()
            .all(|request| !request.path.ends_with("/connect"))
    );
}

fn unknown_login(text: &str) {
    assert!(text.contains("outcome is unknown"), "{text}");
    assert!(text.contains("may still be active or credentials may have been saved"));
    assert!(text.contains("providers login-status"));
    assert!(text.contains("providers status before another login"));
    assert!(text.contains("No retry was made"));
    assert!(!text.contains("settled as interrupted"));
    assert!(!text.contains("\"connected\": true"));
}

#[tokio::test]
async fn device_login_cleanup_reports_cancellation_errors_and_actual_terminal_races() {
    for (reply, state, acknowledged) in [
        (Reply::json(json!({"accepted":true})), "completed", true),
        (Reply::error(409), "completed", false),
        (Reply::error(503), "interrupted", false),
        (
            Reply::json(json!({"accepted":true})).unreadable(),
            "failed",
            false,
        ),
        (Reply::json(json!({"accepted":false})), "completed", false),
    ] {
        let fake = Fake::new(vec![
            Reply::json(challenge()),
            Reply::json(attempt(ATTEMPT, "running")),
            reply.delayed(),
            Reply::json(attempt(ATTEMPT, state)),
        ])
        .await;
        let mut terminal = TerminalChild::spawn(fake.command(&[
            "providers",
            "connect",
            "openai",
            "--device-code",
        ]));
        terminal.until("TEST-CODE").await;
        fake.wait_for_requests(2).await;
        terminal.signal(libc::SIGINT);
        fake.wait_for_requests(3).await;
        terminal.signal(libc::SIGTERM);
        let (status, text) = terminal.finish().await;
        assert_eq!(status.success(), state == "completed", "{text}");
        assert_eq!(
            text.contains("Cancellation request was not acknowledged"),
            !acknowledged,
            "{text}"
        );
        if state == "completed" {
            assert!(text.contains("\"state\": \"completed\""), "{text}");
            assert!(text.contains("\"connected\": true"));
        } else {
            assert!(text.contains(&format!("settled as {state}")), "{text}");
            assert!(text.contains("providers status before another login"));
        }
        assert!(!text.contains("outcome is unknown"));
        let seen = fake.seen();
        assert_eq!(seen.len(), 4);
        assert_eq!(seen[2].method, "POST");
        assert_eq!(seen[2].path, "/v1/connection-attempt/cancel");
        assert_eq!(seen[2].body, json!({"operationID":ATTEMPT}));
        assert_eq!(seen[3].path, "/v1/connection-attempt");
    }
}

#[tokio::test]
async fn device_login_cleanup_cannot_claim_interruption_without_its_own_terminal_state() {
    let mut wrong_provider = attempt(ATTEMPT, "completed");
    wrong_provider["provider"] = json!("deepseek");
    for observation in [
        Reply::error(503),
        Reply::json(attempt(ATTEMPT, "interrupted")).unreadable(),
        Reply::json(json!(null)),
        Reply::json(attempt(OTHER, "completed")),
        Reply::json(wrong_provider),
        Reply::json(json!({"unexpected":PRIVATE})),
    ] {
        let fake = Fake::new(vec![
            Reply::json(challenge()),
            Reply::json(attempt(ATTEMPT, "running")),
            Reply::json(json!({"accepted":true})),
            observation,
        ])
        .await;
        let mut terminal = TerminalChild::spawn(fake.command(&[
            "providers",
            "connect",
            "openai",
            "--device-code",
        ]));
        terminal.until("TEST-CODE").await;
        fake.wait_for_requests(2).await;
        terminal.signal(libc::SIGINT);
        let (status, text) = terminal.finish().await;
        assert!(!status.success());
        unknown_login(&text);
        assert!(!text.contains(OTHER));
        let seen = fake.seen();
        assert_eq!(seen.len(), 4);
        assert_eq!(seen[2].body, json!({"operationID":ATTEMPT}));
    }
}

#[tokio::test]
async fn cancel_login_timeout_is_unknown_for_running_or_stalled_observations() {
    for stalled in [false, true] {
        let mut replies = vec![if stalled {
            Reply::json(json!({"accepted":true}))
        } else {
            Reply::error(503)
        }];
        if stalled {
            let mut reply = Reply::json(attempt(ATTEMPT, "completed"));
            reply.delay = Duration::from_secs(6);
            replies.push(reply);
        } else {
            replies.extend((0..30).map(|_| Reply::json(attempt(ATTEMPT, "running"))));
        }
        let fake = Fake::new(replies).await;
        let output = fake.run(&["providers", "cancel-login", ATTEMPT]).await;
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        no_secrets(&output);
        let error = String::from_utf8_lossy(&output.stderr);
        unknown_login(&error);
        assert_eq!(
            error.contains("Cancellation request was not acknowledged"),
            !stalled
        );
        let seen = fake.seen();
        assert_eq!(seen.iter().filter(|r| r.method == "POST").count(), 1);
        assert_eq!(seen[0].body, json!({"operationID":ATTEMPT}));
        assert!(
            seen[1..]
                .iter()
                .all(|r| r.method == "GET" && r.path == "/v1/connection-attempt")
        );
    }
}

#[tokio::test]
async fn cancel_login_observes_terminal_states_even_when_cancellation_loses_the_race() {
    for (provider, state) in [
        ("openai", "completed"),
        ("openai", "failed"),
        ("deepseek", "interrupted"),
    ] {
        let mut current = attempt(ATTEMPT, state);
        current["provider"] = json!(provider);
        let fake = Fake::new(vec![Reply::error(409), Reply::json(current)]).await;
        let output = fake.run(&["providers", "cancel-login", ATTEMPT]).await;
        assert_eq!(
            projected(&output),
            json!({"attemptID":ATTEMPT,"cancellationRequested":true,"state":state})
        );
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("Cancellation request was not acknowledged")
        );
        assert_eq!(fake.seen().len(), 2);
        assert_eq!(fake.seen()[0].body, json!({"operationID":ATTEMPT}));
    }
}

#[tokio::test]
async fn unacknowledged_login_startup_is_unknown_without_cancellation_or_replay() {
    let mut invalid_id = challenge();
    invalid_id["attempt"]["id"] = json!(PRIVATE);
    for reply in [
        Reply::error(503),
        Reply::json(json!({"unexpected":PRIVATE})),
        Reply::json(invalid_id),
        Reply::json(challenge()).unreadable(),
    ] {
        let fake = Fake::new(vec![reply]).await;
        let mut terminal = TerminalChild::spawn(fake.command(&[
            "providers",
            "connect",
            "openai",
            "--device-code",
        ]));
        let (status, text) = terminal.finish().await;
        assert!(!status.success());
        unknown_login(&text);
        assert!(!text.contains("TEST-CODE"));
        assert_eq!(fake.seen().len(), 1);
        assert_eq!(fake.seen()[0].path, "/v1/providers/openai/connect");
    }
}

#[tokio::test]
async fn signal_during_login_startup_keeps_targeted_cleanup_and_reports_completion() {
    let fake = Fake::new(vec![
        Reply::json(challenge()).delayed(),
        Reply::error(409),
        Reply::json(attempt(ATTEMPT, "completed")),
    ])
    .await;
    let mut terminal =
        TerminalChild::spawn(fake.command(&["providers", "connect", "openai", "--device-code"]));
    fake.wait_for_requests(1).await;
    terminal.signal(libc::SIGINT);
    let (status, text) = terminal.finish().await;
    assert!(status.success(), "{text}");
    assert!(text.contains("\"state\": \"completed\""));
    assert!(text.contains("\"connected\": true"));
    assert!(!text.contains("TEST-CODE"));
    assert!(!text.contains("https://example.invalid/synthetic-login"));
    let seen = fake.seen();
    assert_eq!(seen.len(), 3);
    assert_eq!(seen[1].path, "/v1/connection-attempt/cancel");
    assert_eq!(seen[1].body, json!({"operationID":ATTEMPT}));
}

#[tokio::test]
async fn invalid_mutation_acknowledgements_warn_about_effects_without_replay() {
    let mut invalid_remote = remote();
    invalid_remote["relay"] = json!("not-a-relay");
    for (args, reply) in [
        (
            vec!["providers", "disconnect", "openai"],
            Reply::json(json!({"unexpected":PRIVATE})),
        ),
        (
            vec![
                "remote",
                "configure",
                "--relay",
                "wss://relay.example.invalid",
            ],
            Reply::json(invalid_remote),
        ),
    ] {
        let fake = Fake::new(vec![reply]).await;
        let output = fake.run(&args).await;
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        no_secrets(&output);
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(error.contains("may have taken effect"));
        assert!(error.contains("No retry was made"));
        assert!(error.contains("Inspect service state before continuing"));
        assert_eq!(fake.seen().len(), 1);
    }
}
