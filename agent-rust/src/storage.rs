use crate::{Error, Result, core::*};
use async_trait::async_trait;
use std::{
    fs::{self, File, Metadata, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::Mutex;
const LIMIT: u64 = 16 * 1024 * 1024;
#[async_trait]
pub trait ConversationStore: Checkpoint {
    async fn load(&self) -> Result<Vec<ConversationRecord>>;
    async fn delete(&self, id: String) -> Result<()>;
    async fn close(&self) -> Result<()>;
    async fn load_library(&self) -> Result<LibraryConfiguration> {
        Ok(LibraryConfiguration::default())
    }
    async fn save_library(&self, _: LibraryConfiguration) -> Result<()> {
        Err(Error::Storage)
    }
}
struct StoreState {
    root: PathBuf,
    identity: Metadata,
    closed: bool,
}
impl StoreState {
    fn owner(&self) -> Result<()> {
        let info = fs::symlink_metadata(self.root.join(".lock"))?;
        if self.closed || !info.is_dir() || !same_file(&info, &self.identity) {
            return Err(Error::Invalid(
                "Profile ownership was lost or store is closed.",
            ));
        }
        Ok(())
    }
    fn file(&self, id: &str) -> Result<PathBuf> {
        if !valid_id(id) {
            return Err(Error::Invalid("Invalid conversation ID."));
        }
        Ok(self.root.join(format!("{id}.json")))
    }
    fn sync(&self) -> Result<()> {
        File::open(&self.root)?.sync_all()?;
        Ok(())
    }
}
#[derive(Clone)]
pub struct JsonConversationStore {
    state: Arc<Mutex<StoreState>>,
}
impl JsonConversationStore {
    pub async fn open(directory: impl AsRef<Path>) -> Result<Arc<Self>> {
        let directory = directory.as_ref().to_owned();
        tokio::task::spawn_blocking(move || {
            if !directory.is_absolute() { return Err(Error::Invalid("Profile directory must be absolute.")); }
            fs::DirBuilder::new().recursive(true).mode(0o700).create(&directory)?;
            let root=fs::canonicalize(directory)?; let lock=root.join(".lock");
            fs::DirBuilder::new().mode(0o700).create(&lock).map_err(|_|Error::Invalid("Profile is locked or unavailable. Stop its owner before opening it; a crash lock requires explicit recovery."))?;
            let initialize=(|| -> Result<Metadata> {
                let mut owner=OpenOptions::new().write(true).create_new(true).mode(0o600).open(lock.join("owner"))?;
                writeln!(owner,"PID: {}",std::process::id())?; owner.sync_all()?; Ok(fs::symlink_metadata(&lock)?)
            })();
            match initialize {
                Ok(identity) => Ok(Arc::new(Self{state:Arc::new(Mutex::new(StoreState{root,identity,closed:false}))})),
                Err(_) => { let _=fs::remove_file(lock.join("owner")); let _=fs::remove_dir(lock); Err(Error::Invalid("Could not initialize profile ownership.")) }
            }
        }).await.map_err(|_|Error::Internal)?
    }
    async fn queued<T: Send + 'static>(
        &self,
        action: impl FnOnce(&mut StoreState) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        // Acquire in async FIFO order, then move ownership into the blocking
        // task. Dropping a caller cannot release the lock during a disk write.
        let mut state = self.state.clone().lock_owned().await;
        tokio::task::spawn_blocking(move || {
            state.owner()?;
            action(&mut state)
        })
        .await
        .map_err(|_| Error::Internal)?
    }
}
#[async_trait]
impl Checkpoint for JsonConversationStore {
    async fn save(&self, record: ConversationRecord) -> Result<()> {
        record.validate()?;
        let data = serde_json::to_vec(&record)?;
        if data.len() as u64 > LIMIT {
            return Err(Error::Storage);
        }
        self.queued(move |s| {
            let target = s.file(&record.id)?;
            match fs::symlink_metadata(&target) {
                Ok(info) if !info.is_file() => return Err(Error::Storage),
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(Error::Storage),
                _ => {}
            }
            let temp = s.root.join(format!(".{}.{}.tmp", record.id, new_id()));
            let mut staged = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp)?;
            let result = (|| {
                staged.write_all(&data)?;
                staged.sync_all()?;
                s.owner()?;
                fs::rename(&temp, &target)?;
                s.sync()
            })();
            let _ = fs::remove_file(&temp);
            result
        })
        .await
        .map_err(|_| Error::Storage)
    }
}
#[async_trait]
impl ConversationStore for JsonConversationStore {
    async fn load(&self) -> Result<Vec<ConversationRecord>> {
        self.queued(|s| {
            let mut paths=fs::read_dir(&s.root)?.map(|e|e.map(|e|e.path())).collect::<std::io::Result<Vec<_>>>()?; paths.sort();
            let mut records=vec![];
            for path in paths { if path.extension().and_then(|s|s.to_str())!=Some("json") {continue;}
                if path.file_name().and_then(|s|s.to_str())==Some("library.json") { continue; }
                let id=path.file_stem().and_then(|s|s.to_str()).ok_or(Error::Internal)?;
                let file=OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW|libc::O_NONBLOCK).open(s.file(id)?)?;
                let info=file.metadata()?; if !info.is_file() || info.len()>LIMIT {return Err(Error::Internal);}
                let mut data=vec![]; (&file).take(LIMIT+1).read_to_end(&mut data)?;
                if data.len() as u64!=info.len() || !unchanged(&info,&file.metadata()?) {return Err(Error::Internal);}
                let record:ConversationRecord=serde_json::from_slice(&data)?; record.validate()?;
                if record.id!=id {return Err(Error::Internal);} records.push(record);
            } Ok(records)
        }).await.map_err(|_|Error::Invalid("Could not load conversations. The profile may contain corrupt, unsupported, linked, or oversized data; it was not overwritten."))
    }
    async fn load_library(&self) -> Result<LibraryConfiguration> {
        self.queued(|s| {
            let path = s.root.join("library.json");
            let file = match OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(path)
            {
                Ok(file) => file,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    return Ok(LibraryConfiguration::default());
                }
                Err(_) => return Err(Error::Storage),
            };
            let metadata = file.metadata()?;
            if !metadata.is_file() || metadata.len() > 1024 * 1024 {
                return Err(Error::Storage);
            }
            let mut data = Vec::new();
            (&file).take(1024 * 1024 + 1).read_to_end(&mut data)?;
            if data.len() > 1024 * 1024 || !unchanged(&metadata, &file.metadata()?) {
                return Err(Error::Storage);
            }
            let config: LibraryConfiguration = serde_json::from_slice(&data)?;
            config.validate()?;
            Ok(config)
        })
        .await
    }
    async fn save_library(&self, config: LibraryConfiguration) -> Result<()> {
        config.validate()?;
        let data = serde_json::to_vec(&config)?;
        self.queued(move |s| {
            let target = s.root.join("library.json");
            match fs::symlink_metadata(&target) {
                Ok(m) if !m.is_file() => return Err(Error::Storage),
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(Error::Storage),
                _ => {}
            }
            let temp = s.root.join(format!(".library.{}.tmp", new_id()));
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp)?;
            let result = (|| {
                file.write_all(&data)?;
                file.sync_all()?;
                s.owner()?;
                fs::rename(&temp, target)?;
                s.sync()
            })();
            let _ = fs::remove_file(temp);
            result
        })
        .await
        .map_err(|_| Error::Storage)
    }
    async fn delete(&self, id: String) -> Result<()> {
        self.queued(move |s| {
            fs::remove_file(s.file(&id)?)?;
            s.sync()
        })
        .await
        .map_err(|_| {
            Error::Invalid(
                "Could not confirm conversation deletion. Inspect the profile before continuing.",
            )
        })
    }
    async fn close(&self) -> Result<()> {
        self.queued(|s| {
            s.closed = true;
            fs::remove_file(s.root.join(".lock/owner"))?;
            fs::remove_dir(s.root.join(".lock"))?;
            Ok(())
        })
        .await
    }
}
pub(crate) fn same_file(a: &Metadata, b: &Metadata) -> bool {
    a.dev() == b.dev() && a.ino() == b.ino()
}
pub(crate) fn unchanged(a: &Metadata, b: &Metadata) -> bool {
    same_file(a, b)
        && a.len() == b.len()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
        && a.mode() == b.mode()
        && a.uid() == b.uid()
        && a.gid() == b.gid()
}
