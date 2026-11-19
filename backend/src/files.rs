//! Private session directories, with globally indexed references so forks share ownership.
use crate::{Error, Result, core::*};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, Metadata, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Clone)]
pub struct FileStore {
    root: PathBuf,
    identity: Arc<Metadata>,
}
/// Input and reference validation must finish before durable ownership is reserved.
pub(crate) struct PreparedFile {
    session: String,
    reference: FileRef,
    bytes: Vec<u8>,
}
fn invalid() -> Error {
    Error::Invalid("File attachment storage is unavailable or invalid.")
}
fn private_dir(path: &Path) -> Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    let m = fs::symlink_metadata(path)?;
    if !m.is_dir() || m.mode() & 0o077 != 0 || m.uid() != unsafe { libc::getuid() } {
        return Err(invalid());
    }
    Ok(())
}
impl FileStore {
    pub async fn open(root: PathBuf) -> Result<Arc<Self>> {
        tokio::task::spawn_blocking(move || {
            if !root.is_absolute() {
                return Err(invalid());
            }
            private_dir(&root)?;
            let root = fs::canonicalize(root)?;
            let identity = Arc::new(fs::symlink_metadata(&root)?);
            Ok(Arc::new(Self { root, identity }))
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    fn check(&self) -> Result<()> {
        if !crate::storage::same_file(&fs::symlink_metadata(&self.root)?, &self.identity) {
            return Err(invalid());
        }
        Ok(())
    }
    fn index(&self, id: &str) -> Result<PathBuf> {
        if !valid_id(id) {
            return Err(invalid());
        }
        Ok(self.root.join(format!("{id}.json")))
    }
    fn read(&self, id: &str) -> Result<FileRef> {
        self.check()?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(self.index(id)?)?;
        let m = file.metadata()?;
        if !m.is_file()
            || m.len() > 8192
            || m.mode() & 0o077 != 0
            || m.uid() != unsafe { libc::getuid() }
        {
            return Err(invalid());
        }
        let mut bytes = Vec::new();
        file.take(8193).read_to_end(&mut bytes)?;
        let reference: FileRef = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        reference.validate()?;
        let path = Path::new(&reference.path);
        let asset = path.parent().ok_or_else(invalid)?;
        let session = asset.parent().ok_or_else(invalid)?;
        if reference.id != id
            || path.file_name().and_then(|s| s.to_str()) != Some(&reference.name)
            || asset.file_name().and_then(|s| s.to_str()) != Some(id)
            || session.parent() != Some(self.root.as_path())
            || !session
                .file_name()
                .and_then(|s| s.to_str())
                .is_some_and(valid_id)
        {
            return Err(invalid());
        }
        for directory in [session, asset] {
            let m = fs::symlink_metadata(directory)?;
            if !m.is_dir() || m.mode() & 0o077 != 0 || m.uid() != unsafe { libc::getuid() } {
                return Err(invalid());
            }
        }
        let m = fs::symlink_metadata(path)?;
        if !m.is_file() || m.len() != reference.byte_count as u64 || m.mode() & 0o077 != 0 {
            return Err(invalid());
        }
        Ok(reference)
    }
    pub async fn resolve(&self, ids: Vec<String>) -> Result<Vec<FileRef>> {
        if ids.len() > 4 {
            return Err(Error::Invalid("Attach up to four files."));
        }
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            let refs = ids
                .iter()
                .map(|id| store.read(id))
                .collect::<Result<Vec<_>>>()?;
            validate_message_files(&refs)?;
            Ok(refs)
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    pub(crate) async fn prepare(
        &self,
        session: String,
        id: String,
        name: String,
        bytes: Vec<u8>,
    ) -> Result<PreparedFile> {
        if !valid_id(&session)
            || !valid_id(&id)
            || !valid_file_name(&name)
            || bytes.len() > MAX_FILE_BYTES
        {
            return Err(Error::Invalid(
                "Use a valid filename and a file no larger than 8 MiB.",
            ));
        }
        let path = self.root.join(&session).join(&id).join(&name);
        tokio::task::spawn_blocking(move || {
            let reference = FileRef {
                id,
                name,
                path: path.to_str().ok_or_else(invalid)?.into(),
                byte_count: bytes.len(),
                sha256: format!("{:x}", Sha256::digest(&bytes)),
            };
            reference.validate()?;
            Ok(PreparedFile {
                session,
                reference,
                bytes,
            })
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    pub async fn put(
        &self,
        session: String,
        id: String,
        name: String,
        bytes: Vec<u8>,
    ) -> Result<FileRef> {
        self.put_prepared(self.prepare(session, id, name, bytes).await?)
            .await
    }
    pub(crate) async fn put_prepared(&self, prepared: PreparedFile) -> Result<FileRef> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || -> Result<FileRef> {
            let PreparedFile {
                session,
                reference,
                bytes,
            } = prepared;
            store.check()?;
            let session = store.root.join(session);
            private_dir(&session)?;
            let directory = session.join(&reference.id);
            // Never reuse an asset directory, including interrupted uploads.
            fs::DirBuilder::new().mode(0o700).create(&directory)?;
            let path = directory.join(&reference.name);
            let staging = store.root.join(format!(".{}.tmp", new_id()));
            let mut published = false;
            let result = (|| -> Result<FileRef> {
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o400)
                    .open(&path)?;
                file.write_all(&bytes)?;
                file.sync_all()?;
                File::open(&directory)?.sync_all()?;
                File::open(&session)?.sync_all()?;
                let mut index = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&staging)?;
                index.write_all(&serde_json::to_vec(&reference).map_err(|_| invalid())?)?;
                index.sync_all()?;
                store.check()?;
                // A complete manifest is published once, without overwriting another asset.
                fs::hard_link(&staging, store.index(&reference.id)?)?;
                published = true;
                File::open(&store.root)?.sync_all()?;
                Ok(reference)
            })();
            let _ = fs::remove_file(staging);
            if result.is_err() && !published {
                let _ = fs::remove_file(path);
                let _ = fs::remove_dir(directory);
                let _ = fs::remove_dir(session);
            }
            // After publication, retain an uncertain upload under its reserved ownership.
            result
        })
        .await
        .map_err(|_| Error::Storage)?
        .map_err(|_| Error::Storage)
    }
    pub async fn delete(&self, ids: Vec<String>) -> Result<()> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            store.check()?;
            for id in ids {
                if !store.index(&id)?.try_exists()? {
                    continue;
                }
                let reference = store.read(&id)?;
                let path = Path::new(&reference.path);
                fs::remove_file(path)?;
                let directory = path.parent().ok_or_else(invalid)?;
                fs::remove_dir(directory)?;
                // Other files or fork references can keep the originating session directory alive.
                let _ = fs::remove_dir(directory.parent().ok_or_else(invalid)?);
                fs::remove_file(store.index(&id)?)?;
            }
            File::open(&store.root)?.sync_all()?;
            Ok(())
        })
        .await
        .map_err(|_| Error::Internal)?
    }
}
