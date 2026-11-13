//! Provider-owned JSON/environment authentication. Secrets never enter conversation records.
use crate::{Error, ProviderFailure, Result, check_cancel, core::ProviderConnection};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};
use tokio_util::sync::CancellationToken;
struct State {
    key: Option<String>,
    environment: bool,
    blocked: bool,
}
pub struct DeepSeekCredentials {
    file: super::private_json::PrivateJson,
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
impl DeepSeekCredentials {
    /// Explicit environment input ensures isolated tests never access host secrets.
    pub async fn open(path: PathBuf, environment: Option<String>) -> Result<Arc<Self>> {
        if !path.is_absolute() {
            return Err(failure());
        }
        let file = super::private_json::PrivateJson::new(path)?;
        let from_environment = environment.is_some();
        let key = if let Some(key) = environment {
            Some(validate_key(&key)?)
        } else {
            let document = file.load().await.map_err(|_| failure())?;
            document
                .get("deepseek")
                .map(|value| {
                    let key = value
                        .get("apiKey")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(failure)?;
                    validate_key(key)
                })
                .transpose()?
        };
        Ok(Arc::new(Self {
            file,
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
        let file = self.file.clone();
        let state = self.state.clone();
        // Own the write and state settlement even if the caller detaches.
        tokio::spawn(async move {
            let _writer = writer;
            let result = file
                .update(
                    "deepseek".into(),
                    key.as_ref().map(|key| serde_json::json!({"apiKey":key})),
                )
                .await;
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
