use super::DeepSeekProvider;
use crate::{Error, Result, check_cancel};
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};
const FILE_ERROR: &str = "Cannot load DeepSeek credentials. Set DEEPSEEK_API_KEY or supply an owned, private (0600) credentials JSON file with {\"deepseek\":{\"apiKey\":\"…\"}}.";
fn api_key(value: &str) -> Result<String> {
    let key = value.trim();
    if key.is_empty() || key.len() > 8192 || !key.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
        return Err(Error::Invalid(
            "Invalid DeepSeek API key. Supply a nonempty printable ASCII token.",
        ));
    }
    Ok(key.into())
}
/// Explicit environment input keeps tests isolated from the host's credentials.
pub async fn load_deepseek_api_key(
    profile: &Path,
    path: Option<PathBuf>,
    environment: Option<String>,
) -> Result<String> {
    if let Some(value) = environment {
        return api_key(&value);
    }
    let path = path.unwrap_or_else(|| profile.join("credentials.json"));
    tokio::task::spawn_blocking(move || {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)?;
        let info = file.metadata()?;
        // SAFETY: getuid has no arguments and no memory-safety preconditions.
        let uid = unsafe { libc::getuid() };
        if !info.is_file() || info.len() > 16384 || info.mode() & 0o077 != 0 || info.uid() != uid {
            return Err(Error::Internal);
        }
        let mut data = vec![];
        file.take(16385).read_to_end(&mut data)?;
        if data.len() > 16384 {
            return Err(Error::Internal);
        }
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Credentials {
            deepseek: Key,
        }
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields, rename_all = "camelCase")]
        struct Key {
            api_key: String,
        }
        let credentials: Credentials = serde_json::from_slice(&data)?;
        api_key(&credentials.deepseek.api_key)
    })
    .await
    .map_err(|_| Error::Invalid(FILE_ERROR))?
    .map_err(|_| Error::Invalid(FILE_ERROR))
}
pub async fn configured_deepseek_provider(
    profile: &Path,
    path: Option<PathBuf>,
) -> Result<DeepSeekProvider> {
    let environment = match std::env::var("DEEPSEEK_API_KEY") {
        Ok(value) => Some(value),
        Err(std::env::VarError::NotPresent) => None,
        Err(_) => return Err(Error::Invalid("Invalid DeepSeek API key.")),
    };
    let key = load_deepseek_api_key(profile, path, environment).await?;
    DeepSeekProvider::new(Arc::new(move |cancel| {
        let key = key.clone();
        Box::pin(async move {
            check_cancel(&cancel)?;
            Ok(key)
        })
    }))
}
