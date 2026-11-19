use crate::{Error, Result, core::*};
use async_trait::async_trait;
use std::{
    ffi::CStr,
    fs::{self, File, Metadata, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::Mutex;
const LIMIT: u64 = 16 * 1024 * 1024;
const DIAGNOSTIC_LIMIT: u64 = 1024 * 1024;
const DIAGNOSTIC_LOG: &CStr = c"diagnostics.jsonl";
const DIAGNOSTIC_PREVIOUS: &CStr = c"diagnostics.previous.jsonl";
#[derive(Default)]
pub struct LoadedCatalog {
    pub records: Vec<ConversationRecord>,
    pub unreadable: Vec<String>,
}
#[async_trait]
pub trait ConversationStore: Checkpoint {
    async fn load(&self) -> Result<Vec<ConversationRecord>>;
    async fn load_catalog(&self) -> Result<LoadedCatalog> {
        Ok(LoadedCatalog {
            records: self.load().await?,
            unreadable: vec![],
        })
    }
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
    fn existing_record(&self, id: &str) -> Result<(PathBuf, Metadata)> {
        let path = self.file(id)?;
        let info = fs::symlink_metadata(&path)?;
        if !info.is_file() || info.uid() != unsafe { libc::getuid() } {
            return Err(Error::Storage);
        }
        Ok((path, info))
    }
    fn sync(&self) -> Result<()> {
        File::open(&self.root)?.sync_all()?;
        Ok(())
    }
}

// Keep log operations relative to an opened, verified directory. O_NOFOLLOW on
// the log alone would not protect against a replaced session-folder symlink.
struct DiagnosticDirectory {
    path: PathBuf,
    file: File,
}
impl DiagnosticDirectory {
    fn open(path: PathBuf, create: bool) -> Result<Option<Self>> {
        let info = match fs::symlink_metadata(&path) {
            Ok(info) => info,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if !create {
                    return Ok(None);
                }
                fs::DirBuilder::new().mode(0o700).create(&path)?;
                fs::symlink_metadata(&path)?
            }
            Err(error) => return Err(error.into()),
        };
        if !info.is_dir() || info.uid() != unsafe { libc::getuid() } || info.mode() & 0o077 != 0 {
            return Err(Error::Storage);
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&path)?;
        if !unchanged(&info, &file.metadata()?) {
            return Err(Error::Storage);
        }
        Ok(Some(Self { path, file }))
    }
    fn check(&self) -> Result<()> {
        let info = fs::symlink_metadata(&self.path)?;
        if !info.is_dir()
            || info.uid() != unsafe { libc::getuid() }
            || info.mode() & 0o077 != 0
            || !same_file(&info, &self.file.metadata()?)
        {
            return Err(Error::Storage);
        }
        Ok(())
    }
    fn metadata(&self, name: &CStr) -> Result<Option<libc::stat>> {
        let mut info = std::mem::MaybeUninit::<libc::stat>::uninit();
        // Both names are fixed single components; never follow a final symlink.
        if unsafe {
            libc::fstatat(
                self.file.as_raw_fd(),
                name.as_ptr(),
                info.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            let error = std::io::Error::last_os_error();
            return if error.kind() == std::io::ErrorKind::NotFound {
                Ok(None)
            } else {
                Err(error.into())
            };
        }
        let info = unsafe { info.assume_init() };
        if info.st_mode & libc::S_IFMT != libc::S_IFREG
            || info.st_uid != unsafe { libc::getuid() }
            || info.st_mode & 0o077 != 0
            || info.st_nlink != 1
        {
            return Err(Error::Storage);
        }
        Ok(Some(info))
    }
    // libc stat field widths differ between macOS and Linux.
    #[allow(clippy::unnecessary_cast)]
    fn append(&self, data: &[u8]) -> Result<()> {
        self.check()?;
        let mut current = self.metadata(DIAGNOSTIC_LOG)?;
        let previous = self.metadata(DIAGNOSTIC_PREVIOUS)?;
        if data.len() as u64 > DIAGNOSTIC_LIMIT
            || current
                .iter()
                .chain(previous.iter())
                .any(|info| info.st_size < 0 || info.st_size as u64 > DIAGNOSTIC_LIMIT)
        {
            return Err(Error::Storage);
        }
        if current
            .as_ref()
            .is_some_and(|info| info.st_size as u64 + data.len() as u64 > DIAGNOSTIC_LIMIT)
        {
            if unsafe {
                libc::renameat(
                    self.file.as_raw_fd(),
                    DIAGNOSTIC_LOG.as_ptr(),
                    self.file.as_raw_fd(),
                    DIAGNOSTIC_PREVIOUS.as_ptr(),
                )
            } != 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            current = None;
        }
        let mut flags =
            libc::O_WRONLY | libc::O_APPEND | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
        if current.is_none() {
            flags |= libc::O_CREAT | libc::O_EXCL;
        }
        let descriptor = unsafe {
            libc::openat(
                self.file.as_raw_fd(),
                DIAGNOSTIC_LOG.as_ptr(),
                flags,
                0o600 as libc::c_uint,
            )
        };
        if descriptor < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let mut file = unsafe { File::from_raw_fd(descriptor) };
        let info = file.metadata()?;
        if !info.is_file()
            || info.uid() != unsafe { libc::getuid() }
            || info.mode() & 0o077 != 0
            || info.nlink() != 1
            || match current {
                Some(before) => {
                    info.dev() != before.st_dev as u64
                        || info.ino() != before.st_ino as u64
                        || info.len() != before.st_size as u64
                        || info.mode() != before.st_mode as u32
                }
                None => info.len() != 0,
            }
        {
            return Err(Error::Storage);
        }
        file.write_all(data)?;
        file.sync_all()?;
        self.check()?;
        self.file.sync_all()?;
        Ok(())
    }
    fn delete(self) -> Result<()> {
        self.check()?;
        // Preflight everything before unlinking anything. Unknown contents are
        // not ours to delete, and remove_dir (never remove_dir_all) is deliberate.
        for entry in fs::read_dir(&self.path)? {
            let name = entry?.file_name();
            if name.as_encoded_bytes() != DIAGNOSTIC_LOG.to_bytes()
                && name.as_encoded_bytes() != DIAGNOSTIC_PREVIOUS.to_bytes()
            {
                return Err(Error::Storage);
            }
        }
        let current = self.metadata(DIAGNOSTIC_LOG)?;
        let previous = self.metadata(DIAGNOSTIC_PREVIOUS)?;
        self.check()?;
        for (name, info) in [(DIAGNOSTIC_LOG, current), (DIAGNOSTIC_PREVIOUS, previous)] {
            if info.is_some()
                && unsafe { libc::unlinkat(self.file.as_raw_fd(), name.as_ptr(), 0) } != 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        self.file.sync_all()?;
        self.check()?;
        fs::remove_dir(&self.path)?;
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
    async fn diagnostic(&self, entry: SessionDiagnostic) -> Result<()> {
        if !valid_id(&entry.conversation_id)
            || !valid_id(&entry.operation_id)
            || entry.message_id.as_ref().is_some_and(|id| !valid_id(id))
        {
            return Err(Error::Invalid("Invalid diagnostic ID."));
        }
        let mut data = serde_json::to_vec(&entry)?;
        data.push(b'\n');
        self.queued(move |s| {
            // Check inside the FIFO queue: a diagnostic arriving after deletion
            // must never recreate the session directory or its transcript.
            s.existing_record(&entry.conversation_id)?;
            let directory = DiagnosticDirectory::open(s.root.join(&entry.conversation_id), true)?
                .ok_or(Error::Storage)?;
            s.owner()?;
            directory.append(&data)?;
            s.owner()?;
            s.sync()
        })
        .await
        .map_err(|_| Error::Storage)
    }
}
#[async_trait]
impl ConversationStore for JsonConversationStore {
    async fn load(&self) -> Result<Vec<ConversationRecord>> {
        let catalog = self.load_catalog().await?;
        if !catalog.unreadable.is_empty() {
            return Err(Error::Invalid(
                "Some conversation records are unreadable; use catalog loading to inspect them.",
            ));
        }
        Ok(catalog.records)
    }
    async fn load_catalog(&self) -> Result<LoadedCatalog> {
        self.queued(|state| {
            let mut paths = fs::read_dir(&state.root)?
                .map(|e| e.map(|e| e.path()))
                .collect::<std::io::Result<Vec<_>>>()?;
            paths.sort();
            let mut catalog = LoadedCatalog::default();
            for path in paths {
                if path.extension().and_then(|s| s.to_str()) != Some("json")
                    || path.file_name().and_then(|s| s.to_str()) == Some("library.json")
                {
                    continue;
                }
                let id = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .ok_or(Error::Internal)?;
                let path = state.file(id)?;
                let info = fs::symlink_metadata(&path)?;
                // Links, special files and foreign ownership are store-integrity errors,
                // not ordinary corrupt transcripts. Never follow or silently quarantine them.
                if !info.is_file() || info.uid() != unsafe { libc::getuid() } {
                    return Err(Error::Storage);
                }
                if info.len() > LIMIT {
                    catalog.unreadable.push(id.to_owned());
                    continue;
                }
                let file = OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                    .open(&path)?;
                if !unchanged(&info, &file.metadata()?) {
                    return Err(Error::Storage);
                }
                let mut data = Vec::new();
                (&file).take(LIMIT + 1).read_to_end(&mut data)?;
                if !unchanged(&info, &file.metadata()?) || data.len() as u64 != info.len() {
                    return Err(Error::Storage);
                }
                match serde_json::from_slice::<ConversationRecord>(&data) {
                    Ok(record) if record.id == id && record.validate().is_ok() => {
                        catalog.records.push(record)
                    }
                    _ => catalog.unreadable.push(id.to_owned()),
                }
            }
            state.owner()?;
            Ok(catalog)
        })
        .await
        .map_err(|_| {
            Error::Invalid(
                "Conversation store integrity could not be confirmed. No data was overwritten.",
            )
        })
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
            // No parsing: corrupt/unreadable transcripts must remain deletable.
            let (record, info) = s.existing_record(&id)?;
            if let Some(directory) = DiagnosticDirectory::open(s.root.join(&id), false)? {
                directory.delete()?;
                s.sync()?;
            }
            s.owner()?;
            if !unchanged(&info, &fs::symlink_metadata(&record)?) {
                return Err(Error::Storage);
            }
            fs::remove_file(record)?;
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
