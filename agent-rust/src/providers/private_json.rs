//! Serialized private JSON documents shared by authentication adapters and metadata caches.
//! Updates preserve other provider fields and settle independently of caller cancellation.
use crate::{Error, Result, core::new_id};
use serde_json::{Map, Value};
use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
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
fn error() -> Error {
    Error::Invalid(
        "Private JSON storage is unavailable or insecure. Inspect the file before continuing; no retry was made.",
    )
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
    let parent = path.parent().ok_or_else(error)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let directory = fs::symlink_metadata(parent)?;
    if !directory.is_dir()
        || directory.mode() & 0o077 != 0
        || directory.uid() != unsafe { libc::getuid() }
    {
        return Err(error());
    }
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
        let mut locks = locks().lock().unwrap();
        let lock = locks.get(&path).and_then(Weak::upgrade).unwrap_or_else(|| {
            let lock = Arc::new(Lock::new(()));
            locks.insert(path.clone(), Arc::downgrade(&lock));
            lock
        });
        Ok(Self { path, lock })
    }
    pub async fn load(&self) -> Result<Map<String, Value>> {
        let lock = self.lock.clone().lock_owned().await;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || {
            let _lock = lock;
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
