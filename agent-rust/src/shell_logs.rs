//! Private retained shell output. References belong to conversations, including forks.
use crate::{Error, Result, core::valid_id};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, Metadata, OpenOptions},
    io::{Read, Seek, SeekFrom},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};
pub const LOG_LIMIT: usize = 64 * 1024 * 1024;
#[derive(Clone)]
pub struct ShellLogStore {
    root: PathBuf,
    identity: Arc<Metadata>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LogChunk {
    pub text: String,
    pub offset: u64,
    pub next_offset: u64,
    pub total_bytes: u64,
    pub end_of_file: bool,
}
impl ShellLogStore {
    pub async fn open(root: PathBuf) -> Result<Arc<Self>> {
        tokio::task::spawn_blocking(move || {
            if !root.is_absolute() {
                return Err(Error::Storage);
            }
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&root)?;
            let identity = fs::symlink_metadata(&root)?;
            if !identity.is_dir()
                || identity.mode() & 0o077 != 0
                || identity.uid() != unsafe { libc::getuid() }
            {
                return Err(Error::Storage);
            }
            Ok(Arc::new(Self {
                root,
                identity: Arc::new(identity),
            }))
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    fn check(&self) -> Result<()> {
        let info = fs::symlink_metadata(&self.root)?;
        if !crate::storage::same_file(&info, &self.identity)
            || !info.is_dir()
            || info.mode() & 0o077 != 0
        {
            return Err(Error::Storage);
        }
        Ok(())
    }
    pub fn path(&self, id: &str) -> Result<PathBuf> {
        if !valid_id(id) {
            return Err(Error::Invalid("Invalid log ID."));
        }
        Ok(self.root.join(format!("{id}.log")))
    }
    pub async fn writer(&self, id: &str) -> Result<tokio::fs::File> {
        let store = self.clone();
        let path = self.path(id)?;
        let file = tokio::task::spawn_blocking(move || {
            store.check()?;
            Ok::<_, Error>(
                OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .custom_flags(libc::O_NOFOLLOW)
                    .open(path)?,
            )
        })
        .await
        .map_err(|_| Error::Internal)??;
        Ok(tokio::fs::File::from_std(file))
    }
    pub async fn read(&self, id: &str, offset: u64, max_bytes: usize) -> Result<LogChunk> {
        if max_bytes == 0 || max_bytes > 32768 {
            return Err(Error::Invalid("Read 1–32768 log bytes per request."));
        }
        let store = self.clone();
        let path = self.path(id)?;
        tokio::task::spawn_blocking(move || {
            store.check()?;
            let mut file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(path)?;
            let info = file.metadata()?;
            if !info.is_file()
                || info.uid() != unsafe { libc::getuid() }
                || info.mode() & 0o077 != 0
                || info.len() > LOG_LIMIT as u64
                || offset > info.len()
            {
                return Err(Error::Invalid(
                    "Log is unavailable or the offset is invalid.",
                ));
            }
            file.seek(SeekFrom::Start(offset))?;
            let mut bytes = Vec::new();
            file.take((max_bytes as u64).min(info.len() - offset))
                .read_to_end(&mut bytes)?;
            let next_offset = offset + bytes.len() as u64;
            Ok(LogChunk {
                text: String::from_utf8_lossy(&bytes).into_owned(),
                offset,
                next_offset,
                total_bytes: info.len(),
                end_of_file: next_offset == info.len(),
            })
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    pub async fn delete(&self, ids: Vec<String>) -> Result<()> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            store.check()?;
            for id in ids {
                let path = store.path(&id)?;
                match fs::symlink_metadata(&path) {
                    Ok(info) if info.is_file() => fs::remove_file(path)?,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    _ => return Err(Error::Storage),
                }
            }
            std::fs::File::open(Path::new(&store.root))?.sync_all()?;
            Ok(())
        })
        .await
        .map_err(|_| Error::Internal)?
    }
}
