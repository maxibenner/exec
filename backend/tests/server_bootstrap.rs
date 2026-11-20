#![cfg(unix)]

use serde_json::Value;
use std::{
    fs,
    net::TcpListener,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::Path,
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
    time::timeout,
};

const KEY: &str = "synthetic-bootstrap-key";
const RELAY: &str = "wss://relay.example.invalid";
const LIMIT: Duration = Duration::from_secs(10);

fn command(root: &Path, port: u16, binary: &str) -> Command {
    let mut command = Command::new(binary);
    command
        .env_clear()
        .env("HOME", root.join("home"))
        .env("EXEC_AGENT_TOKEN_FILE", root.join("profile/token"))
        .env("EXEC_AGENT_HOST", "127.0.0.1")
        .env("EXEC_AGENT_PORT", port.to_string())
        .current_dir(root.join("workspace"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    command
}

async fn run(mut command: Command, args: &[&str], key: Option<&str>) -> Vec<u8> {
    if key.is_some() {
        command.stdin(Stdio::piped());
    }
    let mut child = command.args(args).spawn().unwrap();
    let output = timeout(LIMIT, async {
        if let Some(key) = key {
            let mut stdin = child.stdin.take().unwrap();
            stdin.write_all(key.as_bytes()).await?;
        }
        child.wait_with_output().await
    })
    .await
    .expect("administrator command timed out")
    .expect("administrator subprocess failed");
    assert!(
        output.status.success(),
        "administrator command failed: {args:?}"
    );
    output.stdout
}

fn json(bytes: Vec<u8>) -> Value {
    serde_json::from_slice(&bytes).expect("invalid JSON")
}

fn deepseek(rows: Value, connected: bool) {
    assert!(rows.as_array().unwrap().iter().any(|row| {
        row["id"] == "deepseek"
            && row["connected"] == connected
            && row["source"] == "json"
            && row["manageable"] == true
            && row["blocked"] == false
    }));
}

#[tokio::test]
async fn token_file_bootstrap_persists_api_credentials_and_restarts_cleanly() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    for name in ["home", "profile", "workspace"] {
        fs::create_dir(root.join(name)).unwrap();
    }
    let profile = root.join("profile");
    fs::set_permissions(&profile, fs::Permissions::from_mode(0o700)).unwrap();
    let token_path = profile.join("token");
    let reservation = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = reservation.local_addr().unwrap().port();
    let admin = || command(root, port, env!("CARGO_BIN_EXE_exec-agent-admin"));
    assert!(run(admin(), &["init-token"], None).await.is_empty());
    let token = fs::read(&token_path).unwrap();
    assert!(token.len() == 64 && token.iter().all(u8::is_ascii_hexdigit));
    assert!(fs::metadata(&token_path).unwrap().mode() & 0o777 == 0o600);
    assert!(run(admin(), &["init-token"], None).await.is_empty());
    assert!(
        fs::read(&token_path).unwrap() == token,
        "init-token rotated the token"
    );
    drop(reservation);

    for restarted in [false, true] {
        let mut child = command(root, port, env!("CARGO_BIN_EXE_exec-agent"))
            .arg("--profile")
            .arg(&profile)
            .spawn()
            .unwrap();
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let ready = timeout(LIMIT, lines.next_line()).await.unwrap().unwrap();
        assert!(ready.as_deref() == Some("ready"), "missing child readiness");
        assert!(profile.join("conversations/.lock").is_dir());
        // Only local administration: no inference, model discovery or balance requests.
        let health = json(run(admin(), &["health"], None).await);
        assert!(health["version"] == 1 && health["toolsEnabled"] == false);
        deepseek(
            json(run(admin(), &["providers", "list"], None).await),
            restarted,
        );
        if !restarted {
            let connect = ["providers", "connect", "deepseek", "--key-stdin"];
            deepseek(json(run(admin(), &connect, Some(KEY)).await), true);
            let configure = ["remote", "configure", "--disable", "--relay", RELAY];
            run(admin(), &configure, None).await;
        }
        let credentials = json(fs::read(profile.join("credentials.json")).unwrap());
        assert!(
            credentials["deepseek"]["apiKey"] == KEY,
            "key not persisted"
        );
        let remote = json(run(admin(), &["remote", "status"], None).await);
        assert!(remote["relay"] == RELAY && remote["enabled"] == false);
        assert!(remote["connected"] == false && remote["connectionStatus"] == "disconnected");
        let config = json(fs::read(profile.join("remote.json")).unwrap());
        assert!(config["relay"] == RELAY && config["enabled"] == false);

        let pid = child.id().unwrap() as i32;
        // SAFETY: this PID belongs to our still-owned, unreaped subprocess.
        assert!(
            unsafe { libc::kill(pid, libc::SIGTERM) } == 0,
            "SIGTERM failed"
        );
        let status = timeout(LIMIT, child.wait()).await.unwrap().unwrap();
        assert!(status.success(), "server did not shut down gracefully");
        assert!(
            !profile.join("conversations/.lock").exists(),
            "profile lock retained"
        );
        assert!(
            fs::read(&token_path).unwrap() == token,
            "server changed the token"
        );
    }
}

// Exercise the image-declared environment in fresh subprocesses, without Docker.
// Only paths and the port are substituted so credentials stay in this fixture.
fn container_command(root: &Path, port: u16, binary: &str) -> Command {
    let mut command = command(root, port, binary);
    command.env_remove("EXEC_AGENT_TOKEN_FILE");
    let environment = include_str!("../Dockerfile")
        .split_once("\nENV ")
        .unwrap()
        .1
        .split_once("\nUSER ")
        .unwrap()
        .0;
    assert!(
        environment.contains("EXEC_AGENT_DEFAULT_TOKEN_FILE=/var/lib/exec/profile/admin-token")
    );
    assert!(!environment.contains("EXEC_AGENT_TOKEN_FILE="));
    for assignment in environment.split_whitespace().filter(|s| *s != "\\") {
        let (name, value) = assignment.split_once('=').unwrap();
        command.env(name, value);
    }
    command
        .env("HOME", root.join("home"))
        .env(
            "EXEC_AGENT_DEFAULT_TOKEN_FILE",
            root.join("profile/default-token"),
        )
        .env("EXEC_AGENT_PORT", port.to_string());
    command
}

#[tokio::test]
async fn container_default_and_explicit_sources_agree_across_init_server_health_and_admin() {
    for source in ["default", "environment", "file"] {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        for name in ["home", "profile", "workspace"] {
            fs::create_dir(root.join(name)).unwrap();
        }
        let profile = root.join("profile");
        fs::set_permissions(&profile, fs::Permissions::from_mode(0o700)).unwrap();
        let default = profile.join("default-token");
        let explicit = profile.join("explicit-token");
        let token = "cd".repeat(32);
        if source != "default" {
            // Ignore an invalid/stale default; do not read, repair or rotate it.
            fs::write(&default, b"invalid-default").unwrap();
            fs::write(&explicit, &token).unwrap();
            fs::set_permissions(&explicit, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let reservation = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = reservation.local_addr().unwrap().port();
        let configured = |binary| {
            let mut command = container_command(root, port, binary);
            match source {
                "environment" => {
                    command.env("EXEC_AGENT_TOKEN", &token);
                }
                "file" => {
                    command.env("EXEC_AGENT_TOKEN_FILE", &explicit);
                }
                _ => {}
            }
            command
        };
        let admin = || configured(env!("CARGO_BIN_EXE_exec-agent-admin"));
        assert!(run(admin(), &["init-token"], None).await.is_empty());
        let original = fs::read(&default).unwrap();
        assert!(run(admin(), &["init-token"], None).await.is_empty());
        if source == "default" {
            assert_eq!(original.len(), 64);
            assert_eq!(fs::metadata(&default).unwrap().mode() & 0o777, 0o600);
        } else {
            assert_eq!(original, b"invalid-default");
        }
        drop(reservation);
        let mut child = configured(env!("CARGO_BIN_EXE_exec-agent"))
            .arg("--profile")
            .arg(&profile)
            .spawn()
            .unwrap();
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        assert_eq!(
            timeout(LIMIT, lines.next_line())
                .await
                .unwrap()
                .unwrap()
                .as_deref(),
            Some("ready")
        );
        assert_eq!(json(run(admin(), &["health"], None).await)["version"], 1);
        deepseek(
            json(run(admin(), &["providers", "list"], None).await),
            false,
        );
        // SAFETY: this PID belongs to our still-owned, unreaped subprocess.
        assert_eq!(
            unsafe { libc::kill(child.id().unwrap() as i32, libc::SIGTERM) },
            0
        );
        assert!(
            timeout(LIMIT, child.wait())
                .await
                .unwrap()
                .unwrap()
                .success()
        );
        assert_eq!(fs::read(&default).unwrap(), original);
        if source != "default" {
            assert_eq!(fs::read_to_string(&explicit).unwrap(), token);
        }
    }
}

#[tokio::test]
async fn container_explicit_dual_sources_including_empty_file_fail_everywhere() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    for name in ["home", "profile", "workspace"] {
        fs::create_dir(root.join(name)).unwrap();
    }
    let profile = root.join("profile");
    fs::set_permissions(&profile, fs::Permissions::from_mode(0o700)).unwrap();
    let token = "ab".repeat(32);
    for file in [
        String::new(),
        profile.join("explicit-token").display().to_string(),
    ] {
        for (binary, args) in [
            (env!("CARGO_BIN_EXE_exec-agent-admin"), vec!["init-token"]),
            (env!("CARGO_BIN_EXE_exec-agent-admin"), vec!["health"]),
            (
                env!("CARGO_BIN_EXE_exec-agent-admin"),
                vec!["providers", "list"],
            ),
            (
                env!("CARGO_BIN_EXE_exec-agent"),
                vec!["--profile", profile.to_str().unwrap()],
            ),
        ] {
            let output = timeout(
                LIMIT,
                container_command(root, 8765, binary)
                    .env("EXEC_AGENT_TOKEN", &token)
                    .env("EXEC_AGENT_TOKEN_FILE", &file)
                    .args(args)
                    .output(),
            )
            .await
            .unwrap()
            .unwrap();
            assert!(!output.status.success());
            assert!(output.stdout.is_empty());
            assert!(!String::from_utf8_lossy(&output.stderr).contains(&token));
        }
    }
    assert_eq!(fs::read_dir(&profile).unwrap().count(), 0);
}
