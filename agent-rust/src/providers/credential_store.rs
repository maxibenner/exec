//! Provider-owned JSON/environment authentication. Secrets never enter conversation records.
use crate::{
    Error, ProviderFailure, Result, check_cancel,
    core::{ProviderConnection, new_id},
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tokio_util::sync::CancellationToken;

#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Credentials {
    #[serde(skip_serializing_if = "Option::is_none")]
    deepseek: Option<Key>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Key {
    api_key: String,
}
struct State {
    key: Option<String>,
    environment: bool,
    blocked: bool,
}
pub struct DeepSeekCredentials {
    path: PathBuf,
    state: Arc<Mutex<State>>,
    writer: Arc<tokio::sync::Mutex<()>>,
}
fn failure() -> Error {
    Error::Invalid(
        "Credential storage is unavailable or insecure. Inspect the private JSON file; no retry was made.",
    )
}
fn validate_key(value: &str) -> Result<String> {
    super::credentials::api_key(value)
}
fn read(path: &Path) -> Result<Option<String>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(failure()),
    };
    let before = file.metadata()?;
    if !before.is_file()
        || before.len() > 16384
        || before.mode() & 0o077 != 0
        || before.uid() != unsafe { libc::getuid() }
    {
        return Err(failure());
    }
    let mut bytes = Vec::new();
    (&file).take(16385).read_to_end(&mut bytes)?;
    if bytes.len() > 16384 || !crate::storage::unchanged(&before, &file.metadata()?) {
        return Err(failure());
    }
    let credentials: Credentials = serde_json::from_slice(&bytes)?;
    credentials
        .deepseek
        .map(|key| validate_key(&key.api_key))
        .transpose()
}
fn write(path: &Path, key: Option<String>) -> Result<()> {
    let parent = path.parent().ok_or_else(failure)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let info = fs::symlink_metadata(parent)?;
    if !info.is_dir() || info.mode() & 0o077 != 0 || info.uid() != unsafe { libc::getuid() } {
        return Err(failure());
    }
    let existing = match fs::symlink_metadata(path) {
        Ok(info) => {
            read(path)?;
            Some(info)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err(failure()),
    };
    let bytes = serde_json::to_vec(&Credentials {
        deepseek: key.map(|api_key| Key { api_key }),
    })?;
    let temp = parent.join(format!(".credentials.{}.tmp", new_id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    let result = (|| {
        file.write_all(&bytes)?;
        file.sync_all()?;
        match (&existing, fs::symlink_metadata(path)) {
            (Some(before), Ok(after)) if crate::storage::unchanged(before, &after) => {}
            (None, Err(e)) if e.kind() == std::io::ErrorKind::NotFound => {}
            _ => return Err(failure()),
        }
        fs::rename(&temp, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    let _ = fs::remove_file(temp);
    result
}
impl DeepSeekCredentials {
    /// Explicit environment input ensures isolated tests never access host secrets.
    pub async fn open(path: PathBuf, environment: Option<String>) -> Result<Arc<Self>> {
        if !path.is_absolute() {
            return Err(failure());
        }
        let from_environment = environment.is_some();
        let key = if let Some(key) = environment {
            Some(validate_key(&key)?)
        } else {
            let path = path.clone();
            tokio::task::spawn_blocking(move || read(&path))
                .await
                .map_err(|_| failure())?
                .map_err(|_| failure())?
        };
        Ok(Arc::new(Self {
            path,
            state: Arc::new(Mutex::new(State {
                key,
                environment: from_environment,
                blocked: false,
            })),
            writer: Arc::new(tokio::sync::Mutex::new(())),
        }))
    }
    pub fn connection(&self) -> ProviderConnection {
        let state = self.state.lock().unwrap();
        ProviderConnection {
            id: "deepseek".into(),
            name: "DeepSeek".into(),
            connected: state.key.is_some() && !state.blocked,
            source: if state.environment {
                "environment"
            } else {
                "json"
            }
            .into(),
            blocked: state.blocked,
            manageable: !state.environment && !state.blocked,
        }
    }
    pub fn key(&self, cancel: &CancellationToken) -> Result<String> {
        check_cancel(cancel)?;
        let state = self.state.lock().unwrap();
        if state.blocked {
            return Err(Error::Storage);
        }
        state
            .key
            .clone()
            .ok_or(Error::Provider(ProviderFailure::Authentication))
    }
    pub async fn set(&self, key: Option<String>) -> Result<()> {
        let key = key.map(|key| validate_key(&key)).transpose()?;
        let writer = self.writer.clone().lock_owned().await;
        {
            let state = self.state.lock().unwrap();
            if state.environment {
                return Err(Error::Invalid(
                    "Environment credentials are externally managed. Change the environment and restart.",
                ));
            }
            if state.blocked {
                return Err(Error::Storage);
            }
        }
        let path = self.path.clone();
        let state = self.state.clone();
        // Own the write and state settlement even if the caller detaches.
        tokio::task::spawn_blocking(move || {
            let _writer = writer;
            let result = write(&path, key.clone());
            let mut state = state.lock().unwrap();
            if result.is_ok() {
                state.key = key;
            } else {
                state.key = None;
                state.blocked = true;
            }
            result.map_err(|_| failure())
        })
        .await
        .map_err(|_| failure())?
    }
}
