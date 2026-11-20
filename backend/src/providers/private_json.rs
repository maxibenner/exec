//! Serialized private JSON documents shared by authentication adapters and metadata caches.
//! Updates preserve other provider fields under a short cross-process lock and settle
//! independently of caller cancellation. Provider leases separately guard rotating credentials.
use crate::{Error, Result, core::new_id};
use serde_json::{Map, Value};
use std::{
    collections::HashMap,
    fs::{self, File, Metadata, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, Weak},
};
type Lock = tokio::sync::Mutex<()>;
fn locks() -> &'static Mutex<HashMap<PathBuf, Weak<Lock>>> {
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Weak<Lock>>>> = OnceLock::new();
    LOCKS.get_or_init(Default::default)
}
fn shared_lock(path: &Path) -> Arc<Lock> {
    let mut locks = locks().lock().unwrap();
    locks.get(path).and_then(Weak::upgrade).unwrap_or_else(|| {
        let lock = Arc::new(Lock::new(()));
        locks.insert(path.to_owned(), Arc::downgrade(&lock));
        lock
    })
}
fn error() -> Error {
    Error::Invalid(
        "Private JSON storage is unavailable or insecure. Inspect the file before continuing; no retry was made.",
    )
}
fn directory(path: &Path) -> Result<(&Path, Metadata)> {
    let parent = path.parent().ok_or_else(error)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let info = fs::symlink_metadata(parent)?;
    if !info.is_dir() || info.mode() & 0o077 != 0 || info.uid() != unsafe { libc::getuid() } {
        return Err(error());
    }
    Ok((parent, info))
}
fn lock_path(path: &Path, suffix: &str) -> Result<PathBuf> {
    let mut name = path.file_name().ok_or_else(error)?.to_os_string();
    name.push(suffix);
    Ok(path.with_file_name(name))
}
/// Keep lock files in place: unlinking a held lock would permit a second owner.
fn file_lock(path: &Path, wait: bool) -> Result<File> {
    let (parent, directory) = directory(path)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| error())?;
    let info = file.metadata()?;
    if !info.is_file()
        || info.nlink() != 1
        || info.mode() & 0o077 != 0
        || info.uid() != unsafe { libc::getuid() }
    {
        return Err(error());
    }
    if wait {
        file.lock().map_err(|_| error())?;
    } else {
        file.try_lock().map_err(|_| {
            Error::Invalid(
                "Credential storage is in use by another process. Wait for authentication to settle before trying again.",
            )
        })?;
    }
    if !crate::storage::same_file(&info, &fs::symlink_metadata(path)?)
        || !crate::storage::same_file(&directory, &fs::symlink_metadata(parent)?)
    {
        return Err(error());
    }
    Ok(file)
}
pub(crate) fn read(path: &Path) -> Result<Map<String, Value>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(_) => return Err(error()),
    };
    let info = file.metadata()?;
    if !info.is_file()
        || info.nlink() != 1
        || info.len() > 1024 * 1024
        || info.mode() & 0o077 != 0
        || info.uid() != unsafe { libc::getuid() }
    {
        return Err(error());
    }
    let mut data = Vec::new();
    (&file).take(1024 * 1024 + 1).read_to_end(&mut data)?;
    if data.len() > 1024 * 1024 || !crate::storage::unchanged(&info, &file.metadata()?) {
        return Err(error());
    }
    serde_json::from_slice(&data).map_err(|_| error())
}
fn write(path: &Path, document: &Map<String, Value>) -> Result<()> {
    let (parent, directory) = directory(path)?;
    let before = match fs::symlink_metadata(path) {
        Ok(info) => {
            read(path)?;
            Some(info)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err(error()),
    };
    let bytes = serde_json::to_vec(document)?;
    if bytes.len() > 1024 * 1024 {
        return Err(error());
    }
    let temp = parent.join(format!(".private.{}.tmp", new_id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    let result = (|| {
        file.write_all(&bytes)?;
        file.sync_all()?;
        match (&before, fs::symlink_metadata(path)) {
            (Some(a), Ok(b)) if crate::storage::unchanged(a, &b) => {}
            (None, Err(e)) if e.kind() == std::io::ErrorKind::NotFound => {}
            _ => return Err(error()),
        }
        if !crate::storage::same_file(&directory, &fs::symlink_metadata(parent)?) {
            return Err(error());
        }
        fs::rename(&temp, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    let _ = fs::remove_file(temp);
    result
}
/// Provider-scoped ownership spans network operations without blocking other JSON fields.
/// The OS releases ownership on process exit; consumed-token markers remain on disk.
pub(crate) struct Lease {
    _file: File,
    _lock: tokio::sync::OwnedMutexGuard<()>,
}
#[derive(Clone)]
pub(crate) struct PrivateJson {
    path: PathBuf,
    lock: Arc<Lock>,
}
impl PrivateJson {
    pub fn new(path: PathBuf) -> Result<Self> {
        if !path.is_absolute() {
            return Err(error());
        }
        let lock = shared_lock(&path);
        Ok(Self { path, lock })
    }
    pub async fn lease(&self, provider: &str) -> Result<Lease> {
        if provider.is_empty() || !provider.bytes().all(|b| b.is_ascii_lowercase()) {
            return Err(error());
        }
        let path = lock_path(&self.path, &format!(".{provider}.lock"))?;
        let lock = shared_lock(&path).lock_owned().await;
        tokio::task::spawn_blocking(move || {
            Ok(Lease {
                _file: file_lock(&path, false)?,
                _lock: lock,
            })
        })
        .await
        .map_err(|_| error())?
    }
    pub async fn load(&self) -> Result<Map<String, Value>> {
        let lock = self.lock.clone().lock_owned().await;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || {
            let _lock = lock;
            match fs::symlink_metadata(&path) {
                // Opening an unconfigured store must not create directories or files.
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
                Err(_) => return Err(error()),
                Ok(_) => {}
            }
            // A concurrent rename can change an opened snapshot's link count/ctime.
            // Coordinate readers too, rather than treating another provider's write as corruption.
            let _file_lock = file_lock(&lock_path(&path, ".lock")?, true)?;
            read(&path)
        })
        .await
        .map_err(|_| error())?
    }
    pub async fn update(&self, key: String, value: Option<Value>) -> Result<()> {
        let lock = self.lock.clone().lock_owned().await;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || {
            let _lock = lock;
            // Serialize read/modify/rename across processes, preserving other providers.
            let _file_lock = file_lock(&lock_path(&path, ".lock")?, true)?;
            let mut doc = read(&path)?;
            if let Some(value) = value {
                doc.insert(key, value);
            } else {
                doc.remove(&key);
            }
            write(&path, &doc)
        })
        .await
        .map_err(|_| error())?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn directory() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        root
    }

    #[test]
    fn ownership_locks_are_private_exclusive_and_release_without_unlinking() {
        let root = directory();
        let path = root.path().join("credentials.json.openai.lock");
        let lease = file_lock(&path, false).unwrap();
        assert!(file_lock(&path, false).is_err());
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        drop(lease);
        assert!(path.exists());
        assert!(file_lock(&path, false).is_ok());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(file_lock(&path, false).is_err());
        fs::remove_file(&path).unwrap();
        symlink("missing", &path).unwrap();
        assert!(file_lock(&path, false).is_err());
    }

    #[tokio::test]
    async fn hard_linked_credentials_cannot_create_independent_refresh_owners() {
        let root = directory();
        let path = root.path().join("credentials.json");
        let file = PrivateJson::new(path.clone()).unwrap();
        file.update("openai".into(), Some(serde_json::json!({"synthetic":true})))
            .await
            .unwrap();
        let alias = root.path().join("alias.json");
        fs::hard_link(&path, &alias).unwrap();
        assert!(file.load().await.is_err());
        assert!(PrivateJson::new(alias).unwrap().load().await.is_err());
        assert!(file.update("openai".into(), None).await.is_err());
    }

    #[tokio::test]
    async fn document_reads_and_updates_wait_for_the_os_lock_and_preserve_other_fields() {
        let root = directory();
        let path = root.path().join("credentials.json");
        let file = PrivateJson::new(path.clone()).unwrap();
        file.update(
            "deepseek".into(),
            Some(serde_json::json!({"apiKey":"old-synthetic"})),
        )
        .await
        .unwrap();
        let lease = file_lock(&lock_path(&path, ".lock").unwrap(), false).unwrap();
        let writer = tokio::spawn(async move {
            file.update("openai".into(), Some(serde_json::json!({"synthetic":true})))
                .await
        });
        // A lexical alias has an independent in-process gate, like a separate process.
        let alias = PrivateJson::new(root.path().join(".").join("credentials.json")).unwrap();
        let reader = tokio::spawn(async move { alias.load().await });
        tokio::task::yield_now().await;
        assert!(!writer.is_finished());
        assert!(!reader.is_finished());
        // Simulate a second process's update while holding its independent file handle.
        write(
            &path,
            &serde_json::from_value(serde_json::json!({"deepseek":{"apiKey":"synthetic"}}))
                .unwrap(),
        )
        .unwrap();
        drop(lease);
        writer.await.unwrap().unwrap();
        assert_eq!(
            reader.await.unwrap().unwrap()["deepseek"]["apiKey"],
            "synthetic"
        );
        let document = read(&path).unwrap();
        assert!(document.contains_key("openai"));
        assert!(document.contains_key("deepseek"));
    }
}
