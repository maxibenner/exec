//! Gate real, isolated disk writes after commit and optionally lose one acknowledgement.
use async_trait::async_trait;
use exec_agent::{
    Error, Result,
    core::*,
    storage::{ConversationStore, DeletionManifest, JsonConversationStore, LoadedCatalog},
};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Write {
    Record,
    Library,
    PrepareDelete,
    Delete,
    CompleteDelete,
}
#[derive(Default)]
pub struct Gate {
    pub entered: CancellationToken,
    pub release: CancellationToken,
}
pub struct GatedStore {
    pub inner: Arc<JsonConversationStore>,
    gate: Mutex<Option<(Write, Arc<Gate>)>>,
    pub fail_before: Mutex<Option<Write>>,
    pub fail_after: Mutex<Option<Write>>,
    pub record_attempts: AtomicUsize,
    pub library_attempts: AtomicUsize,
    pub prepare_attempts: AtomicUsize,
    pub delete_attempts: AtomicUsize,
    pub complete_attempts: AtomicUsize,
}
impl GatedStore {
    pub fn new(inner: Arc<JsonConversationStore>) -> Arc<Self> {
        Arc::new(Self {
            inner,
            gate: Mutex::new(None),
            fail_before: Mutex::new(None),
            fail_after: Mutex::new(None),
            record_attempts: AtomicUsize::new(0),
            library_attempts: AtomicUsize::new(0),
            prepare_attempts: AtomicUsize::new(0),
            delete_attempts: AtomicUsize::new(0),
            complete_attempts: AtomicUsize::new(0),
        })
    }
    pub fn gate(&self, write: Write) -> Arc<Gate> {
        let gate = Arc::new(Gate::default());
        *self.gate.lock().unwrap() = Some((write, gate.clone()));
        gate
    }
    fn begin(&self, write: Write) -> Result<()> {
        let attempts = match write {
            Write::Record => &self.record_attempts,
            Write::Library => &self.library_attempts,
            Write::PrepareDelete => &self.prepare_attempts,
            Write::Delete => &self.delete_attempts,
            Write::CompleteDelete => &self.complete_attempts,
        };
        attempts.fetch_add(1, Ordering::SeqCst);
        let mut fail = self.fail_before.lock().unwrap();
        if *fail == Some(write) {
            *fail = None;
            Err(Error::Storage)
        } else {
            Ok(())
        }
    }
    async fn acknowledge(&self, write: Write) -> Result<()> {
        let gate = {
            let mut pending = self.gate.lock().unwrap();
            if pending.as_ref().is_some_and(|(kind, _)| *kind == write) {
                pending.take().map(|(_, gate)| gate)
            } else {
                None
            }
        };
        if let Some(gate) = gate {
            gate.entered.cancel();
            gate.release.cancelled().await;
        }
        let mut fail = self.fail_after.lock().unwrap();
        if *fail == Some(write) {
            *fail = None;
            Err(Error::Storage)
        } else {
            Ok(())
        }
    }
}
#[async_trait]
impl Checkpoint for GatedStore {
    async fn save(&self, record: ConversationRecord) -> Result<()> {
        self.begin(Write::Record)?;
        self.inner.save(record).await?;
        self.acknowledge(Write::Record).await
    }
}
#[async_trait]
impl ConversationStore for GatedStore {
    async fn load(&self) -> Result<Vec<ConversationRecord>> {
        self.inner.load().await
    }
    async fn load_catalog(&self) -> Result<LoadedCatalog> {
        self.inner.load_catalog().await
    }
    async fn load_library(&self) -> Result<LibraryConfiguration> {
        self.inner.load_library().await
    }
    async fn save_library(&self, library: LibraryConfiguration) -> Result<()> {
        self.begin(Write::Library)?;
        self.inner.save_library(library).await?;
        self.acknowledge(Write::Library).await
    }
    async fn prepare_delete(&self, manifest: DeletionManifest) -> Result<()> {
        self.begin(Write::PrepareDelete)?;
        self.inner.prepare_delete(manifest).await?;
        self.acknowledge(Write::PrepareDelete).await
    }
    async fn load_deletions(&self) -> Result<Vec<DeletionManifest>> {
        self.inner.load_deletions().await
    }
    async fn complete_delete(&self, id: String) -> Result<()> {
        self.begin(Write::CompleteDelete)?;
        self.inner.complete_delete(id).await?;
        self.acknowledge(Write::CompleteDelete).await
    }
    async fn delete(&self, id: String) -> Result<()> {
        self.begin(Write::Delete)?;
        self.inner.delete(id).await?;
        self.acknowledge(Write::Delete).await
    }
    async fn close(&self) -> Result<()> {
        self.inner.close().await
    }
}
pub async fn entered(gate: &Gate) {
    tokio::time::timeout(std::time::Duration::from_secs(5), gate.entered.cancelled())
        .await
        .unwrap();
}
pub async fn eventually(mut condition: impl FnMut() -> bool) {
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while !condition() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}
