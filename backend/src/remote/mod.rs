mod crypto;
mod tunnel;
use crate::{Error, Result, core::valid_id};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::{Mutex, watch};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Device {
    id: String,
    name: String,
    public_key: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Configuration {
    private_key: String,
    host_token: String,
    relay: String,
    enabled: bool,
    local_development: bool,
    devices: Vec<Device>,
}
struct Invitation {
    secret: String,
    expires: u64,
}
#[derive(Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum ConnectionStatus {
    Disconnected,
    Connecting,
    Connected,
    RelayNotFound,
}
struct State {
    config: Configuration,
    invitation: Option<Invitation>,
    connection: ConnectionStatus,
}
pub(crate) struct RemoteAccess {
    path: PathBuf,
    state: Mutex<State>,
    revision: watch::Sender<u64>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Configure {
    relay: String,
    enabled: bool,
    local_development: bool,
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn random() -> String {
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn route(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}
pub(crate) fn validate_relay(value: &str, local: bool) -> Result<()> {
    let url =
        reqwest::Url::parse(value).map_err(|_| Error::Invalid("Enter a relay WebSocket URL."))?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return Err(Error::Invalid(
            "Relay URL must contain only a scheme, host and optional port.",
        ));
    }
    let private_host = url.host_str().is_some_and(|h| {
        h == "localhost"
            || h.parse::<std::net::IpAddr>().is_ok_and(|ip| match ip {
                std::net::IpAddr::V4(ip) => ip.is_loopback() || ip.is_private(),
                std::net::IpAddr::V6(ip) => ip.is_loopback() || ip.is_unique_local(),
            })
    });
    if url.scheme() != "wss" && !(local && url.scheme() == "ws" && private_host) {
        return Err(Error::Invalid(
            "Use wss://, or explicitly enable local development for a private-network ws:// relay.",
        ));
    }
    Ok(())
}
impl RemoteAccess {
    pub(crate) async fn load(profile: &Path) -> Result<Arc<Self>> {
        let path = profile.join("remote.json");
        let config = match std::fs::symlink_metadata(&path) {
            Ok(metadata) => {
                // SAFETY: getuid has no preconditions.
                if !metadata.is_file()
                    || metadata.uid() != unsafe { libc::getuid() }
                    || metadata.mode() & 0o077 != 0
                    || metadata.len() > 65536
                {
                    return Err(Error::Storage);
                }
                let config: Configuration =
                    serde_json::from_slice(&std::fs::read(&path)?).map_err(|_| Error::Storage)?;
                crypto::public_key(&config.private_key)?;
                if !config.relay.is_empty() {
                    validate_relay(&config.relay, config.local_development)?;
                }
                config
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let (private_key, _) = crypto::keypair();
                Configuration {
                    private_key,
                    host_token: random(),
                    relay: String::new(),
                    enabled: false,
                    local_development: false,
                    devices: vec![],
                }
            }
            Err(e) => return Err(e.into()),
        };
        let (revision, _) = watch::channel(0);
        Ok(Arc::new(Self {
            path,
            state: Mutex::new(State {
                config,
                invitation: None,
                connection: ConnectionStatus::Disconnected,
            }),
            revision,
        }))
    }
    async fn persist(&self, config: &Configuration) -> Result<()> {
        let path = self.path.clone();
        let data = serde_json::to_vec(config).map_err(|_| Error::Storage)?;
        tokio::task::spawn_blocking(move || -> Result<()> {
            use std::io::Write;
            let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
            let result = (|| {
                let mut file = std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&temporary)?;
                file.write_all(&data)?;
                file.sync_all()?;
                std::fs::rename(&temporary, &path)?;
                std::fs::File::open(path.parent().ok_or(Error::Storage)?)?.sync_all()?;
                Ok(())
            })();
            if result.is_err() {
                let _ = std::fs::remove_file(&temporary);
            }
            result
        })
        .await
        .map_err(|_| Error::Storage)?
    }
    pub(crate) async fn status(&self) -> Value {
        let state = self.state.lock().await;
        json!({"enabled":state.config.enabled,"relay":state.config.relay,"localDevelopment":state.config.local_development,
            "connected":state.config.enabled && state.connection == ConnectionStatus::Connected,
            "connectionStatus":if state.config.enabled { state.connection } else { ConnectionStatus::Disconnected },
            "invitationActive":state.config.enabled && state.invitation.as_ref().is_some_and(|invitation| invitation.expires > now()),
            "devices":state.config.devices.iter().map(|d| json!({"id":d.id,"name":d.name})).collect::<Vec<_>>()})
    }
    pub(crate) async fn configure(&self, input: Configure) -> Result<()> {
        if input.enabled || !input.relay.is_empty() {
            validate_relay(&input.relay, input.local_development)?;
        }
        let mut state = self.state.lock().await;
        let mut config = state.config.clone();
        config.relay = input.relay.trim_end_matches('/').to_owned();
        config.enabled = input.enabled;
        config.local_development = input.local_development;
        self.persist(&config).await?;
        state.connection = if config.enabled {
            ConnectionStatus::Connecting
        } else {
            ConnectionStatus::Disconnected
        };
        state.config = config;
        state.invitation = None;
        self.revision.send_modify(|r| *r += 1);
        Ok(())
    }
    pub(crate) async fn invite(&self) -> Result<Value> {
        let mut state = self.state.lock().await;
        if !state.config.enabled {
            return Err(Error::Invalid("Enable remote access first."));
        }
        let secret = random();
        let expires = now() + 300;
        let value = json!({"version":1,"relay":state.config.relay,"route":route(&state.config.host_token),
            "hostKey":crypto::public_key(&state.config.private_key)?,"secret":secret,"expires":expires,"localDevelopment":state.config.local_development});
        state.invitation = Some(Invitation { secret, expires });
        Ok(value)
    }
    pub(crate) async fn revoke(&self, id: &str) -> Result<()> {
        let mut state = self.state.lock().await;
        let mut config = state.config.clone();
        config.devices.retain(|d| d.id != id);
        self.persist(&config).await?;
        state.config = config;
        self.revision.send_modify(|r| *r += 1);
        Ok(())
    }
    async fn authorize_device(
        &self,
        public: &str,
        invitation: Option<&str>,
        name: &str,
    ) -> Result<String> {
        let mut state = self.state.lock().await;
        if !state.config.enabled {
            return Err(Error::Invalid("Remote access is disabled."));
        }
        if let Some(device) = state.config.devices.iter().find(|d| d.public_key == public) {
            return Ok(device.id.clone());
        }
        let invitation = invitation.ok_or(Error::Invalid("Pair this device again."))?;
        let valid = state.invitation.as_ref().is_some_and(|i| {
            i.expires > now() && {
                let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, i.secret.as_bytes());
                let tag = ring::hmac::sign(&key, b"pair");
                ring::hmac::verify(
                    &ring::hmac::Key::new(ring::hmac::HMAC_SHA256, invitation.as_bytes()),
                    b"pair",
                    tag.as_ref(),
                )
                .is_ok()
            }
        });
        if !valid || state.config.devices.len() >= 8 {
            return Err(Error::Invalid("Pairing invitation expired or unavailable."));
        }
        if name.is_empty() || name.len() > 80 || name.chars().any(char::is_control) {
            return Err(Error::Invalid("Invalid device name."));
        }
        let id = uuid::Uuid::new_v4().to_string();
        let mut config = state.config.clone();
        config.devices.push(Device {
            id: id.clone(),
            name: name.into(),
            public_key: public.into(),
        });
        // Consume before saving: a storage failure must not make an invitation reusable.
        state.invitation = None;
        self.persist(&config).await?;
        state.config = config;
        Ok(id)
    }
    async fn device_exists(&self, id: &str) -> bool {
        let state = self.state.lock().await;
        state.config.enabled && state.config.devices.iter().any(|d| d.id == id)
    }
}

