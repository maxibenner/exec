use crate::{Error, Result, core::*, storage::ConversationStore};
use futures_util::FutureExt;
use std::panic::AssertUnwindSafe;
use std::{
    collections::{BTreeMap, HashSet},
    sync::{Arc, Mutex},
};

#[derive(Default)]
struct Catalog {
    conversations: BTreeMap<String, Arc<Conversation>>,
    mutating: HashSet<String>,
    closed: bool,
    library: LibraryConfiguration,
    library_busy: bool,
    library_error: bool,
    account_busy: bool,
    unreadable: HashSet<String>,
}
pub struct AgentManager {
    catalog: Mutex<Catalog>,
    store: Option<Arc<dyn ConversationStore>>,
}
impl Default for AgentManager {
    fn default() -> Self {
        Self {
            catalog: Mutex::new(Catalog::default()),
            store: None,
        }
    }
}
impl AgentManager {
    pub async fn open(
        store: Arc<dyn ConversationStore>,
        configure: impl Fn(&ConversationRecord) -> (Arc<dyn ChatProvider>, Vec<Arc<dyn Tool>>),
    ) -> Result<Arc<Self>> {
        let manager = Arc::new(Self {
            catalog: Mutex::new(Catalog::default()),
            store: Some(store.clone()),
        });
        let restore = async {
            let library = store.load_library().await?;
            manager.catalog.lock().unwrap().library = library;
            let catalog = store.load_catalog().await?;
            manager.catalog.lock().unwrap().unreadable = catalog.unreadable.into_iter().collect();
            for record in catalog.records {
                let (provider, tools) = configure(&record);
                let mut options = ConversationOptions::new(
                    provider,
                    record.model.clone(),
                    record.workspace.clone(),
                );
                options.tools = tools;
                options.checkpoint = Some(store.clone());
                let active = record.operation.as_ref().is_some_and(|o| o.state.active());
                let conversation = Conversation::new(options, Some(record))?;
                if active {
                    store.save(conversation.record()).await?;
                }
                manager
                    .catalog
                    .lock()
                    .unwrap()
                    .conversations
                    .insert(conversation.id.clone(), conversation);
            }
            Ok::<_, Error>(())
        }
        .await;
        if restore.is_err() {
            let _ = store.close().await;
            return Err(Error::Invalid(
                "Could not restore conversations. No work was resumed; inspect the profile before continuing.",
            ));
        }
        Ok(manager)
    }
    pub async fn create(&self, mut options: ConversationOptions) -> Result<Arc<Conversation>> {
        if let Some(store) = &self.store {
            options.checkpoint = Some(store.clone());
        }
        if self.catalog.lock().unwrap().account_busy {
            return Err(Error::Busy);
        }
        let conversation = Conversation::new(options, None)?;
        self.insert_conversation(conversation).await
    }
    async fn insert_conversation(
        &self,
        conversation: Arc<Conversation>,
    ) -> Result<Arc<Conversation>> {
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed {
                return Err(Error::Invalid("Agent manager is closed."));
            }
            if c.account_busy {
                return Err(Error::Busy);
            }
            c.mutating.insert(conversation.id.clone());
        }
        let saved = if let Some(store) = &self.store {
            store.save(conversation.record()).await
        } else {
            Ok(())
        };
        let mut c = self.catalog.lock().unwrap();
        c.mutating.remove(&conversation.id);
        if let Err(error) = saved {
            conversation.dispose()?;
            return Err(error);
        }
        c.conversations
            .insert(conversation.id.clone(), conversation.clone());
        Ok(conversation)
    }
    pub fn connections(&self, provider: &dyn ChatProvider) -> Vec<ProviderConnection> {
        provider.connections()
    }
    pub async fn set_credential(
        self: &Arc<Self>,
        provider: Arc<dyn ChatProvider>,
        id: &str,
        credential: Option<String>,
    ) -> Result<Vec<ProviderConnection>> {
        {
            let mut catalog = self.catalog.lock().unwrap();
            if catalog.closed {
                return Err(Error::Invalid("Agent manager is closed."));
            }
            if catalog.account_busy
                || !catalog.mutating.is_empty()
                || catalog.conversations.values().any(|c| c.busy())
            {
                return Err(Error::Busy);
            }
            catalog.account_busy = true;
        }
        let manager = self.clone();
        let id = id.to_owned();
        tokio::spawn(async move {
            let result = AssertUnwindSafe(provider.set_credential(&id, credential))
                .catch_unwind()
                .await
                .unwrap_or(Err(Error::Internal));
            manager.catalog.lock().unwrap().account_busy = false;
            result?;
            Ok(provider.connections())
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    pub fn library_configuration(&self) -> Result<LibraryConfiguration> {
        let c = self.catalog.lock().unwrap();
        if c.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        if c.library_error {
            return Err(Error::Storage);
        }
        Ok(c.library.clone())
    }
    pub async fn update_library(
        &self,
        library: LibraryConfiguration,
    ) -> Result<LibraryConfiguration> {
        library.validate()?;
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed {
                return Err(Error::Invalid("Agent manager is closed."));
            }
            if c.library_error {
                return Err(Error::Storage);
            }
            if c.library_busy {
                return Err(Error::Busy);
            }
            c.library_busy = true;
        }
        let saved = if let Some(store) = &self.store {
            store.save_library(library.clone()).await
        } else {
            Ok(())
        };
        let mut c = self.catalog.lock().unwrap();
        c.library_busy = false;
        if saved.is_err() {
            c.library_error = true;
            return Err(Error::Storage);
        }
        c.library = library.clone();
        Ok(library)
    }
    pub async fn create_session(
        &self,
        provider: Arc<dyn ChatProvider>,
        tools: Vec<Arc<dyn Tool>>,
        model: Option<String>,
        workspace: String,
        settings: Option<SessionSettings>,
    ) -> Result<Arc<Conversation>> {
        let defaults = self.library_configuration()?;
        let model = model.or(defaults.default_model).ok_or(Error::Invalid(
            "Select a model or configure a default model.",
        ))?;
        if !valid_model_id(&model) {
            return Err(Error::Invalid("Invalid model."));
        }
        let settings = settings.unwrap_or(defaults.settings);
        settings.validate()?;
        if !std::path::Path::new(&workspace).is_absolute() {
            return Err(Error::Invalid("Workspace must be absolute."));
        }
        let workspace = tokio::fs::canonicalize(workspace)
            .await
            .map_err(|_| Error::Invalid("Workspace must be an existing directory."))?;
        if !tokio::fs::metadata(&workspace)
            .await
            .map_err(|_| Error::Invalid("Workspace must be an existing directory."))?
            .is_dir()
        {
            return Err(Error::Invalid("Workspace must be a directory."));
        }
        let mut options = ConversationOptions::new(provider, model, workspace.to_string_lossy());
        options.tools = tools;
        options.settings = settings;
        self.create(options).await
    }
    pub async fn rename(&self, id: &str, title: String) -> Result<ConversationSnapshot> {
        self.get(id)?
            .mutate_record(move |record| {
                record.metadata.title = Some(title);
                record.metadata.manually_named = true;
                Ok(())
            })
            .await
    }
    pub async fn select_model(&self, id: &str, model: String) -> Result<ConversationSnapshot> {
        if !valid_model_id(&model) {
            return Err(Error::Invalid("Invalid model."));
        }
        self.get(id)?
            .mutate_record(move |record| {
                record.model = model;
                Ok(())
            })
            .await
    }
    pub async fn fork(
        &self,
        id: &str,
        provider: Arc<dyn ChatProvider>,
        tools: Vec<Arc<dyn Tool>>,
    ) -> Result<Arc<Conversation>> {
        let record = self.get(id)?.fork_record()?;
        let mut options =
            ConversationOptions::new(provider, record.model.clone(), record.workspace.clone());
        options.tools = tools;
        options.checkpoint = self.store.clone().map(|s| s as Arc<dyn Checkpoint>);
        self.insert_conversation(Conversation::new(options, Some(record))?)
            .await
    }
    /// Load project instructions only for the first accepted turn, then freeze them.
    /// The runner atomically accepts input and persists the snapshot before inference.
    pub async fn submit(&self, id: &str, text: String) -> Result<Submission> {
        if self.catalog.lock().unwrap().account_busy {
            return Err(Error::Busy);
        }
        let conversation = self.get(id)?;
        if conversation.busy() {
            return Err(Error::Busy);
        }
        let snapshot = conversation.snapshot();
        let instructions = if snapshot.configuration.instructions_frozen {
            None
        } else {
            crate::workspace_instructions::load(snapshot.workspace).await?
        };
        let catalog = self.catalog.lock().unwrap();
        if catalog.closed || catalog.account_busy {
            return Err(Error::Busy);
        }
        conversation.submit_with_instructions(text, instructions)
    }
    pub fn steer(&self, id: &str, operation_id: &str, text: String) -> Result<String> {
        self.get(id)?.steer(operation_id, text)
    }
    pub async fn update_settings(
        &self,
        id: &str,
        settings: SessionSettings,
    ) -> Result<ConversationSnapshot> {
        self.get(id)?.update_settings(settings).await
    }
    pub fn get(&self, id: &str) -> Result<Arc<Conversation>> {
        let c = self.catalog.lock().unwrap();
        if c.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        if c.mutating.contains(id) {
            return Err(Error::Invalid("Conversation catalog operation is pending."));
        }
        c.conversations
            .get(id)
            .cloned()
            .ok_or(Error::Invalid("Conversation not found."))
    }
    pub fn unreadable_sessions(&self) -> Vec<String> {
        let catalog = self.catalog.lock().unwrap();
        let mut ids: Vec<_> = catalog.unreadable.iter().cloned().collect();
        ids.sort();
        ids
    }
    pub fn list(&self) -> Result<Vec<ConversationSnapshot>> {
        let c = self.catalog.lock().unwrap();
        if c.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        let mut result: Vec<_> = c.conversations.values().map(|c| c.snapshot()).collect();
        result.sort_by_key(|s| {
            (
                c.library
                    .order
                    .iter()
                    .position(|id| id == &s.id)
                    .unwrap_or(usize::MAX),
                s.id.clone(),
            )
        });
        Ok(result)
    }
    pub async fn delete(&self, id: &str) -> Result<()> {
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed || c.mutating.contains(id) {
                return Err(Error::Internal);
            }
            if let Some(conversation) = c.conversations.get(id) {
                conversation.dispose()?;
            } else if !c.unreadable.contains(id) {
                return Err(Error::Invalid("Conversation not found."));
            }
            c.mutating.insert(id.into());
        }
        let deleted = if let Some(store) = &self.store {
            store.delete(id.into()).await
        } else {
            Ok(())
        };
        let mut c = self.catalog.lock().unwrap();
        c.mutating.remove(id);
        deleted?;
        c.conversations.remove(id);
        c.unreadable.remove(id);
        Ok(())
    }
    pub async fn close(&self) -> Result<()> {
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed {
                return Err(Error::Invalid("Agent manager is closed."));
            }
            if c.account_busy
                || c.library_busy
                || !c.mutating.is_empty()
                || c.conversations.values().any(|c| c.busy())
            {
                return Err(Error::Invalid(
                    "Stop and await active conversations/catalog operations before closing the manager.",
                ));
            }
            // Holding the catalog lock excludes catalog operations. dispose also atomically excludes submissions through retained references.
            for conversation in c.conversations.values() {
                conversation.dispose()?;
            }
            c.closed = true;
        }
        if let Some(store) = &self.store {
            store.close().await?;
        }
        Ok(())
    }
    pub async fn cancel_and_wait(&self) -> Result<()> {
        let conversations: Vec<_> = self
            .catalog
            .lock()
            .unwrap()
            .conversations
            .values()
            .cloned()
            .collect();
        for conversation in &conversations {
            if let Some(op) = conversation.snapshot().operation {
                conversation.cancel(&op.id);
            }
        }
        for conversation in conversations {
            let (_, mut events) = conversation.subscribe();
            while conversation.busy() {
                if events.recv().await.is_err() {
                    events = conversation.subscribe().1;
                }
            }
        }
        Ok(())
    }
}
