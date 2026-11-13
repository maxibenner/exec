#[path = "support/http.rs"]
mod http;
mod support;
use exec_agent::{
    client::AgentClient,
    core::ChatProvider,
    providers::{DeepSeekProvider, credentials::load_deepseek_api_key},
    service::profile_socket,
};
use serde_json::json;
use std::{
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink},
    path::Path,
    sync::Arc,
    time::Duration,
};
use support::*;
const SECRET: &str = "test-only-credential";
fn credentials(root: &Path, content: &str) -> std::path::PathBuf {
    let path = root.join("credentials.json");
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)
        .unwrap();
    file.write_all(content.as_bytes()).unwrap();
    path
}
#[tokio::test]
async fn private_json_custom_paths_environment_overrides_without_writing() {
    let root = directory();
    let path = credentials(
        root.path(),
        &json!({"deepseek":{"apiKey":SECRET}}).to_string(),
    );
    assert_eq!(
        load_deepseek_api_key(root.path(), None, None)
            .await
            .unwrap(),
        SECRET
    );
    assert_eq!(
        load_deepseek_api_key(&root.path().join("unused"), Some(path.clone()), None)
            .await
            .unwrap(),
        SECRET
    );
    fs::write(&path, format!("invalid {SECRET}")).unwrap();
    assert_eq!(
        load_deepseek_api_key(root.path(), None, Some(" override ".into()))
            .await
            .unwrap(),
        "override"
    );
    assert_eq!(
        fs::read_to_string(path).unwrap(),
        format!("invalid {SECRET}")
    );
}
async fn invalid_env(value: String) {
    let error = load_deepseek_api_key(Path::new("/not-consulted"), None, Some(value))
        .await
        .unwrap_err();
    assert!(error.to_string().contains("Invalid DeepSeek API key"));
}
macro_rules! invalid {
    ($name:ident,$value:expr) => {
        #[tokio::test]
        async fn $name() {
            invalid_env($value.into()).await;
        }
    };
}
invalid!(empty_environment_key, "");
invalid!(blank_environment_key, " ");
invalid!(newline_environment_key, "bad\nkey");
invalid!(space_environment_key, "bad key");
invalid!(non_ascii_environment_key, "é");
invalid!(oversized_environment_key, "x".repeat(8193));
#[tokio::test]
async fn missing_malformed_oversized_unknown_json_credentials_fail_redacted() {
    let root = directory();
    assert!(
        load_deepseek_api_key(root.path(), None, None)
            .await
            .is_err()
    );
    for content in [
        SECRET.into(),
        format!("{{\"{SECRET}\":"),
        "null".into(),
        "[]".into(),
        "{}".into(),
        json!({"deepseek":{"apiKey":""}}).to_string(),
        json!({"deepseek":{"apiKey":SECRET,"unknown":SECRET}}).to_string(),
        json!({"deepseek":{"apiKey":SECRET},"extra":true}).to_string(),
        json!({"deepseek":{"apiKey":123}}).to_string(),
        " ".repeat(16385),
    ] {
        credentials(root.path(), &content);
        let error = load_deepseek_api_key(root.path(), None, None)
            .await
            .unwrap_err()
            .to_string();
        assert!(error.starts_with("Cannot load DeepSeek credentials."));
        assert!(!error.contains(SECRET));
        assert!(!error.contains(root.path().to_str().unwrap()));
    }
}
#[tokio::test]
async fn credential_files_reject_shared_permissions_symlinks_directories_unchanged() {
    let root = directory();
    let path = credentials(
        root.path(),
        &json!({"deepseek":{"apiKey":SECRET}}).to_string(),
    );
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(
        load_deepseek_api_key(root.path(), None, None)
            .await
            .is_err()
    );
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o644
    );
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let link = root.path().join("link.json");
    symlink(path, &link).unwrap();
    for path in [link, root.path().to_owned()] {
        assert!(
            load_deepseek_api_key(root.path(), Some(path), None)
                .await
                .is_err()
        );
    }
}
#[tokio::test]
async fn configured_credentials_used_only_for_provider_transport() {
    let root = directory();
    let key = load_deepseek_api_key(root.path(), None, Some(SECRET.into()))
        .await
        .unwrap();
    let transport = http::Transport::new(|request| async move {
        assert_eq!(request.path, "models");
        assert_eq!(request.key, SECRET);
        Ok(http::json_response(
            json!({"object":"list","data":[{"id":"deepseek-chat"}]}),
        ))
    });
    let provider = DeepSeekProvider::with_transport(
        Arc::new(move |_| {
            let key = key.clone();
            Box::pin(async move { Ok(key) })
        }),
        transport.clone(),
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(transport.count(), 0);
    assert_eq!(
        provider
            .models(tokio_util::sync::CancellationToken::new())
            .await
            .unwrap()[0]
            .id,
        "deepseek-chat"
    );
    assert_eq!(transport.count(), 1);
}
async fn start(
    profile: &Path,
    args: &[&str],
    env_key: bool,
) -> (tokio::process::Child, AgentClient) {
    let mut command = tokio::process::Command::new(env!("CARGO_BIN_EXE_exec-agent"));
    command
        .args(["--profile", profile.to_str().unwrap(), "serve"])
        .args(args)
        .env_clear()
        .env("HOME", profile.parent().unwrap())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    if env_key {
        command.env("DEEPSEEK_API_KEY", SECRET);
    }
    let mut child = command.spawn().unwrap();
    let client = AgentClient::new(profile_socket(profile)).unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            assert!(
                child.try_wait().unwrap().is_none(),
                "Service exited before startup"
            );
            if client.health().await.is_ok() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    (child, client)
}
async fn stop(child: tokio::process::Child, signal: i32) {
    // SAFETY: PID is the still-owned test child; kill takes scalar arguments.
    assert_eq!(unsafe { libc::kill(child.id().unwrap() as i32, signal) }, 0);
    let output = tokio::time::timeout(Duration::from_secs(5), child.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!String::from_utf8_lossy(&output.stdout).contains(SECRET));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(SECRET));
}
#[tokio::test]
async fn standalone_serve_loads_json_env_shutdown_reopens_without_credential_exposure() {
    let root = directory();
    let profile = root.path().join("profile");
    let path = credentials(
        root.path(),
        &json!({"deepseek":{"apiKey":SECRET}}).to_string(),
    );
    let (first, client) = start(&profile, &["--credentials", path.to_str().unwrap()], false).await;
    assert_eq!(
        client.health().await.unwrap(),
        json!({"version":1,"toolsEnabled":false})
    );
    let c = client
        .create("deepseek-chat", root.path().to_str().unwrap())
        .await
        .unwrap();
    assert!(
        !serde_json::to_string(&client.get(&c.id).await.unwrap())
            .unwrap()
            .contains(SECRET)
    );
    assert!(
        !fs::read_to_string(profile.join("conversations").join(format!("{}.json", c.id)))
            .unwrap()
            .contains(SECRET)
    );
    stop(first, libc::SIGTERM).await;
    assert!(!profile_socket(&profile).exists());
    assert!(!profile.join("conversations/.lock").exists());
    let (second, client) = start(&profile, &["--workspace-tools"], true).await;
    assert_eq!(
        client.health().await.unwrap(),
        json!({"version":1,"toolsEnabled":true})
    );
    assert_eq!(client.list().await.unwrap()[0]["id"], c.id);
    stop(second, libc::SIGINT).await;
    credentials(&profile, &json!({"deepseek":{"apiKey":SECRET}}).to_string());
    let (third, client) = start(&profile, &[], false).await;
    assert_eq!(client.list().await.unwrap()[0]["id"], c.id);
    stop(third, libc::SIGTERM).await;
}
#[tokio::test]
async fn serve_fails_before_creating_profile_on_bad_arguments() {
    let root = directory();
    let profile = root.path().join("absent");
    for args in [
        vec!["--credentials"],
        vec!["--api-key", SECRET],
        vec!["--workspace-tools", "--workspace-tools"],
    ] {
        let output = tokio::process::Command::new(env!("CARGO_BIN_EXE_exec-agent"))
            .args(["--profile", profile.to_str().unwrap(), "serve"])
            .args(args)
            .env_clear()
            .env("HOME", root.path())
            .output()
            .await
            .unwrap();
        assert_eq!(output.status.code(), Some(1));
        assert!(!String::from_utf8_lossy(&output.stderr).contains(SECRET));
        assert!(!String::from_utf8_lossy(&output.stdout).contains(SECRET));
    }
    assert!(!profile.exists());
}

#[tokio::test]
async fn standalone_without_credentials_keeps_history_accessible() {
    let root = directory();
    let profile = root.path().join("offline");
    let (first, client) = start(&profile, &[], false).await;
    assert!(!client.connections().await.unwrap()[0].connected);
    let c = client
        .create("deepseek-chat", root.path().to_str().unwrap())
        .await
        .unwrap();
    client.rename(&c.id, "Offline history").await.unwrap();
    stop(first, libc::SIGTERM).await;
    let (second, client) = start(&profile, &[], false).await;
    assert_eq!(
        client.get(&c.id).await.unwrap().metadata.title.as_deref(),
        Some("Offline history")
    );
    assert_eq!(client.list().await.unwrap()[0]["id"], c.id);
    stop(second, libc::SIGTERM).await;
}
