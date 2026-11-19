use crate::{Error, Result, core::*, storage::ConversationStore};
use futures_util::FutureExt;
use std::panic::AssertUnwindSafe;
use std::{
    collections::{BTreeMap, HashSet},
    sync::{Arc, Mutex},
};

#[derive(Default)]
struct Catalog {
    native: Arc<crate::native::NativeHub>,
    conversations: BTreeMap<String, Arc<Conversation>>,
    mutating: HashSet<String>,
    closed: bool,
    library: LibraryConfiguration,
    library_busy: bool,
    library_error: bool,
    account_busy: bool,
    account_epoch: u64,
    connection_attempt: Option<ConnectionAttempt>,
    connection_cancel: Option<tokio_util::sync::CancellationToken>,
    unreadable: HashSet<String>,
    logs: Option<Arc<crate::shell_logs::ShellLogStore>>,
    forking: usize,
    images: Option<Arc<crate::images::ImageStore>>,
    files: Option<Arc<crate::files::FileStore>>,
}
pub struct AgentManager {
    changes: Arc<ChangeHub>,
    catalog: Mutex<Catalog>,
    store: Option<Arc<dyn ConversationStore>>,
}
impl Default for AgentManager {
    fn default() -> Self {
        Self {
            changes: Arc::new(ChangeHub::default()),
            catalog: Mutex::new(Catalog::default()),
            store: None,
        }
    }
}
async fn canonical_workspace(workspace: String) -> Result<String> {
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
    Ok(workspace.to_string_lossy().into_owned())
}
impl AgentManager {
    pub fn subscribe_changes(&self) -> tokio::sync::watch::Receiver<ChangeNotification> {
        self.changes.subscribe()
    }
    pub async fn open(
        store: Arc<dyn ConversationStore>,
        configure: impl Fn(&ConversationRecord) -> (Arc<dyn ChatProvider>, Vec<Arc<dyn Tool>>),
    ) -> Result<Arc<Self>> {
        let manager = Arc::new(Self {
            changes: Arc::new(ChangeHub::default()),
            catalog: Mutex::new(Catalog::default()),
            store: Some(store.clone()),
        });
        let restore = async {
            let library = store.load_library().await?;
            manager.catalog.lock().unwrap().library = library;
            let catalog = store.load_catalog().await?;
            manager.catalog.lock().unwrap().unreadable = catalog.unreadable.into_iter().collect();
            for mut record in catalog.records {
                let (provider, tools) = configure(&record);
                let mut options = ConversationOptions::new(
                    provider,
                    record.model.clone(),
                    record.workspace.clone(),
                );
                options.tools = if record.metadata.parent.is_none() {
                    manager.delegation_tools(options.provider.clone(), tools)
                } else {
                    tools
                        .into_iter()
                        .filter(|tool| tool.definition().name != "delegate")
                        .collect()
                };
                options.checkpoint = Some(store.clone());
                // Apply the current session budget to restored sessions as well.
                let budget_changed = record.max_steps != options.max_steps;
                record.max_steps = options.max_steps;
                let active = record.operation.as_ref().is_some_and(|o| o.state.active());
                let conversation = Conversation::new(options, Some(record))?;
                if active || budget_changed {
                    store.save(conversation.record()).await?;
                }
                conversation.attach_changes(&manager.changes);
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
        options.images = self
            .catalog
            .lock()
            .unwrap()
            .images
            .clone()
            .map(|s| s as Arc<dyn ImageReader>);
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
        conversation.attach_changes(&self.changes);
        c.conversations
            .insert(conversation.id.clone(), conversation.clone());
        Ok(conversation)
    }
    pub async fn fetch_content(
        &self,
        url: &str,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<crate::content_fetch::FetchedContent> {
        if self.catalog.lock().unwrap().closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        crate::content_fetch::ContentFetcher::default()
            .fetch(url, cancel)
            .await
    }
    fn provider_epoch(&self) -> Result<u64> {
        let catalog = self.catalog.lock().unwrap();
        if catalog.closed || catalog.account_busy {
            return Err(Error::Busy);
        }
        Ok(catalog.account_epoch)
    }
    fn check_provider_epoch(&self, epoch: u64) -> Result<()> {
        let catalog = self.catalog.lock().unwrap();
        if catalog.closed || catalog.account_busy || catalog.account_epoch != epoch {
            return Err(Error::Cancelled);
        }
        Ok(())
    }
    pub async fn discover_models(
        &self,
        provider: Arc<dyn ChatProvider>,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<Vec<ChatModel>> {
        let epoch = self.provider_epoch()?;
        let result = provider.models(cancel).await;
        // Provider caches may have changed even if discovery only partly succeeded.
        self.changes.provider_metadata_changed();
        self.check_provider_epoch(epoch)?;
        result
    }
    pub async fn search_web(
        &self,
        provider: Arc<dyn ChatProvider>,
        model: &str,
        query: String,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<WebSearchResult> {
        search_query(&query)?;
        let epoch = self.provider_epoch()?;
        let result = provider.search_web(model, query, cancel).await?;
        self.check_provider_epoch(epoch)?;
        Ok(result)
    }
    pub async fn account_balances(
        &self,
        provider: Arc<dyn ChatProvider>,
        id: &str,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<Vec<AccountBalance>> {
        let epoch = self.provider_epoch()?;
        let result = provider.account_balances(id, cancel).await?;
        self.check_provider_epoch(epoch)?;
        Ok(result)
    }
    pub async fn account_usage(
        &self,
        provider: Arc<dyn ChatProvider>,
        id: &str,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<AccountUsage> {
        let epoch = self.provider_epoch()?;
        let result = provider.account_usage(id, cancel).await?;
        self.check_provider_epoch(epoch)?;
        Ok(result)
    }
    pub fn connection_attempt(&self) -> Option<ConnectionAttempt> {
        self.catalog.lock().unwrap().connection_attempt.clone()
    }
    pub fn cancel_connection(&self, id: &str) -> Result<()> {
        let c = self.catalog.lock().unwrap();
        if c.connection_attempt
            .as_ref()
            .is_none_or(|a| a.id != id || a.state != "running")
        {
            return Err(Error::Invalid("Connection attempt is no longer active."));
        }
        c.connection_cancel.as_ref().ok_or(Error::Busy)?.cancel();
        Ok(())
    }
    pub async fn connect(
        self: &Arc<Self>,
        provider: Arc<dyn ChatProvider>,
        id: &str,
    ) -> Result<ConnectionChallenge> {
        self.connect_with_method(provider, id, ConnectionMethod::Browser)
            .await
    }
    pub async fn connect_with_method(
        self: &Arc<Self>,
        provider: Arc<dyn ChatProvider>,
        id: &str,
        method: ConnectionMethod,
    ) -> Result<ConnectionChallenge> {
        let cancel = tokio_util::sync::CancellationToken::new();
        let attempt = ConnectionAttempt {
            id: new_id(),
            provider: id.into(),
            state: "running".into(),
            error: None,
        };
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed
                || c.account_busy
                || !c.mutating.is_empty()
                || c.conversations.values().any(|c| c.busy())
            {
                return Err(Error::Busy);
            }
            c.account_busy = true;
            c.connection_attempt = Some(attempt.clone());
            c.connection_cancel = Some(cancel.clone());
            c.account_epoch = c.account_epoch.wrapping_add(1);
        }
        let (challenge, receiver) = tokio::sync::oneshot::channel();
        let manager = self.clone();
        let id = id.to_owned();
        let startup_cancel = cancel.clone();
        tokio::spawn(async move {
            let result = AssertUnwindSafe(provider.connect(&id, method, challenge, cancel.clone()))
                .catch_unwind()
                .await
                .unwrap_or(Err(Error::Internal));
            let mut c = manager.catalog.lock().unwrap();
            c.account_busy = false;
            c.account_epoch = c.account_epoch.wrapping_add(1);
            c.connection_cancel = None;
            if let Some(attempt) = &mut c.connection_attempt {
                attempt.state = if result.is_ok() {
                    "completed"
                } else if cancel.is_cancelled() {
                    "interrupted"
                } else {
                    "failed"
                }
                .into();
                attempt.error = result.err().map(|e| e.to_string());
            }
            manager.changes.provider_metadata_changed();
        });
        let challenge = match tokio::time::timeout(std::time::Duration::from_secs(45), receiver)
            .await
        {
            Ok(Ok(challenge)) => challenge,
            _ => {
                startup_cancel.cancel();
                return Err(Error::Invalid(
                    "Could not start provider authentication. Inspect connection-attempt status.",
                ));
            }
        };
        Ok(ConnectionChallenge {
            attempt,
            authorization_url: challenge.authorization_url,
            device_code: challenge.device_code,
        })
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
            {
                let mut catalog = manager.catalog.lock().unwrap();
                catalog.account_busy = false;
                catalog.account_epoch = catalog.account_epoch.wrapping_add(1);
                manager.changes.provider_metadata_changed();
            }
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
        self.modify_library(|_| Ok(library)).await
    }
    /// Apply only supplied fields against the latest configuration under the catalog lock.
    pub async fn patch_library(&self, patch: serde_json::Value) -> Result<LibraryConfiguration> {
        self.modify_library(|current| {
            let patch = patch
                .as_object()
                .ok_or(Error::Invalid("Expected a settings object."))?;
            let mut value = serde_json::to_value(current).map_err(|_| Error::Internal)?;
            for (key, replacement) in patch {
                match key.as_str() {
                    "automaticTitles" | "defaultModel" | "defaultDisabledTools" | "order" => {
                        value[key] = replacement.clone()
                    }
                    "settings" => {
                        let settings = replacement
                            .as_object()
                            .ok_or(Error::Invalid("Expected settings fields."))?;
                        for (key, replacement) in settings {
                            if !matches!(
                                key.as_str(),
                                "systemPrompt" | "autoApprove" | "effort" | "searchModel"
                            ) {
                                return Err(Error::Invalid("Unknown settings field."));
                            }
                            value["settings"][key] = replacement.clone();
                        }
                    }
                    _ => return Err(Error::Invalid("Unknown library field.")),
                }
            }
            serde_json::from_value(value).map_err(|_| Error::Invalid("Invalid settings value."))
        })
        .await
    }
    async fn modify_library(
        &self,
        change: impl FnOnce(&LibraryConfiguration) -> Result<LibraryConfiguration>,
    ) -> Result<LibraryConfiguration> {
        let library;
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
            library = change(&c.library)?;
            library.validate()?;
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
            self.changes.catalog_changed();
            return Err(Error::Storage);
        }
        c.library = library.clone();
        self.changes.catalog_changed();
        Ok(library)
    }
    fn delegation_tools(
        self: &Arc<Self>,
        provider: Arc<dyn ChatProvider>,
        mut tools: Vec<Arc<dyn Tool>>,
    ) -> Vec<Arc<dyn Tool>> {
        tools.retain(|tool| tool.definition().name != "delegate");
        tools.push(crate::tools::create_delegate_tool(
            self,
            provider,
            tools.clone(),
        ));
        tools
    }

    /// Only the executing parent tool can create a child. Persist its provenance
    /// before starting inference; never resume or recreate it after interruption.
    pub(crate) async fn create_children(
        &self,
        context: &ToolContext,
        titles: &[String],
        provider: Arc<dyn ChatProvider>,
        tools: Vec<Arc<dyn Tool>>,
    ) -> Result<Vec<(Arc<Conversation>, Option<String>)>> {
        let parent = {
            let catalog = self.catalog.lock().unwrap();
            if catalog.closed
                || catalog.account_busy
                || catalog.mutating.contains(&context.conversation_id)
            {
                return Err(Error::Busy);
            }
            catalog
                .conversations
                .get(&context.conversation_id)
                .ok_or(Error::Invalid("Parent conversation not found."))?
                .reserve_delegation(context, titles.len())?
        };
        let mut children = Vec::with_capacity(titles.len());
        for title in titles {
            crate::check_cancel(&context.cancel)?;
            let mut options = ConversationOptions::new(
                provider.clone(),
                parent.model.clone(),
                parent.workspace.clone(),
            );
            options.tools = tools
                .iter()
                .filter(|tool| tool.definition().name != "delegate")
                .cloned()
                .collect();
            options.settings = parent.configuration.settings.clone();
            options.metadata.disabled_tools = parent.metadata.disabled_tools.clone();
            options.metadata.title = Some(title.clone());
            options.metadata.parent = Some(SessionParent {
                session_id: context.conversation_id.clone(),
                operation_id: context.operation_id.clone(),
                tool_call_id: context.call_id.clone(),
            });
            let child = self.create(options).await?;
            children.push((child, parent.configuration.workspace_instructions.clone()));
        }
        Ok(children)
    }

    pub async fn create_session(
        self: &Arc<Self>,
        provider: Arc<dyn ChatProvider>,
        tools: Vec<Arc<dyn Tool>>,
        model: Option<String>,
        workspace: String,
        settings: Option<SessionSettings>,
        disabled_tools: Option<Vec<String>>,
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
        let workspace = canonical_workspace(workspace).await?;
        let mut options = ConversationOptions::new(provider, model, workspace);
        options.tools = self.delegation_tools(options.provider.clone(), tools);
        options.settings = settings;
        // Explicit selections must match the current catalog. Inherited defaults, like
        // persisted session selections, retain names while tools are unavailable.
        if disabled_tools.as_ref().is_some_and(|names| {
            names.iter().any(|name| {
                !options
                    .tools
                    .iter()
                    .any(|tool| tool.definition().name == *name)
            })
        }) {
            return Err(Error::Invalid("Unknown disabled tool."));
        }
        options.metadata.disabled_tools = disabled_tools.unwrap_or(defaults.default_disabled_tools);
        self.create(options).await
    }
    pub async fn rename(&self, id: &str, title: String) -> Result<ConversationSnapshot> {
        self.get(id)?.rename(title).await
    }
    pub async fn select_model(&self, id: &str, model: String) -> Result<ConversationSnapshot> {
        if !valid_model_id(&model) {
            return Err(Error::Invalid("Invalid model."));
        }
        self.get(id)?
            .mutate_record(move |record| {
                record.model = model;
                record.usage = None;
                Ok(())
            })
            .await
    }
    pub async fn select_workspace(
        &self,
        id: &str,
        workspace: String,
    ) -> Result<ConversationSnapshot> {
        let conversation = self.get(id)?;
        let workspace = canonical_workspace(workspace).await?;
        conversation
            .mutate_record(move |record| {
                if record.workspace_locked() {
                    return Err(Error::WorkspaceLocked);
                }
                record.workspace = workspace;
                record
                    .configuration
                    .as_mut()
                    .unwrap()
                    .workspace_instructions = None;
                record.provider_state = None;
                record.usage = None;
                Ok(())
            })
            .await
    }
    /// Cancel and settle the family before resetting context, preserving configuration
    /// and shared assets. Reservations also block already acquired handles.
    pub async fn clear(self: &Arc<Self>, id: &str) -> Result<ConversationSnapshot> {
        let (conversation, family, reservations) = {
            let catalog = self.catalog.lock().unwrap();
            if catalog.closed || catalog.account_busy {
                return Err(Error::Busy);
            }
            let conversation = catalog
                .conversations
                .get(id)
                .ok_or(Error::Invalid("Conversation not found."))?
                .clone();
            let ids = Self::deletion_family(&catalog, id);
            if ids.iter().any(|id| catalog.mutating.contains(id))
                || Self::delegation_owned(&catalog, &conversation)
            {
                return Err(Error::Busy);
            }
            let family: Vec<_> = ids
                .iter()
                .map(|id| catalog.conversations[id].clone())
                .collect();
            let reservations = family
                .iter()
                .map(|c| c.reserve_clear())
                .collect::<Result<Vec<_>>>()?;
            for session in &family {
                if let Some(op) = session.snapshot().operation {
                    session.cancel(&op.id);
                }
            }
            (conversation, family, reservations)
        };
        let manager = self.clone();
        // Own cancellation, settlement and persistence even if the caller disconnects.
        tokio::spawn(async move {
            for session in &family {
                session.settle_active().await;
            }
            let mut reservations = reservations;
            let task = {
                let catalog = manager.catalog.lock().unwrap();
                // Delegation creation already in flight may have inserted more children.
                // Parent settlement has awaited their executors; reserve survivors too.
                for id in Self::deletion_family(&catalog, &conversation.id) {
                    if !family.iter().any(|session| session.id == id) {
                        reservations.push(catalog.conversations[&id].reserve_idle()?);
                    }
                }
                conversation.start_clear(reservations)?
            };
            task.await.map_err(|_| Error::Internal)?
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    pub async fn fork(
        self: &Arc<Self>,
        id: &str,
        provider: Arc<dyn ChatProvider>,
        tools: Vec<Arc<dyn Tool>>,
    ) -> Result<Arc<Conversation>> {
        let record = {
            let mut catalog = self.catalog.lock().unwrap();
            if catalog.closed || catalog.account_busy || catalog.mutating.contains(id) {
                return Err(Error::Busy);
            }
            let record = catalog
                .conversations
                .get(id)
                .ok_or(Error::Invalid("Conversation not found."))?
                .fork_record()?;
            catalog.forking += 1;
            record
        };
        let mut options =
            ConversationOptions::new(provider, record.model.clone(), record.workspace.clone());
        options.tools = self.delegation_tools(options.provider.clone(), tools);
        options.images = self
            .catalog
            .lock()
            .unwrap()
            .images
            .clone()
            .map(|s| s as Arc<dyn ImageReader>);
        options.checkpoint = self.store.clone().map(|s| s as Arc<dyn Checkpoint>);
        let result = match Conversation::new(options, Some(record)) {
            Ok(conversation) => self.insert_conversation(conversation).await,
            Err(error) => Err(error),
        };
        self.catalog.lock().unwrap().forking -= 1;
        result
    }

    /// Load project instructions only for the first accepted turn, then freeze them.
    /// The runner atomically accepts input and persists the snapshot before inference.
    pub async fn submit(&self, id: &str, text: String) -> Result<Submission> {
        self.submit_images(id, text, vec![]).await
    }
    pub async fn submit_images(
        &self,
        id: &str,
        text: String,
        images: Vec<ImageRef>,
    ) -> Result<Submission> {
        self.submit_attachments(id, text, images, vec![]).await
    }
    pub async fn submit_attachments(
        &self,
        id: &str,
        text: String,
        images: Vec<ImageRef>,
        file_ids: Vec<String>,
    ) -> Result<Submission> {
        let files = self.resolve_files(id, file_ids).await?;
        if self.catalog.lock().unwrap().account_busy {
            return Err(Error::Busy);
        }
        let conversation = self.get(id)?;
        if conversation.busy() {
            return Err(Error::Busy);
        }
        self.check_delegation_owner(&conversation)?;
        let snapshot = conversation.snapshot();
        let instructions = if snapshot.configuration.instructions_frozen {
            None
        } else {
            crate::workspace_instructions::load(snapshot.workspace.clone()).await?
        };
        let catalog = self.catalog.lock().unwrap();
        if catalog.closed || catalog.account_busy {
            return Err(Error::Busy);
        }
        conversation.submit_attachments_with_naming(
            text,
            images,
            files,
            instructions,
            !catalog.library_error && catalog.library.automatic_titles,
            Some(&snapshot.workspace),
        )
    }
    fn check_delegation_owner(&self, conversation: &Conversation) -> Result<()> {
        let catalog = self.catalog.lock().unwrap();
        if Self::delegation_owned(&catalog, conversation) {
            return Err(Error::Busy);
        }
        Ok(())
    }
    fn delegation_owned(catalog: &Catalog, conversation: &Conversation) -> bool {
        conversation.parent().is_some_and(|parent| {
            catalog
                .conversations
                .get(&parent.session_id)
                .is_some_and(|owner| {
                    owner
                        .snapshot()
                        .operation
                        .is_some_and(|op| op.id == parent.operation_id && op.state.active())
                })
        })
    }
    pub fn compact(&self, id: &str) -> Result<Submission> {
        self.check_delegation_owner(self.get(id)?.as_ref())?;
        let catalog = self.catalog.lock().unwrap();
        if catalog.closed || catalog.account_busy {
            return Err(Error::Busy);
        }
        catalog
            .conversations
            .get(id)
            .ok_or(Error::Invalid("Conversation not found."))?
            .compact()
    }
    pub fn steer(&self, id: &str, operation_id: &str, text: String) -> Result<String> {
        self.steer_images(id, operation_id, text, vec![])
    }
    pub fn steer_images(
        &self,
        id: &str,
        operation_id: &str,
        text: String,
        images: Vec<ImageRef>,
    ) -> Result<String> {
        self.get(id)?.steer_images(operation_id, text, images)
    }
    pub async fn steer_attachments(
        &self,
        id: &str,
        operation_id: &str,
        text: String,
        images: Vec<ImageRef>,
        file_ids: Vec<String>,
    ) -> Result<String> {
        let files = self.resolve_files(id, file_ids).await?;
        self.get(id)?
            .steer_attachments(operation_id, text, images, files)
    }
    async fn resolve_files(&self, id: &str, ids: Vec<String>) -> Result<Vec<FileRef>> {
        if ids.is_empty() {
            return Ok(vec![]);
        }
        let resources = self.get(id)?.resources();
        if ids.len() > 4
            || ids.iter().any(|id| {
                !resources
                    .iter()
                    .any(|r| r.id == *id && r.kind == ResourceKind::File)
            })
        {
            return Err(Error::Invalid("File is not owned by this conversation."));
        }
        let store = self
            .catalog
            .lock()
            .unwrap()
            .files
            .clone()
            .ok_or(Error::Invalid("File storage is unavailable."))?;
        store.resolve(ids).await
    }
    pub(crate) fn attach_files(&self, files: Arc<crate::files::FileStore>) {
        self.catalog.lock().unwrap().files = Some(files);
    }
    pub async fn upload_file(
        self: &Arc<Self>,
        id: &str,
        name: String,
        bytes: Vec<u8>,
    ) -> Result<FileRef> {
        if !valid_file_name(&name) || bytes.len() > MAX_FILE_BYTES {
            return Err(Error::Invalid(
                "Use a valid filename and a file no larger than 8 MiB.",
            ));
        }
        let conversation = self.get(id)?;
        let files = {
            let c = self.catalog.lock().unwrap();
            if c.closed || c.account_busy || c.mutating.contains(id) {
                return Err(Error::Busy);
            }
            c.files
                .clone()
                .ok_or(Error::Invalid("File storage is unavailable."))?
        };
        let asset_id = new_id();
        let resource = ResourceRef {
            id: asset_id.clone(),
            call_id: String::new(),
            kind: ResourceKind::File,
        };
        let session = id.to_owned();
        conversation
            .store_resource(resource, async move {
                files.put(session, asset_id, name, bytes).await
            })
            .await
    }
    pub async fn update_settings(
        &self,
        id: &str,
        settings: SessionSettings,
    ) -> Result<ConversationSnapshot> {
        self.get(id)?.update_settings(settings).await
    }
    /// Read-only observers keep access during catalog reservations, until actual removal.
    /// Do not expose a Conversation handle here: get() remains mutation-guarded.
    pub fn snapshot(&self, id: &str) -> Result<ConversationSnapshot> {
        let catalog = self.catalog.lock().unwrap();
        if catalog.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        Ok(catalog
            .conversations
            .get(id)
            .ok_or(Error::Invalid("Conversation not found."))?
            .snapshot())
    }
    pub fn sync(&self, id: &str, cursor: SyncCursor<'_>) -> Result<ConversationSync> {
        let catalog = self.catalog.lock().unwrap();
        if catalog.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        catalog
            .conversations
            .get(id)
            .ok_or(Error::Invalid("Conversation not found."))?
            .sync(cursor)
    }
    pub fn observe(&self, id: &str) -> Result<(ConversationSnapshot, EventReceiver)> {
        let catalog = self.catalog.lock().unwrap();
        if catalog.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        Ok(catalog
            .conversations
            .get(id)
            .ok_or(Error::Invalid("Conversation not found."))?
            .subscribe())
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
    pub fn native(&self) -> Arc<crate::native::NativeHub> {
        self.catalog.lock().unwrap().native.clone()
    }
    pub(crate) fn attach_native(&self, native: Arc<crate::native::NativeHub>) {
        self.catalog.lock().unwrap().native = native;
    }
    pub fn desktop_permission(&self, id: &str) -> Result<crate::native::DesktopPermission> {
        self.get(id)?;
        Ok(self.native().permission(id))
    }
    pub fn set_desktop_permission(
        &self,
        id: &str,
        permission: crate::native::DesktopPermission,
    ) -> Result<crate::native::DesktopPermission> {
        self.get(id)?;
        let native = self.native();
        native.set_permission(id, permission)?;
        Ok(native.permission(id))
    }
    pub(crate) fn attach_images(&self, images: Arc<crate::images::ImageStore>) {
        let mut c = self.catalog.lock().unwrap();
        for conversation in c.conversations.values() {
            conversation.attach_images(images.clone());
        }
        c.images = Some(images);
    }
    pub async fn upload_image(
        self: &Arc<Self>,
        id: &str,
        name: String,
        bytes: Vec<u8>,
    ) -> Result<ImageRef> {
        let conversation = self.get(id)?;
        let images = {
            let c = self.catalog.lock().unwrap();
            if c.closed || c.account_busy || c.mutating.contains(id) {
                return Err(Error::Busy);
            }
            c.images
                .clone()
                .ok_or(Error::Invalid("Image storage is unavailable."))?
        };
        let asset_id = new_id();
        let resource = ResourceRef {
            id: asset_id.clone(),
            call_id: String::new(),
            kind: ResourceKind::Image,
        };
        // Conversation ownership blocks deletion until storage settles, but leaves
        // reads and explicit cancellation available during an active upload.
        conversation
            .store_resource(
                resource,
                async move { images.put(asset_id, name, bytes).await },
            )
            .await
    }
    pub async fn release_image(self: &Arc<Self>, id: &str, asset: &str) -> Result<()> {
        if !valid_id(asset) {
            return Err(Error::Invalid("Invalid image ID."));
        }
        let conversation = self.get(id)?;
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed || c.forking > 0 || c.mutating.contains(id) || conversation.busy() {
                return Err(Error::Busy);
            }
            c.mutating.insert(id.into());
        }
        let manager = self.clone();
        let id = id.to_owned();
        let asset = asset.to_owned();
        tokio::spawn(async move{
            let remove=asset.clone();let result=async{conversation.mutate_record(move|record|{
                if record.messages.iter().chain(&record.pending_input).any(|m|match m{Message::User{images,..}=>images.iter().any(|i|i.id==remove),Message::Tool{details:Some(ToolDetails::Image{image,..}),..}=>image.id==remove,_=>false}){return Err(Error::Invalid("Images in conversation history cannot be removed independently. Delete the conversation instead."));}
                let before=record.resources.len();record.resources.retain(|r|!(r.id==remove&&r.kind==ResourceKind::Image&&r.call_id.is_empty()));if before==record.resources.len(){return Err(Error::Invalid("Unused uploaded image not found."));}Ok(())
            }).await?;
            let images={let c=manager.catalog.lock().unwrap();if !c.unreadable.is_empty()||c.conversations.values().any(|conv|conv.resources().iter().any(|r|r.id==asset)){None}else{c.images.clone()}};
            if let Some(images)=images{images.delete(vec![asset]).await?;}Ok(())}.await;
            manager.catalog.lock().unwrap().mutating.remove(&id);result
        }).await.map_err(|_|Error::Internal)?
    }
    pub async fn read_image(&self, id: &str) -> Result<ImageData> {
        let images = {
            let c = self.catalog.lock().unwrap();
            if c.closed
                || !c.conversations.values().any(|conv| {
                    conv.resources()
                        .iter()
                        .any(|r| r.id == id && r.kind == ResourceKind::Image)
                })
            {
                return Err(Error::Invalid(
                    "Image is not referenced by an available conversation.",
                ));
            }
            c.images
                .clone()
                .ok_or(Error::Invalid("Image storage is unavailable."))?
        };
        images.read(id).await
    }
    pub(crate) fn attach_logs(&self, logs: Arc<crate::shell_logs::ShellLogStore>) {
        self.catalog.lock().unwrap().logs = Some(logs);
    }
    pub async fn read_log(
        &self,
        id: &str,
        offset: u64,
        max_bytes: usize,
    ) -> Result<crate::shell_logs::LogChunk> {
        let logs = {
            let catalog = self.catalog.lock().unwrap();
            if catalog.closed
                || !catalog.conversations.values().any(|c| {
                    c.resources()
                        .iter()
                        .any(|r| r.id == id && r.kind == ResourceKind::ShellLog)
                })
            {
                return Err(Error::Invalid(
                    "Log is not referenced by an available conversation.",
                ));
            }
            catalog
                .logs
                .clone()
                .ok_or(Error::Invalid("Shell log storage is unavailable."))?
        };
        logs.read(id, offset, max_bytes).await
    }
    pub fn unreadable_sessions(&self) -> Vec<String> {
        let catalog = self.catalog.lock().unwrap();
        let mut ids: Vec<_> = catalog.unreadable.iter().cloned().collect();
        ids.sort();
        ids
    }
    pub fn summaries(&self) -> Result<Vec<ConversationSummary>> {
        let c = self.catalog.lock().unwrap();
        if c.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        let mut result: Vec<_> = c.conversations.values().map(|c| c.summary()).collect();
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
    fn deletion_family(catalog: &Catalog, id: &str) -> Vec<String> {
        let mut ids = vec![id.to_owned()];
        let mut seen = HashSet::from([id.to_owned()]);
        let mut index = 0;
        while index < ids.len() {
            let parent_id = ids[index].clone();
            for child in catalog.conversations.values() {
                if child.parent().is_some_and(|p| p.session_id == parent_id)
                    && seen.insert(child.id.clone())
                {
                    ids.push(child.id.clone());
                }
            }
            index += 1;
        }
        ids
    }
    pub async fn delete(&self, id: &str) -> Result<()> {
        let (reserved, conversations) = {
            let mut catalog = self.catalog.lock().unwrap();
            let ids = Self::deletion_family(&catalog, id);
            if catalog.closed
                || catalog.forking > 0
                || ids.iter().any(|id| catalog.mutating.contains(id))
            {
                return Err(Error::Busy);
            }
            if !catalog.conversations.contains_key(id) && !catalog.unreadable.contains(id) {
                return Err(Error::Invalid("Conversation not found."));
            }
            let conversations: Vec<_> = ids
                .iter()
                .filter_map(|id| catalog.conversations.get(id).cloned())
                .collect();
            if conversations.iter().any(|c| {
                c.parent()
                    .is_some_and(|p| catalog.mutating.contains(&p.session_id))
            }) {
                return Err(Error::Busy);
            }
            let reserved: HashSet<_> = ids.into_iter().collect();
            catalog.mutating.extend(reserved.iter().cloned());
            for conversation in &conversations {
                if let Some(op) = conversation.snapshot().operation {
                    conversation.cancel(&op.id);
                }
            }
            (reserved, conversations)
        };
        // Never drop a live tool executor to simulate deletion. In particular, the
        // parent's delegate future owns its children until their cleanup settles.
        for conversation in conversations {
            let (_, mut events) = conversation.subscribe();
            while conversation.busy() {
                if events.recv().await.is_err() {
                    events = conversation.subscribe().1;
                }
            }
        }
        // Recollect after parent cleanup: a child whose creation was already in
        // flight when cancellation arrived must be included as well.
        let result = self.delete_session(id, None, &reserved).await;
        let mut catalog = self.catalog.lock().unwrap();
        for id in reserved {
            catalog.mutating.remove(&id);
        }
        result
    }
    pub(crate) async fn delete_returned_child(
        &self,
        id: &str,
        parent_id: &str,
        call_id: &str,
    ) -> Result<()> {
        self.delete_session(id, Some((parent_id, call_id)), &HashSet::new())
            .await
    }
    async fn delete_session(
        &self,
        id: &str,
        returned_child: Option<(&str, &str)>,
        reserved: &HashSet<String>,
    ) -> Result<()> {
        // Reserve the entire family before touching storage. A busy descendant
        // must not cause a half-deleted family, and forks must not race cleanup.
        let sessions = {
            let mut catalog = self.catalog.lock().unwrap();
            // Explicit deletion already owns cleanup, or has finished it.
            if returned_child.is_some()
                && (catalog.mutating.contains(id) || !catalog.conversations.contains_key(id))
            {
                return Ok(());
            }
            if catalog.closed || catalog.forking > 0 {
                return Err(Error::Busy);
            }
            if !catalog.conversations.contains_key(id) && !catalog.unreadable.contains(id) {
                return Err(Error::Invalid("Conversation not found."));
            }
            let ids = Self::deletion_family(&catalog, id);
            let family: HashSet<_> = ids.iter().cloned().collect();
            for session_id in &ids {
                if catalog.mutating.contains(session_id) && !reserved.contains(session_id) {
                    return Err(Error::Busy);
                }
                if let Some(conversation) = catalog.conversations.get(session_id) {
                    if returned_child.is_some() && conversation.disposed() {
                        // A previous explicit deletion failed after disposing this child.
                        // Its delegate must not turn cleanup into an automatic retry.
                        return Err(Error::Storage);
                    }
                    let cleanup_allowed =
                        returned_child.is_some_and(|(parent_id, call_id)| {
                            let snapshot = conversation.snapshot();
                            snapshot.metadata.parent.is_some_and(|p| {
                                p.session_id == parent_id && p.tool_call_id == call_id
                            }) && snapshot.operation.is_some_and(|op| !op.state.active())
                        });
                    if (returned_child.is_some() && !cleanup_allowed) || conversation.busy() {
                        return Err(Error::Busy);
                    }
                }
            }
            let mut sessions = Vec::with_capacity(ids.len());
            // Delete leaves first: a storage failure keeps their parent available
            // for inspection, rather than leaving inaccessible orphan children.
            for session_id in ids.into_iter().rev() {
                let resources = if let Some(conversation) = catalog.conversations.get(&session_id) {
                    conversation.dispose()?;
                    conversation.resources()
                } else {
                    vec![]
                };
                sessions.push((session_id, resources));
            }
            catalog.mutating.extend(family);
            sessions
        };
        let mut result = Ok(());
        for (session_id, resources) in &sessions {
            result = self
                .delete_reserved_session(session_id, resources.clone())
                .await;
            if result.is_err() {
                break;
            }
        }
        let mut catalog = self.catalog.lock().unwrap();
        for (session_id, _) in sessions {
            catalog.mutating.remove(&session_id);
        }
        result
    }
    async fn delete_reserved_session(&self, id: &str, resources: Vec<ResourceRef>) -> Result<()> {
        if let Some(store) = &self.store {
            store.delete(id.into()).await?;
        }
        let cleanup = {
            let mut catalog = self.catalog.lock().unwrap();
            catalog.conversations.remove(id);
            catalog.native.remove_session(id);
            catalog.unreadable.remove(id);
            self.changes.remove(id);
            let referenced: HashSet<_> = catalog
                .conversations
                .values()
                .flat_map(|c| c.resources().into_iter().map(|r| r.id))
                .collect();
            if catalog.unreadable.is_empty() {
                let unreferenced: Vec<_> = resources
                    .into_iter()
                    .filter(|r| !referenced.contains(&r.id))
                    .collect();
                Some((
                    catalog.logs.clone(),
                    catalog.images.clone(),
                    catalog.files.clone(),
                    unreferenced,
                ))
            } else {
                None
            }
        };
        if let Some((logs, images, files, resources)) = cleanup {
            let logs_result = if let Some(logs) = logs {
                logs.delete(
                    resources
                        .iter()
                        .filter(|r| r.kind == ResourceKind::ShellLog)
                        .map(|r| r.id.clone())
                        .collect(),
                )
                .await
            } else {
                Ok(())
            };
            let file_result = if let Some(files) = files {
                files
                    .delete(
                        resources
                            .iter()
                            .filter(|r| r.kind == ResourceKind::File)
                            .map(|r| r.id.clone())
                            .collect(),
                    )
                    .await
            } else {
                Ok(())
            };
            let image_result = if let Some(images) = images {
                images
                    .delete(
                        resources
                            .into_iter()
                            .filter(|r| r.kind == ResourceKind::Image)
                            .map(|r| r.id)
                            .collect(),
                    )
                    .await
            } else {
                Ok(())
            };
            logs_result.and(image_result).and(file_result)
        } else {
            Ok(())
        }
    }
    pub async fn close(&self) -> Result<()> {
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed {
                return Err(Error::Invalid("Agent manager is closed."));
            }
            if c.forking > 0
                || c.account_busy
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
        {
            let c = self.catalog.lock().unwrap();
            if let Some(cancel) = &c.connection_cancel {
                cancel.cancel();
            }
        }
        while self.catalog.lock().unwrap().account_busy {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }

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