/// Deliberate, fixed remote-client capability set. New API routes are denied by default.
pub(crate) fn permits(method: &str, path: &str) -> bool {
    if path.contains('%') {
        return false;
    }
    if method == "GET" {
        if let Some((route, query)) = path.split_once('?') {
            let Some(id) = route
                .strip_prefix("/v1/conversations/")
                .and_then(|tail| tail.strip_suffix("/sync"))
            else {
                return false;
            };
            if !valid_id(id) {
                return false;
            }
            let anchor = query.strip_prefix("before=").or_else(|| {
                query.strip_prefix("after=").and_then(|tail| {
                    tail.split_once("&prefix=").and_then(|(id, proof)| {
                        (proof.len() == 64 && proof.bytes().all(|byte| byte.is_ascii_hexdigit()))
                            .then_some(id)
                    })
                })
            });
            return anchor.is_some_and(valid_id);
        }
    }
    if path.contains('?') {
        return false;
    }
    if method == "GET"
        && matches!(
            path,
            "/v1/health" | "/v1/models" | "/v1/library" | "/v1/conversations"
        )
    {
        return true;
    }
    if method == "PATCH" && path == "/v1/library" {
        return true;
    }
    if method == "POST" && matches!(path, "/v1/conversations" | "/v1/workspaces/browse") {
        return true;
    }
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() < 4
        || parts[1] != "v1"
        || parts[2] != "conversations"
        || uuid::Uuid::parse_str(parts[3]).is_err()
    {
        return false;
    }
    if parts.len() == 4 {
        return method == "GET" || method == "DELETE";
    }
    parts.len() == 5
        && match method {
            "GET" => parts[4] == "sync",
            "POST" => matches!(parts[4], "turns" | "steer" | "cancel" | "approvals"),
            "PUT" => matches!(parts[4], "settings" | "model" | "title"),
            _ => false,
        }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn wait_status(remote: &RemoteAccess, expected: &str) {
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                if remote.status().await["connectionStatus"] == expected {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn relay_status_tracks_handshake_failure_and_disable() {
        let dir = tempfile::tempdir().unwrap();
        let remote = RemoteAccess::load(dir.path()).await.unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay = format!("ws://{}", listener.local_addr().unwrap());
        remote
            .configure(Configure {
                relay: relay.clone(),
                enabled: true,
                local_development: true,
            })
            .await
            .unwrap();
        assert_eq!(remote.status().await["connectionStatus"], "connecting");
        let stop = tokio_util::sync::CancellationToken::new();
        let runner = tokio::spawn(remote.clone().run(std::sync::Weak::new(), stop.clone()));
        let (socket, _) = listener.accept().await.unwrap();
        let _socket = tokio_tungstenite::accept_async(socket).await.unwrap();
        wait_status(&remote, "connected").await;
        remote
            .configure(Configure {
                relay: relay.clone(),
                enabled: false,
                local_development: true,
            })
            .await
            .unwrap();
        assert_eq!(remote.status().await["connectionStatus"], "disconnected");
        assert_eq!(remote.status().await["connected"], false);
        drop(listener);
        remote
            .configure(Configure {
                relay,
                enabled: true,
                local_development: true,
            })
            .await
            .unwrap();
        wait_status(&remote, "relayNotFound").await;
        stop.cancel();
        runner.await.unwrap();
        assert_eq!(remote.status().await["connectionStatus"], "disconnected");
    }
    #[tokio::test]
    async fn pairing_is_single_use_persistent_and_revocable() {
        let dir = tempfile::tempdir().unwrap();
        let remote = RemoteAccess::load(dir.path()).await.unwrap();
        remote
            .configure(Configure {
                relay: "ws://127.0.0.1:8787".into(),
                enabled: true,
                local_development: true,
            })
            .await
            .unwrap();
        let invitation = remote.invite().await.unwrap();
        assert_eq!(remote.status().await["invitationActive"], true);
        let (_, public) = crypto::keypair();
        let (_, other) = crypto::keypair();
        assert!(
            remote
                .authorize_device(&public, Some("wrong"), "Phone")
                .await
                .is_err()
        );
        assert_eq!(remote.status().await["invitationActive"], true);
        let id = remote
            .authorize_device(&public, invitation["secret"].as_str(), "Phone")
            .await
            .unwrap();
        assert_eq!(remote.status().await["invitationActive"], false);
        assert!(
            remote
                .authorize_device(&other, invitation["secret"].as_str(), "Other")
                .await
                .is_err()
        );
        let restored = RemoteAccess::load(dir.path()).await.unwrap();
        assert_eq!(
            restored
                .authorize_device(&public, None, "Phone")
                .await
                .unwrap(),
            id
        );
        restored.revoke(&id).await.unwrap();
        assert!(!restored.device_exists(&id).await);
        assert!(
            restored
                .authorize_device(&public, None, "Phone")
                .await
                .is_err()
        );
    }
    #[test]
    fn rejects_admin_routes_and_plaintext_production() {
        for path in [
            "/v1/providers",
            "/v1/remote",
            "/v1/native/events",
            "/v1/library?x=1",
        ] {
            assert!(!permits("POST", path));
        }
        assert!(validate_relay("ws://example.com", true).is_err());
        assert!(validate_relay("ws://127.0.0.1:8787", false).is_err());
        assert!(validate_relay("wss://example.com", false).is_ok());
        assert!(validate_relay("wss://user:secret@example.com", false).is_err());
    }
    #[test]
    fn sync_queries_are_read_only_and_strictly_scoped() {
        let id = crate::core::new_id();
        let message = crate::core::new_id();
        let route = format!("/v1/conversations/{id}/sync");
        assert!(permits("GET", &route));
        assert!(permits("GET", &format!("{route}?before={message}")));
        assert!(permits(
            "GET",
            &format!("{route}?after={message}&prefix={}", "a".repeat(64))
        ));
        assert!(!permits("POST", &route));
        assert!(!permits(
            "GET",
            &format!("{route}?before={message}&other=x")
        ));
        assert!(!permits(
            "GET",
            &format!("{route}?after={message}&prefix=bad")
        ));
        assert!(!permits(
            "GET",
            &format!("/v1/conversations/{id}?before={message}")
        ));
    }
}
