use super::*;
use crate::{Error, Result, check_cancel};
use async_trait::async_trait;
use futures_util::{FutureExt, StreamExt};
use std::{
    collections::{HashMap, HashSet},
    panic::AssertUnwindSafe,
    sync::{Arc, Mutex, MutexGuard},
    task::Poll,
    time::{Duration, Instant},
};
use tokio::sync::{Notify, oneshot};
use tokio_util::sync::CancellationToken;

#[async_trait]
pub trait Checkpoint: Send + Sync {
    async fn save(&self, record: ConversationRecord) -> Result<()>;
    /// Optional, best-effort diagnostics; never a prerequisite for durable state.
    async fn diagnostic(&self, _entry: SessionDiagnostic) -> Result<()> {
        Ok(())
    }
}
pub struct ConversationOptions {
    pub provider: Arc<dyn ChatProvider>,
    pub model: String,
    pub workspace: String,
    pub tools: Vec<Arc<dyn Tool>>,
    pub max_steps: usize,
    pub metadata: SessionMetadata,
    pub settings: SessionSettings,
    pub checkpoint: Option<Arc<dyn Checkpoint>>,
    pub images: Option<Arc<dyn ImageReader>>,
}
impl ConversationOptions {
    pub fn new(
        provider: Arc<dyn ChatProvider>,
        model: impl Into<String>,
        workspace: impl Into<String>,
    ) -> Self {
        Self {
            provider,
            model: model.into(),
            workspace: workspace.into(),
            tools: vec![],
            max_steps: 128,
            metadata: SessionMetadata::default(),
            settings: SessionSettings::default(),
            checkpoint: None,
            images: None,
        }
    }
}
struct Active {
    cancel: CancellationToken,
    finishing: bool,
    compact_only: bool,
    // Reservations survive child cleanup and compaction, but not consumed user input.
    delegated_agents: usize,
    // Keep replay protection for the entire operation, including steered turns.
    delegation_calls: HashSet<String>,
}
struct Pending {
    approval: Approval,
    decision: oneshot::Sender<bool>,
}
struct State {
    record: ConversationRecord,
    active: Option<Active>,
    pending: Option<Pending>,
    active_tool: Option<String>,
    storage_error: Option<String>,
    disposed: bool,
    updating: bool,
    changes: Option<ChangeRegistration>,
    prefixes: super::sync::PrefixCache,
    #[cfg(test)]
    full_snapshots: std::cell::Cell<usize>,
}

/// Publish while still holding the state lock. A subscriber that reads a revision
/// and then state cannot miss a mutation between its read and its next wait.
/// Comparing only the summary keeps catalog revisions independent of token text.
struct StateGuard<'a> {
    state: MutexGuard<'a, State>,
    provider: &'a dyn ChatProvider,
    dirty: bool,
    text_only: bool,
    before: Option<(ConversationSummary, Option<Approval>)>,
}
impl std::ops::Deref for StateGuard<'_> {
    type Target = State;
    fn deref(&self) -> &State {
        &self.state
    }
}
impl std::ops::DerefMut for StateGuard<'_> {
    fn deref_mut(&mut self) -> &mut State {
        if !self.dirty && !self.text_only && self.state.changes.is_some() {
            self.before = Some((
                self.state.summary(self.provider),
                self.state.pending.as_ref().map(|p| p.approval.clone()),
            ));
        }
        self.dirty = true;
        &mut self.state
    }
}
impl Drop for StateGuard<'_> {
    fn drop(&mut self) {
        if self.dirty
            && let Some(changes) = &self.state.changes
        {
            let catalog = self.before.as_ref().is_some_and(|(summary, approval)| {
                *summary != self.state.summary(self.provider)
                    || *approval != self.state.pending.as_ref().map(|p| p.approval.clone())
            });
            changes.changed(catalog);
        }
    }
}
impl State {
    fn snapshot(&self, provider: &dyn ChatProvider) -> ConversationSnapshot {
        #[cfg(test)]
        self.full_snapshots.set(self.full_snapshots.get() + 1);
        self.snapshot_range(provider, 0..self.record.messages.len())
    }
    fn snapshot_range(
        &self,
        provider: &dyn ChatProvider,
        range: std::ops::Range<usize>,
    ) -> ConversationSnapshot {
        self.summary(provider).with_messages(
            self.record.messages[range].to_vec(),
            self.pending.as_ref().map(|p| p.approval.clone()),
        )
    }
    fn summary(&self, provider: &dyn ChatProvider) -> ConversationSummary {
        ConversationSummary {
            id: self.record.id.clone(),
            supports_compaction: provider.supports_compaction(&self.record.model),
            configuration: self
                .record
                .configuration
                .clone()
                .expect("validated configuration"),
            model: self.record.model.clone(),
            workspace: self.record.workspace.clone(),
            can_change_workspace: !self.record.workspace_locked()
                && self.active.is_none()
                && !self.updating
                && !self.disposed
                && self.storage_error.is_none(),
            pending_input: self.record.pending_input.clone(),
            metadata: self.record.metadata.clone(),
            usage: self.record.usage.clone(),
            context_usage: provider
                .context_window(&self.record.model)
                .zip(
                    self.record
                        .usage
                        .as_ref()
                        .and_then(|u| u.total_tokens.or(u.input_tokens)),
                )
                .map(|(limit, tokens)| ContextUsage { tokens, limit }),
            resources: self.record.resources.clone(),
            operation: self.record.operation.clone(),
            active_tool_call_id: self.active_tool.clone(),
            active_tool_name: self.active_tool.as_ref().and_then(|id| {
                self.record.messages.iter().rev().find_map(|message| {
                    if let Message::Assistant { calls, .. } = message {
                        calls
                            .iter()
                            .find(|call| &call.id == id)
                            .map(|call| call.name.clone())
                    } else {
                        None
                    }
                })
            }),
            storage_error: self.storage_error.clone(),
        }
    }
}
pub struct Conversation {
    pub id: String,
    state: Mutex<State>,
    provider: Arc<dyn ChatProvider>,
    tools: HashMap<String, Arc<dyn Tool>>,
    definitions: Vec<ToolDefinition>,
    persist: Option<Arc<dyn Checkpoint>>,
    checkpoint_lock: tokio::sync::Mutex<()>,
    images: Mutex<Option<Arc<dyn ImageReader>>>,
    events: EventHub,
    input_arrived: Notify,
}
/// Keep a conversation from starting work across a durable reset.
/// Dropping also wakes observers waiting for an in-flight mutation to settle.
pub(crate) struct IdleReservation(Arc<Conversation>, bool);
impl IdleReservation {
    /// Atomically replace the reservation with disposal after active work settles.
    pub(crate) fn dispose(mut self) -> Result<()> {
        let mut state = self.0.state();
        if state.active.is_some() {
            return Err(Error::Busy);
        }
        state.disposed = true;
        state.updating = false;
        self.1 = false;
        self.0.publish_snapshot(&state);
        Ok(())
    }
}
impl Drop for IdleReservation {
    fn drop(&mut self) {
        if !self.1 {
            return;
        }
        let mut state = self.0.state();
        state.updating = false;
        self.0.publish_snapshot(&state);
    }
}

pub struct Submission {
    pub operation_id: String,
    /// The new user row for a turn; compaction does not submit input.
    pub message_id: Option<String>,
    /// Dropping the receipt only detaches. Use Conversation::cancel to stop work.
    pub completion: oneshot::Receiver<Operation>,
}
impl Conversation {
    pub fn new(
        options: ConversationOptions,
        initial: Option<ConversationRecord>,
    ) -> Result<Arc<Self>> {
        let record = if let Some(record) = initial {
            let record = record.recover()?;
            if record.model != options.model || record.workspace != options.workspace {
                return Err(Error::Invalid(
                    "Restored conversation configuration does not match.",
                ));
            }
            record
        } else {
            ConversationRecord {
                version: 9,
                resources: vec![],
                cleanup_resources: vec![],
                provider_state: None,
                usage: None,
                metadata: SessionMetadata {
                    activity_at: SessionMetadata::activity(),
                    ..options.metadata
                },
                configuration: Some(ConversationConfiguration::new(options.settings)),
                id: new_id(),
                model: options.model,
                workspace: options.workspace,
                max_steps: options.max_steps,
                messages: vec![],
                tool_availability: vec![],
                pending_input: vec![],
                operation: None,
                executing_tool_id: None,
            }
        };
        record.validate()?;
        let mut tools = HashMap::new();
        let mut definitions = vec![];
        for tool in options.tools {
            let definition = tool.definition();
            if definition.name.is_empty() || tools.insert(definition.name.clone(), tool).is_some() {
                return Err(Error::Invalid("Tool names must be nonempty and unique."));
            }
            definitions.push(definition);
        }
        definitions.sort_by(|a, b| a.name.cmp(&b.name));
        let events = EventHub::default();
        Ok(Arc::new(Self {
            id: record.id.clone(),
            state: Mutex::new(State {
                record,
                active: None,
                pending: None,
                active_tool: None,
                storage_error: None,
                disposed: false,
                updating: false,
                changes: None,
                prefixes: Default::default(),
                #[cfg(test)]
                full_snapshots: Default::default(),
            }),
            provider: options.provider,
            tools,
            definitions,
            persist: options.checkpoint,
            checkpoint_lock: tokio::sync::Mutex::new(()),
            images: Mutex::new(options.images),
            events,
            input_arrived: Notify::new(),
        }))
    }
    fn state(&self) -> StateGuard<'_> {
        StateGuard {
            state: self.state.lock().expect("conversation state lock poisoned"),
            provider: self.provider.as_ref(),
            dirty: false,
            text_only: false,
            before: None,
        }
    }
    fn text_state(&self) -> StateGuard<'_> {
        let mut state = self.state();
        state.text_only = true;
        state
    }
    pub(crate) fn attach_changes(&self, hub: &Arc<ChangeHub>) {
        let mut state = self.state.lock().unwrap();
        state.changes = Some(hub.attach(&self.id));
    }
    pub fn summary(&self) -> ConversationSummary {
        self.state().summary(self.provider.as_ref())
    }
    /// Read and validate a cursor under one lock, cloning only the requested page.
    pub fn sync(&self, cursor: SyncCursor<'_>) -> Result<ConversationSync> {
        use super::sync::{AFTER_LOOKUP_SIZE, PAGE_SIZE};
        let mut state = self.state.lock().unwrap();
        let State {
            record, prefixes, ..
        } = &mut *state;
        let messages = &record.messages;
        let total = messages.len();
        let (offset, end, reset) = match cursor {
            SyncCursor::Latest => (total.saturating_sub(PAGE_SIZE), total, true),
            SyncCursor::Before(anchor) => {
                let index =
                    messages
                        .iter()
                        .position(|m| m.id() == anchor)
                        .ok_or(Error::Invalid(
                            "Conversation history changed. Refresh the conversation.",
                        ))?;
                (index.saturating_sub(PAGE_SIZE), index, false)
            }
            SyncCursor::After { anchor, prefix } => {
                // Older anchors must reset anyway. Never scan the entire transcript
                // on the hot tail-poll path, even for a missing/stale anchor.
                let index = messages
                    .iter()
                    .enumerate()
                    .rev()
                    .take(AFTER_LOOKUP_SIZE)
                    .find_map(|(i, m)| (m.id() == anchor).then_some(i));
                match index {
                    Some(index) if prefixes.proof(messages, index) == prefix => {
                        (index, total, false)
                    }
                    _ => (total.saturating_sub(PAGE_SIZE), total, true),
                }
            }
        };
        let prefix = total
            .checked_sub(1)
            .map(|end| prefixes.proof(messages, end));
        Ok(ConversationSync {
            snapshot: state.snapshot_range(self.provider.as_ref(), offset..end),
            offset,
            total,
            reset,
            prefix,
        })
    }
    pub fn snapshot(&self) -> ConversationSnapshot {
        self.state().snapshot(self.provider.as_ref())
    }
    pub(crate) fn attach_images(&self, images: Arc<dyn ImageReader>) {
        *self.images.lock().unwrap() = Some(images);
    }
    pub fn parent(&self) -> Option<SessionParent> {
        self.state().record.metadata.parent.clone()
    }
    /// Reserve before creating children, at the same boundary as consumed user input.
    /// Active operations never resume after restart; reservations need not be persisted.
    pub(crate) fn reserve_delegation(
        &self,
        context: &ToolContext,
        count: usize,
    ) -> Result<ConversationSnapshot> {
        check_cancel(&context.cancel)?;
        if count == 0 || count > 8 {
            return Err(Error::Tool(
                "Delegation requires one to eight tasks.".into(),
            ));
        }
        let mut s = self.state();
        if s.record.metadata.parent.is_some() {
            return Err(Error::Tool("Sub-agents cannot delegate.".into()));
        }
        if self.id != context.conversation_id
            || s.record.operation.as_ref().is_none_or(|op| {
                op.id != context.operation_id || op.state != OperationState::Running
            })
            || s.active_tool.as_deref() != Some(&context.call_id)
            || s.active
                .as_ref()
                .is_none_or(|a| a.finishing || a.compact_only)
        {
            return Err(Error::Invalid(
                "Delegation requires an executing parent tool.",
            ));
        }
        let active = s.active.as_mut().unwrap();
        if active.delegation_calls.contains(&context.call_id) {
            return Err(Error::Tool(
                "This delegation already ran; it was not restarted.".into(),
            ));
        }
        if active.delegated_agents + count > 8 {
            return Err(Error::Tool(
                "The limit of eight sub-agents per turn was reached.".into(),
            ));
        }
        active.delegation_calls.insert(context.call_id.clone());
        active.delegated_agents += count;
        Ok(s.snapshot(self.provider.as_ref()))
    }
    /// Checkpoint each settled child before its only remaining session can be deleted.
    /// Keep failed writes inspectable in memory; the storage latch prevents cleanup/retry.
    pub(crate) async fn publish_delegation_result(
        &self,
        context: &ToolContext,
        total: usize,
        result: DelegationResult,
    ) -> Result<()> {
        let index = {
            let mut s = self.state();
            if s.record
                .operation
                .as_ref()
                .is_none_or(|op| op.id != context.operation_id)
                || s.active_tool.as_deref() != Some(&context.call_id)
            {
                return Err(Error::Invalid("Delegation is no longer executing."));
            }
            let index = s.record.messages.iter().position(|m| matches!(m,
                Message::Tool { call_id, outcome: ToolOutcome::Running, .. } if call_id == &context.call_id
            )).unwrap_or_else(|| {
                s.record.messages.push(Message::Tool {
                    id: new_id(),
                    call_id: context.call_id.clone(),
                    text: String::new(),
                    outcome: ToolOutcome::Running,
                    details: Some(ToolDetails::Delegation { total, results: vec![] }),
                });
                s.record.messages.len() - 1
            });
            s.prefixes.invalidate(index);
            let Message::Tool {
                text,
                details: Some(ToolDetails::Delegation { results, .. }),
                ..
            } = &mut s.record.messages[index]
            else {
                return Err(Error::Internal);
            };
            if results.iter().any(|r| r.task_index == result.task_index) {
                return Err(Error::Internal);
            }
            results.push(result);
            results.sort_by_key(|r| r.task_index);
            *text = results
                .iter()
                .map(|r| r.text.as_str())
                .collect::<Vec<_>>()
                .join("\n\n");
            s.record.version = s.record.version.max(10);
            index
        };
        let saved = self.checkpoint(None).await;
        self.changed(&self.state(), index);
        saved
    }
    pub fn resources(&self) -> Vec<ResourceRef> {
        self.state().record.resources.clone()
    }
    /// Includes hidden cleanup ownership retained by clear, not just usable assets.
    pub(crate) fn owned_resources(&self) -> Vec<ResourceRef> {
        let state = self.state();
        state
            .record
            .resources
            .iter()
            .chain(&state.record.cleanup_resources)
            .cloned()
            .collect()
    }
    pub fn record(&self) -> ConversationRecord {
        self.state().record.clone()
    }
    pub(crate) fn uses_provider(&self, id: &str) -> bool {
        let state = self.state();
        let record = &state.record;
        let owns_model = |model: &str| self.provider.provider_id(model).as_deref() == Some(id);
        let search = record
            .configuration
            .as_ref()
            .and_then(|c| c.settings.search_model.as_deref());
        let image_call = state
            .pending
            .as_ref()
            .is_some_and(|p| p.approval.call.name == "generate_image")
            || state.active_tool.as_ref().is_some_and(|id| {
                record.messages.iter().rev().any(|message| {
                    matches!(message, Message::Assistant { calls, .. }
                        if calls.iter().any(|call| &call.id == id && call.name == "generate_image"))
                })
            });
        owns_model(&record.model)
            || (record.metadata.tool_enabled("web_search")
                && self.tools.contains_key("web_search")
                && search.is_some_and(owns_model))
            || (image_call && self.provider.image_generation_provider_id().as_deref() == Some(id))
    }
    pub fn busy(&self) -> bool {
        let state = self.state();
        state.active.is_some() || state.updating
    }
    pub(crate) fn disposed(&self) -> bool {
        self.state().disposed
    }
    pub fn dispose(&self) -> Result<()> {
        let mut s = self.state();
        if s.active.is_some() || s.updating {
            return Err(Error::Busy);
        }
        s.disposed = true;
        Ok(())
    }
    /// Durable idle-only mutation. The owned task finishes even if its caller detaches.
    /// Publish new settings only after the save succeeds; failed acknowledgements block work.
    pub async fn update_settings(
        self: &Arc<Self>,
        settings: SessionSettings,
    ) -> Result<ConversationSnapshot> {
        settings.validate()?;
        self.mutate_record(move |record| {
            record.configuration.as_mut().unwrap().settings = settings;
            Ok(())
        })
        .await
    }
    /// Durably change the policy for future tool decisions, even during an active turn.
    pub async fn update_auto_approve(self: &Arc<Self>, auto_approve: bool) -> Result<bool> {
        {
            let mut state = self.state();
            if state.disposed {
                return Err(Error::Invalid("Conversation is closed."));
            }
            if state.storage_error.is_some() {
                return Err(Error::Storage);
            }
            if state.updating {
                return Err(Error::Busy);
            }
            // Reserve against other mutations and disposal, not the active runner.
            state.updating = true;
        }
        let conversation = self.clone();
        // Own the save even if the caller detaches. Keep the checkpoint lock through
        // publication so subsequent runner saves (including settlement) see the new flag.
        tokio::spawn(async move {
            let _checkpoint = conversation.checkpoint_lock.lock().await;
            let saved = AssertUnwindSafe(async {
                let (persist, mut record) = {
                    let state = conversation.state();
                    // A checkpoint ahead of this update may have failed while we waited.
                    if state.storage_error.is_some() {
                        return Err(Error::Storage);
                    }
                    let Some(persist) = &conversation.persist else {
                        return Ok(());
                    };
                    (persist, state.record.clone())
                };
                record.configuration.as_mut().unwrap().settings.auto_approve = auto_approve;
                persist.save(record).await
            })
            .catch_unwind()
            .await
            .unwrap_or(Err(Error::Storage));
            let mut state = conversation.state();
            state.updating = false;
            if saved.is_ok() {
                // The transcript and execution state may have advanced during the save.
                let config = state.record.configuration.as_mut().unwrap();
                config.settings.auto_approve = auto_approve;
            } else {
                state.storage_error = Some(Error::Storage.to_string());
            }
            conversation.publish_snapshot(&state);
            saved.map_err(|_| Error::Storage)?;
            Ok(auto_approve)
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    /// Tool policy uses the same idle-only, durable boundary as session settings.
    pub async fn update_disabled_tools(
        self: &Arc<Self>,
        disabled_tools: Vec<String>,
    ) -> Result<ConversationSnapshot> {
        self.mutate_record(move |record| {
            if record.metadata.parent.is_some() {
                return Err(Error::Invalid(
                    "Sub-agents inherit their parent's tool selection.",
                ));
            }
            if disabled_tools
                .iter()
                .any(|name| !self.tools.contains_key(name))
            {
                return Err(Error::Invalid("Unknown disabled tool."));
            }
            record.metadata.disabled_tools = disabled_tools;
            Ok(())
        })
        .await
    }
    /// Query actual executors, including child restrictions, without consulting the
    /// deny-list or changing the record. Supplied settings preview the client's choice.
    pub fn tool_availability(
        &self,
        names: &[String],
        model: &str,
        search_model: Option<&str>,
        capture_preview: Option<CapturePreview>,
    ) -> std::collections::BTreeMap<String, RuntimeToolAvailability> {
        let workspace = self.state().record.workspace.clone();
        let context = ToolContext::idle(
            self.id.clone(),
            model.into(),
            search_model.map(str::to_owned),
            workspace,
            capture_preview,
        );
        runtime_tool_availability(names, &self.tools, &context)
    }
    fn request_context(
        &self,
        record: &mut ConversationRecord,
        end: usize,
        cancel: &CancellationToken,
    ) -> (Vec<ContextMessage>, Vec<String>, Vec<ToolDefinition>) {
        // Select schemas and trusted availability from the same local capability
        // snapshot. History stays intact when a tool is no longer offered.
        // Tool-free conversations need no policy unless replacing a previous set.
        let tools = if !self.definitions.is_empty() || !record.tool_availability.is_empty() {
            let context = ToolContext {
                available_images: vec![],
                conversation_id: self.id.clone(),
                capture_preview: None,
                operation_id: record.operation.as_ref().unwrap().id.clone(),
                call_id: String::new(),
                model: record.model.clone(),
                search_model: record
                    .configuration
                    .as_ref()
                    .unwrap()
                    .settings
                    .search_model
                    .clone(),
                workspace: record.workspace.clone(),
                cancel: cancel.clone(),
            };
            let tools: Vec<_> = self
                .definitions
                .iter()
                .filter(|d| {
                    record.metadata.tool_enabled(&d.name) && self.tools[&d.name].available(&context)
                })
                .cloned()
                .collect();
            let enabled = tools.iter().map(|d| d.name.clone()).collect();
            record.update_tool_availability(end, enabled);
            tools
        } else {
            vec![]
        };
        let (messages, message_ids) = record.provider_context(end);
        (messages, message_ids, tools)
    }
    pub(crate) fn reserve_idle(self: &Arc<Self>) -> Result<IdleReservation> {
        let mut state = self.state();
        if state.disposed || state.active.is_some() || state.updating {
            return Err(Error::Busy);
        }
        state.updating = true;
        Ok(IdleReservation(self.clone(), true))
    }
    pub(crate) fn reserve_clear(self: &Arc<Self>) -> Result<IdleReservation> {
        let mut state = self.state();
        if state.disposed || state.updating {
            return Err(Error::Busy);
        }
        if state.storage_error.is_some() {
            return Err(Error::Storage);
        }
        state.updating = true;
        Ok(IdleReservation(self.clone(), true))
    }
    /// Deletion can settle active work and explicitly retry a disposed session,
    /// including one whose last storage acknowledgement failed.
    pub(crate) fn reserve_delete(self: &Arc<Self>) -> Result<IdleReservation> {
        let mut state = self.state();
        if state.updating {
            return Err(Error::Busy);
        }
        state.updating = true;
        Ok(IdleReservation(self.clone(), true))
    }
    pub(crate) async fn settle_active(&self) {
        let (_, mut events) = self.subscribe();
        while self.state().active.is_some() {
            if events.recv().await.is_err() {
                events = self.subscribe().1;
            }
        }
    }
    /// Called under the manager's catalog lock after checking delegation ownership.
    /// Retain descendant reservations through both the save and publication.
    pub(crate) fn start_clear(
        self: &Arc<Self>,
        reservations: Vec<IdleReservation>,
    ) -> Result<tokio::task::JoinHandle<Result<ConversationSnapshot>>> {
        self.start_mutation(
            |record| {
                record.messages.clear();
                record.tool_availability.clear();
                record.pending_input.clear();
                record.operation = None;
                record.executing_tool_id = None;
                record.provider_state = None;
                record.usage = None;
                // Hide cleared attachments, but durably retain their cleanup ownership.
                // Neither shared forks nor unreadable records permit eager asset deletion.
                for mut resource in record.resources.drain(..) {
                    resource.call_id.clear();
                    record.cleanup_resources.push(resource);
                }
                record.version = record.version.max(12);
                record.metadata.activity_at = SessionMetadata::activity();
                Ok(())
            },
            reservations,
            true,
        )
    }
    /// Rename live metadata without replacing a concurrently changing transcript.
    /// Use the runner's checkpoint ordering and own the save if the caller detaches.
    pub(crate) async fn rename(self: &Arc<Self>, title: String) -> Result<ConversationSnapshot> {
        {
            let mut state = self.state();
            if state.disposed {
                return Err(Error::Invalid("Conversation is closed."));
            }
            if state.storage_error.is_some() {
                return Err(Error::Storage);
            }
            if state.updating {
                return Err(Error::Busy);
            }
            let mut metadata = state.record.metadata.clone();
            metadata.title = Some(title);
            metadata.manually_named = true;
            metadata.validate()?;
            state.record.metadata = metadata;
            // Block conflicting idle mutations/deletion, not the active runner.
            state.updating = true;
        }
        let conversation = self.clone();
        tokio::spawn(async move {
            let saved = AssertUnwindSafe(conversation.checkpoint(None))
                .catch_unwind()
                .await
                .unwrap_or(Err(Error::Storage));
            let mut state = conversation.state();
            state.updating = false;
            if saved.is_err() {
                state.storage_error = Some(Error::Storage.to_string());
            }
            let snapshot = state.snapshot(conversation.provider.as_ref());
            conversation.events.send(Arc::new(ServiceEvent::Snapshot {
                snapshot: snapshot.clone(),
            }));
            saved.map_err(|_| Error::Storage)?;
            Ok(snapshot)
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    pub(crate) async fn mutate_record(
        self: &Arc<Self>,
        mutate: impl FnOnce(&mut ConversationRecord) -> Result<()>,
    ) -> Result<ConversationSnapshot> {
        self.start_mutation(mutate, vec![], false)?
            .await
            .map_err(|_| Error::Internal)?
    }
    fn start_mutation(
        self: &Arc<Self>,
        mutate: impl FnOnce(&mut ConversationRecord) -> Result<()>,
        mut keep_idle: Vec<IdleReservation>,
        reserved: bool,
    ) -> Result<tokio::task::JoinHandle<Result<ConversationSnapshot>>> {
        let record = {
            let mut s = self.state();
            if s.disposed {
                return Err(Error::Invalid("Conversation is closed."));
            }
            if s.storage_error.is_some() {
                return Err(Error::Storage);
            }
            if s.active.is_some() || (s.updating && !reserved) {
                return Err(Error::Busy);
            }
            let mut record = s.record.clone();
            mutate(&mut record)?;
            record.validate()?;
            if reserved {
                // Transfer the root reservation to this mutation; release it under
                // the publication lock so snapshots reflect the final idle state.
                keep_idle[0].1 = false;
            }
            s.updating = true;
            record
        };
        let conversation = self.clone();
        Ok(tokio::spawn(async move {
            let saved = AssertUnwindSafe(async {
                if let Some(persist) = &conversation.persist {
                    persist.save(record.clone()).await?;
                }
                Ok::<_, Error>(())
            })
            .catch_unwind()
            .await
            .unwrap_or(Err(Error::Internal));
            let snapshot = {
                let mut state = conversation.state();
                state.updating = false;
                if saved.is_ok() {
                    state.prefixes.invalidate(0);
                    state.record = record;
                } else {
                    state.storage_error = Some(Error::Storage.to_string());
                }
                let snapshot = state.snapshot(conversation.provider.as_ref());
                conversation.events.send(Arc::new(ServiceEvent::Snapshot {
                    snapshot: snapshot.clone(),
                }));
                snapshot
            };
            drop(keep_idle);
            saved.map_err(|_| Error::Storage)?;
            Ok(snapshot)
        }))
    }
    /// Subscription and initial snapshot are taken under the same lock as events.
    /// Lagging observers must reconnect explicitly; they can never block execution.
    pub fn subscribe(&self) -> (ConversationSnapshot, EventReceiver) {
        let s = self.state();
        let receiver = self.events.subscribe();
        (s.snapshot(self.provider.as_ref()), receiver)
    }
    fn publish_snapshot(&self, state: &State) {
        if self.events.has_observers() {
            self.events.send(Arc::new(ServiceEvent::Snapshot {
                snapshot: state.snapshot(self.provider.as_ref()),
            }));
        }
    }
    fn emit(&self, s: &State, kind: EventKind) {
        if !self.events.has_observers() {
            return;
        }
        let Some(op) = &s.record.operation else {
            return;
        };
        let snapshot = if matches!(kind, EventKind::Text { .. }) {
            None
        } else {
            Some(s.snapshot(self.provider.as_ref()))
        };
        self.events.send(Arc::new(ServiceEvent::Runtime {
            event: RuntimeEvent {
                conversation_id: self.id.clone(),
                operation_id: op.id.clone(),
                kind,
            },
            snapshot,
        }));
    }
    fn set_state(&self, s: &mut State, state: OperationState) {
        if let Some(op) = &mut s.record.operation {
            op.state = state;
        }
        self.emit(s, EventKind::Operation { state });
    }
    fn changed(&self, s: &State, index: usize) {
        let m = &s.record.messages[index];
        self.emit(
            s,
            EventKind::Message {
                message_id: m.id().into(),
            },
        );
        if let Message::Tool {
            call_id,
            id,
            outcome,
            ..
        } = m
            && *outcome != ToolOutcome::Running
        {
            self.emit(
                s,
                EventKind::ToolFinished {
                    call_id: call_id.clone(),
                    message_id: id.clone(),
                    outcome: *outcome,
                },
            );
        }
    }
    pub(crate) fn fork_record(&self) -> Result<ConversationRecord> {
        let state = self.state();
        if state.updating {
            return Err(Error::Busy);
        }
        if state.storage_error.is_some() {
            return Err(Error::Storage);
        }
        if state.disposed {
            return Err(Error::Invalid("Conversation is closed."));
        }
        let mut record = state.record.clone();
        // A fork inherits usable context, not the source's cleared cleanup ledger.
        record.cleanup_resources.clear();
        record.pending_input.clear();
        if state.active.is_some() {
            // Snapshot only completed transcript pieces, never live work.
            record.messages.retain(|message| {
                !matches!(
                    message,
                    Message::Assistant {
                        status: MessageStatus::Streaming,
                        ..
                    } | Message::Tool {
                        outcome: ToolOutcome::Running,
                        ..
                    }
                )
            });
            let resolved: HashSet<_> = record
                .messages
                .iter()
                .filter_map(|message| {
                    if let Message::Tool { call_id, .. } = message {
                        Some(call_id.clone())
                    } else {
                        None
                    }
                })
                .collect();
            for message in &mut record.messages {
                if let Message::Assistant { calls, .. } = message {
                    calls.retain(|call| resolved.contains(&call.id));
                }
            }
            record.resources.retain(|resource| {
                resource.call_id.is_empty() || resolved.contains(&resource.call_id)
            });
            record.executing_tool_id = None;
            if let Some(operation) = &mut record.operation
                && operation.state.active()
            {
                operation.state = OperationState::Interrupted;
                operation.error = None;
            }
            // Pruned calls cannot reuse finalized opaque output, but dropping all
            // state would also discard compaction and replay the full history.
            if let Some(provider_state) = record.provider_state.take() {
                let (messages, ids) = record.provider_context(record.messages.len());
                record.provider_state =
                    self.provider.fork_state(provider_state, &ids, &messages)?;
            }
            record.usage = None;
        }
        record.id = new_id();
        // An explicit user fork is independent, not another execution of the parent's call.
        record.metadata.parent = None;
        record.metadata.manually_named = false;
        record.metadata.activity_at = SessionMetadata::activity();
        record.metadata.title = Some(format!(
            "{} (fork)",
            record
                .metadata
                .title
                .as_deref()
                .unwrap_or("Untitled")
                .chars()
                .take(100)
                .collect::<String>()
        ));
        Ok(record)
    }
    pub fn submit(self: &Arc<Self>, text: String) -> Result<Submission> {
        self.submit_with_instructions(text, None)
    }
    /// Manager supplies a first-turn snapshot; embedded callers may supply their own.
    pub fn submit_with_instructions(
        self: &Arc<Self>,
        text: String,
        instructions: Option<String>,
    ) -> Result<Submission> {
        self.submit_images(text, vec![], instructions)
    }
    pub fn submit_images(
        self: &Arc<Self>,
        text: String,
        images: Vec<ImageRef>,
        instructions: Option<String>,
    ) -> Result<Submission> {
        self.submit_attachments_with_naming(text, images, vec![], instructions, false, None)
    }
    pub(crate) fn submit_attachments_with_naming(
        self: &Arc<Self>,
        text: String,
        images: Vec<ImageRef>,
        files: Vec<FileRef>,
        instructions: Option<String>,
        automatic_titles: bool,
        expected_workspace: Option<&str>,
    ) -> Result<Submission> {
        validate_message_input(&text, &images, &files)?;
        let mut s = self.state();
        if s.disposed {
            return Err(Error::Invalid("Conversation is closed."));
        }
        if s.storage_error.is_some() {
            return Err(Error::Storage);
        }
        if s.active.is_some() || s.updating {
            return Err(Error::Busy);
        }
        // Instruction loading awaits filesystem I/O outside this lock. Reject a
        // concurrent folder change rather than freezing context from the old folder.
        if expected_workspace.is_some_and(|workspace| workspace != s.record.workspace) {
            return Err(Error::Busy);
        }
        if let Some(value) = &instructions {
            validate_instructions(value)?;
        }
        if files.iter().any(|file| {
            !s.record
                .resources
                .iter()
                .any(|r| r.id == file.id && r.kind == ResourceKind::File)
        }) {
            return Err(Error::Invalid("File is not owned by this conversation."));
        }
        if images.iter().any(|image| {
            !s.record
                .resources
                .iter()
                .any(|r| r.id == image.id && r.kind == ResourceKind::Image)
        }) {
            return Err(Error::Invalid("Image is not owned by this conversation."));
        }
        let config = s.record.configuration.as_mut().unwrap();
        if !config.instructions_frozen {
            config.workspace_instructions = instructions;
            config.instructions_frozen = true;
        }
        let title_input = (automatic_titles && !s.record.metadata.manually_named).then(|| {
            (
                s.record.metadata.title.clone().unwrap_or_default(),
                text.clone(),
            )
        });
        s.record.metadata.activity_at = SessionMetadata::activity();
        if s.record.metadata.title.is_none() && text.trim().is_empty() {
            s.record.metadata.title = Some(
                files
                    .first()
                    .map(|f| f.name.chars().take(80).collect())
                    .unwrap_or_else(|| "Image".into()),
            );
        }
        if s.record.metadata.title.is_none() {
            s.record.metadata.title = Some(super::titles::fallback(&text));
        }
        let operation_id = new_id();
        let cancel = CancellationToken::new();
        s.active = Some(Active {
            cancel: cancel.clone(),
            finishing: false,
            compact_only: false,
            delegated_agents: 0,
            delegation_calls: HashSet::new(),
        });
        s.record.operation = Some(Operation {
            id: operation_id.clone(),
            state: OperationState::Running,
            error: None,
        });
        let pending = std::mem::take(&mut s.record.pending_input);
        s.record.messages.extend(pending);
        let message_id = new_id();
        s.record.messages.push(Message::User {
            id: message_id.clone(),
            text,
            images,
            files,
        });
        let runner = self.clone();
        let (settled, completion) = oneshot::channel();
        tokio::spawn(async move {
            tokio::task::yield_now().await;
            let operation = runner.run(cancel, false, title_input).await;
            let _ = settled.send(operation);
        });
        Ok(Submission {
            operation_id,
            message_id: Some(message_id),
            completion,
        })
    }
    pub fn compact(self: &Arc<Self>) -> Result<Submission> {
        let mut s = self.state();
        if s.disposed || s.storage_error.is_some() {
            return Err(Error::Storage);
        }
        if s.active.is_some() || s.updating || !s.record.pending_input.is_empty() {
            return Err(Error::Busy);
        }
        if !self.provider.supports_compaction(&s.record.model) || s.record.messages.is_empty() {
            return Err(Error::Invalid("This model has no compactable history."));
        }
        let operation_id = new_id();
        let cancel = CancellationToken::new();
        s.active = Some(Active {
            cancel: cancel.clone(),
            finishing: false,
            compact_only: true,
            delegated_agents: 0,
            delegation_calls: HashSet::new(),
        });
        s.record.operation = Some(Operation {
            id: operation_id.clone(),
            state: OperationState::Running,
            error: None,
        });
        let runner = self.clone();
        let (settled, completion) = oneshot::channel();
        tokio::spawn(async move {
            let op = runner.run(cancel, true, None).await;
            let _ = settled.send(op);
        });
        Ok(Submission {
            operation_id,
            message_id: None,
            completion,
        })
    }
    async fn compact_history(&self, cancel: &CancellationToken, automatic: bool) -> Result<()> {
        check_cancel(cancel)?;
        let mut request = {
            let mut s = self.state();
            if !self.provider.supports_compaction(&s.record.model) {
                return if automatic {
                    Ok(())
                } else {
                    Err(Error::Provider(crate::ProviderFailure::Unsupported))
                };
            }
            if automatic {
                let Some(tokens) = s
                    .record
                    .usage
                    .as_ref()
                    .and_then(|u| u.total_tokens.or(u.input_tokens))
                else {
                    return Ok(());
                };
                let Some(window) = self.provider.context_window(&s.record.model) else {
                    return Ok(());
                };
                let threshold = self
                    .provider
                    .auto_compaction_threshold_percent(&s.record.model)
                    .clamp(1, 100);
                if tokens < window.saturating_mul(threshold).div_ceil(100) {
                    return Ok(());
                }
            }
            let mut end = s.record.messages.len();
            if automatic {
                // Never move behind a durable request boundary, even if a failed
                // manual compaction covered an otherwise unanswered user message.
                let last_boundary = s
                    .record
                    .tool_availability
                    .last()
                    .map(|a| a.after_message_id.as_str());
                while end > 0
                    && Some(s.record.messages[end - 1].id()) != last_boundary
                    && (matches!(&s.record.messages[end - 1], Message::User { .. })
                        || s.record.messages[end - 1].is_compaction())
                {
                    end -= 1;
                }
            }
            let history = &s.record.messages[..end];
            if !history.iter().any(Message::in_context) {
                return if automatic {
                    Ok(())
                } else {
                    Err(Error::Invalid("There is no completed history to compact."))
                };
            }
            let (messages, message_ids, tools) = self.request_context(&mut s.record, end, cancel);
            let history = &s.record.messages[..end];
            ProviderRequest {
                images: Default::default(),
                model: s.record.model.clone(),
                message_ids,
                incomplete_message_ids: history
                    .iter()
                    .filter(|m| m.is_incomplete_reply())
                    .map(|m| m.id().to_owned())
                    .collect(),
                messages,
                instructions: s
                    .record
                    .configuration
                    .as_ref()
                    .unwrap()
                    .instructions(&s.record.workspace, !self.definitions.is_empty()),
                effort: None,
                provider_state: s.record.provider_state.clone(),
                tools,
                cancel: cancel.clone(),
            }
        };
        let call_id = format!("compaction:{}", new_id());
        let index = {
            let mut s = self.state();
            let index = s.record.messages.len();
            s.record.messages.push(Message::Assistant {
                id: new_id(),
                text: String::new(),
                calls: vec![ToolCall {
                    id: call_id.clone(),
                    name: "compact".into(),
                    arguments: Default::default(),
                }],
                status: MessageStatus::Streaming,
            });
            s.record.executing_tool_id = Some(call_id.clone());
            s.active_tool = Some(call_id.clone());
            self.changed(&s, index);
            self.emit(
                &s,
                EventKind::ToolStarted {
                    call_id: call_id.clone(),
                },
            );
            index
        };
        let result = AssertUnwindSafe(async {
            // Persist the activity before starting effectful provider work.
            self.checkpoint(None).await?;
            self.diagnostic(DiagnosticEvent::CompactionStarted, Some(index), None).await;
            let history = self.state().record.messages.clone();
            self.resolve_images(&mut request, &history, true).await?;
            let mut compaction = Box::pin(self.provider.compact(request));
            let state = loop {
                tokio::select! {biased;
                    _=self.input_arrived.notified()=>{if self.checkpoint(None).await.is_err(){cancel.cancel();}}
                    result=&mut compaction=>break result,
                }
            }?;
            if self.state().storage_error.is_some() {
                return Err(Error::Storage);
            }
            check_cancel(cancel)?;
            if !valid_json_depth(&state, 0) || serde_json::to_vec(&state)?.len() > 8 * 1024 * 1024 {
                return Err(Error::Internal);
            }
            {
                let mut s = self.state();
                s.record.provider_state = Some(state);
                s.record.usage = None;
            }
            // Do not publish successful compaction before its checkpoint succeeds.
            self.checkpoint(None).await
        }).catch_unwind().await.unwrap_or(Err(Error::Internal));
        {
            let mut s = self.state();
            s.prefixes.invalidate(index);
            let Message::Assistant { status, .. } = &mut s.record.messages[index] else {
                unreachable!()
            };
            // The call was issued even when its execution failed or was interrupted.
            *status = MessageStatus::Completed;
            let (outcome, text) = match &result {
                Ok(()) => (ToolOutcome::Completed, "Conversation history compacted."),
                Err(_) if cancel.is_cancelled() => {
                    (ToolOutcome::Interrupted, "Compaction interrupted.")
                }
                Err(_) => (ToolOutcome::Failed, "Compaction failed."),
            };
            s.record.messages.push(Message::Tool {
                id: new_id(),
                call_id,
                text: text.into(),
                outcome,
                details: None,
            });
            s.record.executing_tool_id = None;
            s.active_tool = None;
            self.changed(&s, index);
            self.changed(&s, s.record.messages.len() - 1);
        }
        self.diagnostic(
            match &result {
                Ok(()) => DiagnosticEvent::CompactionCompleted,
                Err(_) if cancel.is_cancelled() => DiagnosticEvent::CompactionInterrupted,
                Err(_) => DiagnosticEvent::CompactionFailed,
            },
            Some(index),
            result.as_ref().err(),
        )
        .await;
        result
    }
    /// In-memory acceptance, like submit. The runner checkpoints pending input;
    /// no client-side queue or competing execution loop is involved.
    pub fn steer(&self, operation_id: &str, text: String) -> Result<String> {
        self.steer_images(operation_id, text, vec![])
    }
    pub fn steer_images(
        &self,
        operation_id: &str,
        text: String,
        images: Vec<ImageRef>,
    ) -> Result<String> {
        self.steer_attachments(operation_id, text, images, vec![])
    }
    pub(crate) fn steer_attachments(
        &self,
        operation_id: &str,
        text: String,
        images: Vec<ImageRef>,
        files: Vec<FileRef>,
    ) -> Result<String> {
        validate_message_input(&text, &images, &files)?;
        let mut s = self.state();
        if s.storage_error.is_some() {
            return Err(Error::Storage);
        }
        if s.disposed
            || s.record
                .operation
                .as_ref()
                .is_none_or(|op| op.id != operation_id)
            || s.active
                .as_ref()
                .is_none_or(|a| a.finishing || a.cancel.is_cancelled())
        {
            return Err(Error::Busy);
        }
        if files.iter().any(|file| {
            !s.record
                .resources
                .iter()
                .any(|r| r.id == file.id && r.kind == ResourceKind::File)
        }) {
            return Err(Error::Invalid("File is not owned by this conversation."));
        }
        if images.iter().any(|image| {
            !s.record
                .resources
                .iter()
                .any(|r| r.id == image.id && r.kind == ResourceKind::Image)
        }) {
            return Err(Error::Invalid("Image is not owned by this conversation."));
        }
        if s.record.pending_input.len() >= 32 {
            return Err(Error::Busy);
        }
        let id = new_id();
        s.record.metadata.activity_at = SessionMetadata::activity();
        s.record.pending_input.push(Message::User {
            files,
            images,
            id: id.clone(),
            text,
        });
        // Steering is additive. Only an explicit approval decision or cancellation
        // may resolve an outstanding action; new input is consumed by the next step.
        self.emit(
            &s,
            EventKind::Input {
                message_id: id.clone(),
            },
        );
        self.input_arrived.notify_one();
        Ok(id)
    }
    /// Remove only input that has not crossed the runner's promotion boundary.
    /// The operation may already be terminal with retained input.
    pub async fn cancel_pending_input(
        self: &Arc<Self>,
        operation_id: &str,
        message_id: &str,
    ) -> Result<bool> {
        {
            let mut s = self.state();
            if s.disposed || s.updating {
                return Err(Error::Busy);
            }
            if s.record
                .operation
                .as_ref()
                .is_none_or(|op| op.id != operation_id)
            {
                return Ok(false);
            }
            let Some(index) = s
                .record
                .pending_input
                .iter()
                .position(|m| m.id() == message_id)
            else {
                return Ok(false);
            };
            if s.storage_error.is_some() {
                return Err(Error::Storage);
            }
            s.updating = true;
            s.record.pending_input.remove(index);
        }
        // Reserve against submission and other record mutations until this ordered
        // save settles, even if the caller disconnects. Never requeue on failure.
        let conversation = self.clone();
        tokio::spawn(async move {
            let saved = AssertUnwindSafe(conversation.checkpoint(None))
                .catch_unwind()
                .await
                .unwrap_or(Err(Error::Storage));
            let mut state = conversation.state();
            state.updating = false;
            if saved.is_err() {
                state.storage_error = Some(Error::Storage.to_string());
            }
            conversation.publish_snapshot(&state);
            saved.map(|()| true)
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    fn inject_pending_input(&self, s: &mut State) {
        let pending = std::mem::take(&mut s.record.pending_input);
        if !pending.is_empty() {
            // Steering can start a new user turn without replacing the operation.
            // Reset only when input is consumed, after the previous executors settle.
            s.active.as_mut().unwrap().delegated_agents = 0;
        }
        for message in pending {
            s.record.messages.push(message);
            self.changed(s, s.record.messages.len() - 1);
        }
    }
    pub fn cancel(&self, operation_id: &str) -> bool {
        let mut s = self.state();
        if s.record
            .operation
            .as_ref()
            .is_none_or(|o| o.id != operation_id)
        {
            return false;
        }
        let Some(active) = &s.active else {
            return false;
        };
        if active.finishing {
            return false;
        }
        if !active.cancel.is_cancelled() {
            active.cancel.cancel();
            self.set_state(&mut s, OperationState::Cancelling);
        }
        true
    }
    pub fn resolve_approval(&self, operation_id: &str, approval_id: &str, approved: bool) -> bool {
        let mut s = self.state();
        if s.active.as_ref().is_none_or(|a| a.cancel.is_cancelled())
            || s.pending.as_ref().is_none_or(|p| {
                p.approval.id != approval_id || p.approval.operation_id != operation_id
            })
        {
            return false;
        }
        if let Some(pending) = s.pending.take() {
            let _ = pending.decision.send(approved);
        }
        true
    }
    /// Reserve upload ownership without replacing a concurrently changing transcript.
    pub(crate) async fn store_resource<T: Send + 'static>(
        self: &Arc<Self>,
        resource: ResourceRef,
        upload: impl std::future::Future<Output = Result<T>> + Send + 'static,
    ) -> Result<T> {
        {
            let mut state = self.state();
            if state.disposed || state.updating {
                return Err(Error::Busy);
            }
            if state.storage_error.is_some() {
                return Err(Error::Storage);
            }
            if state.record.resources.len() + state.record.cleanup_resources.len() >= 4096 {
                return Err(Error::Invalid("Too many conversation resources."));
            }
            state.record.resources.push(resource);
            state.updating = true;
        }
        let conversation = self.clone();
        tokio::spawn(async move {
            let saved = AssertUnwindSafe(conversation.checkpoint(None))
                .catch_unwind()
                .await
                .unwrap_or(Err(Error::Storage));
            let result = match saved {
                Ok(()) => AssertUnwindSafe(upload)
                    .catch_unwind()
                    .await
                    .unwrap_or(Err(Error::Internal)),
                Err(error) => {
                    conversation.state().storage_error = Some(Error::Storage.to_string());
                    Err(error)
                }
            };
            let mut state = conversation.state();
            state.updating = false;
            conversation.publish_snapshot(&state);
            result
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    async fn diagnostic(
        &self,
        event: DiagnosticEvent,
        index: Option<usize>,
        error: Option<&Error>,
    ) {
        let Some(persist) = &self.persist else {
            return;
        };
        let entry = {
            let s = self.state();
            let Some(operation) = &s.record.operation else {
                return;
            };
            SessionDiagnostic::new(
                self.id.clone(),
                operation.id.clone(),
                index.map(|index| s.record.messages[index].id().to_owned()),
                event,
                error,
            )
        };
        // Diagnostics must never turn a successful action into a failure or retry.
        // Await before settling the operation so deletion cannot race a late append.
        let _ = AssertUnwindSafe(async { persist.diagnostic(entry).await })
            .catch_unwind()
            .await;
    }
    async fn checkpoint(&self, terminal: Option<OperationState>) -> Result<()> {
        // The runner and live mutations share ordered, fresh snapshots.
        let _checkpoint = self.checkpoint_lock.lock().await;
        let mut record = {
            let s = self.state();
            if s.storage_error.is_some() {
                return Err(Error::Storage);
            }
            s.record.clone()
        };
        if let Some(state) = terminal
            && let Some(op) = &mut record.operation
        {
            op.state = state;
        }
        if let Some(persist) = &self.persist
            && persist.save(record).await.is_err()
        {
            self.state().storage_error = Some(Error::Storage.to_string());
            return Err(Error::Storage);
        }
        // Keep later checkpoints from persisting a pre-terminal operation.
        if let Some(terminal) = terminal
            && let Some(operation) = &mut self.state().record.operation
        {
            operation.state = terminal;
        }
        Ok(())
    }
    async fn run(
        &self,
        cancel: CancellationToken,
        compact_only: bool,
        title_input: Option<(String, String)>,
    ) -> Operation {
        let result = AssertUnwindSafe(async {
            self.checkpoint(None).await?;
            self.diagnostic(DiagnosticEvent::OperationStarted, None, None)
                .await;
            if compact_only {
                self.compact_history(&cancel, false).await?;
                let respond = {
                    let mut s = self.state();
                    check_cancel(&cancel)?;
                    if s.record.pending_input.is_empty() {
                        // Settle against steering/cancellation under the same lock.
                        s.active.as_mut().unwrap().finishing = true;
                        false
                    } else {
                        s.active.as_mut().unwrap().compact_only = false;
                        true
                    }
                };
                if respond {
                    self.steps(&cancel).await
                } else {
                    Ok(())
                }
            } else {
                if let Some((title, message)) = title_input {
                    let model = self.state().record.model.clone();
                    if let Some(title) = super::titles::generate(
                        self.provider.as_ref(),
                        model,
                        title,
                        message,
                        cancel.clone(),
                    )
                    .await
                    {
                        let mut state = self.state();
                        if !state.record.metadata.manually_named && !cancel.is_cancelled() {
                            state.record.metadata.title = Some(title);
                        }
                    }
                }
                self.steps(&cancel).await
            }
        })
        .catch_unwind()
        .await
        .unwrap_or(Err(Error::Internal));
        let mut terminal = match &result {
            Ok(()) => OperationState::Completed,
            Err(_) if cancel.is_cancelled() => OperationState::Interrupted,
            Err(_) => OperationState::Failed,
        };
        {
            let mut s = self.state();
            if let Err(error) = &result
                && (!cancel.is_cancelled() || *error == Error::Storage)
            {
                s.record.operation.as_mut().unwrap().error = Some(match error { Error::Provider(_) | Error::ProviderDetailed { .. } | Error::Storage | Error::Invalid("Agent step limit reached. No further request was sent.") => error.to_string(), _ => "Provider operation failed or returned an incomplete response. It was not retried.".into() });
            }
            // Invalidate before mutating any incomplete historical messages/results.
            if let Some(index) = s.record.messages.iter().position(|m| {
                matches!(
                    m,
                    Message::Assistant {
                        status: MessageStatus::Streaming,
                        ..
                    } | Message::Tool {
                        outcome: ToolOutcome::Running,
                        ..
                    }
                )
            }) {
                s.prefixes.invalidate(index);
            }
            // Panics from an embedded provider cannot leave a streaming message in terminal state.
            for m in &mut s.record.messages {
                if let Message::Assistant { status, .. } = m
                    && *status == MessageStatus::Streaming
                {
                    *status = if cancel.is_cancelled() {
                        MessageStatus::Interrupted
                    } else {
                        MessageStatus::Failed
                    };
                }
            }
            let previous = s.record.messages.len();
            let progress: Vec<_> = s
                .record
                .messages
                .iter()
                .enumerate()
                .filter_map(|(index, message)| {
                    matches!(
                        message,
                        Message::Tool {
                            outcome: ToolOutcome::Running,
                            ..
                        }
                    )
                    .then_some(index)
                })
                .collect();
            let intent = s.record.executing_tool_id.take();
            finish_missing_results(&mut s.record.messages, intent.as_deref());
            s.active_tool = None;
            s.pending = None;
            s.active.as_mut().unwrap().finishing = true;
            for index in progress
                .into_iter()
                .chain(previous..s.record.messages.len())
            {
                self.changed(&s, index);
            }
        }
        if self.state().storage_error.is_none() {
            let _ = self.checkpoint(Some(terminal)).await;
        }
        let diagnostic_error = if self.state().storage_error.is_some() {
            terminal = OperationState::Failed;
            Some(Error::Storage)
        } else {
            result.as_ref().err().cloned()
        };
        self.diagnostic(
            match terminal {
                OperationState::Completed => DiagnosticEvent::OperationCompleted,
                OperationState::Interrupted => DiagnosticEvent::OperationInterrupted,
                _ => DiagnosticEvent::OperationFailed,
            },
            None,
            diagnostic_error.as_ref(),
        )
        .await;
        let mut s = self.state();
        if s.storage_error.is_some() {
            terminal = OperationState::Failed;
            s.record.operation.as_mut().unwrap().error = Some(Error::Storage.to_string());
        }
        s.active = None;
        self.set_state(&mut s, terminal);
        s.record.operation.clone().unwrap()
    }
    async fn steps(&self, cancel: &CancellationToken) -> Result<()> {
        check_cancel(cancel)?;
        self.checkpoint(None).await?;
        {
            let mut s = self.state();
            self.set_state(&mut s, OperationState::Running);
        }
        let model = self.state().record.model.clone();
        self.provider.prepare_model(&model, cancel.clone()).await?;
        let max_steps = self.state().record.max_steps;
        for step in 0..max_steps {
            check_cancel(cancel)?;
            self.compact_history(cancel, true).await?;
            let (calls, needs_continuation) = self.respond(cancel).await?;
            self.checkpoint(None).await?;
            check_cancel(cancel)?;
            self.validate_tool_batch(&calls, step + 1 < max_steps)?;
            self.execute_calls(&calls, cancel).await?;
            check_cancel(cancel)?;
            if calls.is_empty() && !needs_continuation {
                let mut s = self.state();
                if s.record.pending_input.is_empty() {
                    // Linearize settlement against steering under the same lock.
                    s.active.as_mut().unwrap().finishing = true;
                    return Ok(());
                }
            }
        }
        Err(Error::Invalid(
            "Agent step limit reached. No further request was sent.",
        ))
    }
    async fn respond(&self, cancel: &CancellationToken) -> Result<(Vec<ToolCall>, bool)> {
        let (mut request, index, mut known) = {
            let mut s = self.state();
            // Include input accepted during compaction too. This lock establishes
            // which instructions belong to the response that is about to start.
            self.inject_pending_input(&mut s);
            let end = s.record.messages.len();
            let (messages, message_ids, tools) = self.request_context(&mut s.record, end, cancel);
            let known: HashSet<String> = s
                .record
                .messages
                .iter()
                .flat_map(|m| match m {
                    Message::Assistant { calls, .. } => {
                        calls.iter().map(|c| c.id.clone()).collect()
                    }
                    _ => Vec::new(),
                })
                .collect();
            let index = s.record.messages.len();
            s.record.messages.push(Message::Assistant {
                id: new_id(),
                text: String::new(),
                calls: vec![],
                status: MessageStatus::Streaming,
            });
            self.changed(&s, index);
            (
                ProviderRequest {
                    images: Default::default(),
                    incomplete_message_ids: s.record.messages[..index]
                        .iter()
                        .filter(|m| m.is_incomplete_reply())
                        .map(|m| m.id().to_owned())
                        .collect(),
                    message_ids,
                    model: s.record.model.clone(),
                    effort: s
                        .record
                        .configuration
                        .as_ref()
                        .unwrap()
                        .settings
                        .effort
                        .clone(),
                    provider_state: s.record.provider_state.clone(),
                    instructions: s
                        .record
                        .configuration
                        .as_ref()
                        .unwrap()
                        .instructions(&s.record.workspace, !self.definitions.is_empty()),
                    messages,
                    tools,
                    cancel: cancel.clone(),
                },
                index,
                known,
            )
        };
        let mut metadata = None;
        let response: Result<(Vec<ToolCall>, bool)> = async {
            self.checkpoint(None).await?;
            check_cancel(cancel)?;
            self.diagnostic(DiagnosticEvent::ResponseStarted, Some(index), None)
                .await;
            let history = self.state().record.messages[..index].to_vec();
            self.resolve_images(&mut request, &history, false).await?;
            let mut stream = self.provider.stream(request);
            let mut calls = vec![];
            let mut last_save: Option<Instant> = None;
            loop {
                let event = tokio::select! {
                    biased;
                    _ = self.input_arrived.notified() => { self.checkpoint(None).await?; continue; }
                    event = stream.next() => event,
                };
                let Some(event) = event else {
                    break;
                };
                check_cancel(cancel)?;
                match event? {
                    ProviderEvent::TextSnapshot(value) => {
                        let mut s = self.text_state();
                        s.prefixes.invalidate(index);
                        let Message::Assistant { text, .. } = &mut s.record.messages[index] else {
                            unreachable!()
                        };
                        *text = value;
                        self.changed(&s, index);
                    }
                    ProviderEvent::Text(delta) => {
                        {
                            let mut s = self.text_state();
                            s.prefixes.invalidate(index);
                            let Message::Assistant { id, text, .. } = &mut s.record.messages[index]
                            else {
                                unreachable!()
                            };
                            text.push_str(&delta);
                            let message_id = id.clone();
                            self.emit(&s, EventKind::Text { message_id, delta });
                        }
                        if last_save.is_none_or(|time| time.elapsed() >= Duration::from_secs(1)) {
                            self.checkpoint(None).await?;
                            last_save = Some(Instant::now());
                        }
                    }
                    ProviderEvent::ToolCall(call) => {
                        if call.id.is_empty()
                            || call.id.starts_with("compaction:")
                            || call.name.is_empty()
                            || !known.insert(call.id.clone())
                            || calls.len() >= 64
                        {
                            return Err(Error::Internal);
                        }
                        calls.push(call);
                    }
                    ProviderEvent::Metadata { state, usage } => {
                        if usage.as_ref().is_some_and(|usage| !usage.valid()) {
                            return Err(Error::Internal);
                        }
                        if metadata.is_some()
                            || state.as_ref().is_some_and(|state| {
                                !valid_json_depth(state, 0)
                                    || serde_json::to_vec(state)
                                        .map_or(true, |bytes| bytes.len() > 8 * 1024 * 1024)
                            })
                        {
                            return Err(Error::Internal);
                        }
                        metadata = Some((state, usage));
                    }
                    end @ (ProviderEvent::Done | ProviderEvent::Continue) => {
                        check_cancel(cancel)?;
                        return Ok((calls, matches!(end, ProviderEvent::Continue)));
                    }
                }
            }
            Err(Error::Internal)
        }
        .await;
        {
            let mut s = self.state();
            // Provider state and the finalized reply must be visible atomically:
            // a concurrent checkpoint must not pair completed opaque output with
            // a streaming reply that recovery would mark incomplete.
            if let Some((state, usage)) = metadata.filter(|_| response.is_ok()) {
                s.record.provider_state = state;
                // Preserve the last measurement when this response reports none.
                if usage.is_some() {
                    s.record.usage = usage;
                }
            }
            s.prefixes.invalidate(index);
            let Message::Assistant { calls, status, .. } = &mut s.record.messages[index] else {
                unreachable!()
            };
            match &response {
                Ok((batch, _)) => {
                    *calls = batch.clone();
                    *status = MessageStatus::Completed;
                }
                Err(_) => {
                    *status = if cancel.is_cancelled() {
                        MessageStatus::Interrupted
                    } else {
                        MessageStatus::Failed
                    }
                }
            }
            self.changed(&s, index);
        }
        self.diagnostic(
            match &response {
                Ok(_) => DiagnosticEvent::ResponseCompleted,
                Err(_) if cancel.is_cancelled() => DiagnosticEvent::ResponseInterrupted,
                Err(_) => DiagnosticEvent::ResponseFailed,
            },
            Some(index),
            response.as_ref().err(),
        )
        .await;
        response
    }
    async fn resolve_images(
        &self,
        request: &mut ProviderRequest,
        history: &[Message],
        compaction: bool,
    ) -> Result<()> {
        let reader = self.images.lock().unwrap().clone();
        let mut total_bytes = 0usize;
        let indices = if compaction {
            self.provider.compaction_image_context_indices(request)?
        } else {
            self.provider.image_context_indices(request)?
        };
        for index in indices {
            let id = request.message_ids.get(index).ok_or(Error::Internal)?;
            let refs = history
                .iter()
                .find(|m| m.id() == id)
                .map(Message::images)
                .unwrap_or_default();
            if refs.is_empty() {
                continue;
            }
            if !self
                .provider
                .accepts_images(&request.model, request.cancel.clone())
                .await?
            {
                if matches!(
                    history.iter().find(|m| m.id() == id),
                    Some(Message::Tool { .. })
                ) {
                    if let Some(ContextMessage::Tool { text, .. }) = request.messages.get_mut(index)
                    {
                        text.push_str("\n[Image contents are unavailable to this model. Do not claim to have inspected them.]");
                    }
                    continue;
                }
                return Err(Error::Invalid(
                    "The selected model does not accept image input.",
                ));
            }
            let reader = reader
                .as_ref()
                .ok_or(Error::Invalid("Image storage is unavailable."))?;
            let mut inputs = Vec::new();
            for image in refs {
                check_cancel(&request.cancel)?;
                total_bytes = total_bytes.saturating_add(image.byte_count);
                if total_bytes > 16 * 1024 * 1024 {
                    return Err(Error::Invalid(
                        "Active image context exceeds 16 MiB. Compact or start a new conversation.",
                    ));
                }
                inputs.push(reader.load(image).await?);
            }
            request.images.insert(index, inputs);
        }
        Ok(())
    }
    async fn ask(
        &self,
        call: &ToolCall,
        description: String,
        details: Option<ToolDetails>,
        cancel: &CancellationToken,
    ) -> Result<bool> {
        check_cancel(cancel)?;
        {
            self.state().record.operation.as_mut().unwrap().state =
                OperationState::AwaitingApproval;
        }
        self.checkpoint(None).await?;
        check_cancel(cancel)?;
        let (send, mut receive) = oneshot::channel();
        {
            let mut s = self.state();
            check_cancel(cancel)?;
            let approval = Approval {
                id: new_id(),
                operation_id: s.record.operation.as_ref().unwrap().id.clone(),
                call: call.clone(),
                description,
                details,
                workspace: s.record.workspace.clone(),
            };
            let approval_id = Some(approval.id.clone());
            s.pending = Some(Pending {
                approval,
                decision: send,
            });
            self.set_state(&mut s, OperationState::AwaitingApproval);
            self.emit(&s, EventKind::Approval { approval_id });
        }
        let decision = loop {
            tokio::select! { biased;
                _ = cancel.cancelled() => break false,
                value = &mut receive => break value.unwrap_or(false),
                _ = self.input_arrived.notified() => self.checkpoint(None).await?,
            }
        };
        {
            let mut s = self.state();
            s.pending = None;
            self.emit(&s, EventKind::Approval { approval_id: None });
            check_cancel(cancel)?;
            self.set_state(&mut s, OperationState::Running);
        }
        Ok(decision)
    }
    fn validate_tool_batch(&self, calls: &[ToolCall], has_continuation: bool) -> Result<()> {
        let standalone = calls.iter().any(|call| {
            self.tools.get(&call.name).is_some_and(|tool| {
                tool.execution_policy() == ToolExecutionPolicy::StandaloneWithContinuation
            })
        });
        if standalone {
            if calls.len() != 1 {
                return Err(Error::Invalid(
                    "This tool requires a standalone response. No tools were executed.",
                ));
            }
            if !has_continuation {
                return Err(Error::Invalid(
                    "Agent step limit reached. No further request was sent.",
                ));
            }
        }
        Ok(())
    }
    async fn execute_calls(&self, calls: &[ToolCall], cancel: &CancellationToken) -> Result<()> {
        for call in calls {
            let mut outcome = ToolOutcome::NotExecuted;
            let mut details = None;
            let mut text =
                "Not executed: operation interrupted. Do not retry without a new user request."
                    .to_string();
            // Finish calls from the current response before injecting steering.
            // Input must not invalidate preparation, approval or execution in flight.
            if !cancel.is_cancelled() {
                if !self.state().record.metadata.tool_enabled(&call.name) {
                    outcome = ToolOutcome::NotExecuted;
                    text = "Tool is disabled for this session. Nothing was executed. Do not retry without a new user request.".into();
                } else if let Some(tool) = self.tools.get(&call.name) {
                    let mut started = false;
                    let action = AssertUnwindSafe(async {
                        let context = {
                            let state = self.state();
                            let record = &state.record;
                            let owned: HashSet<_> = record.resources.iter()
                                .filter(|r| r.kind == ResourceKind::Image)
                                .map(|r| r.id.as_str()).collect();
                            let available_images = record.messages.iter().flat_map(Message::images)
                                .filter(|image| owned.contains(image.id.as_str())).cloned().collect();
                            ToolContext {
                                available_images,
                                conversation_id: self.id.clone(),
                                capture_preview: None,
                                operation_id: record.operation.as_ref().unwrap().id.clone(),
                                search_model: record.configuration.as_ref().unwrap().settings.search_model.clone(),
                                call_id: call.id.clone(),
                                model: record.model.clone(),
                                workspace: record.workspace.clone(),
                                cancel: cancel.clone(),
                            }
                        };
                        if !tool.available(&context) {
                            return Ok((ToolOutcome::NotExecuted, "Tool is currently unavailable. Nothing was executed. Do not retry without a new user request.".into()));
                        }
                        let prepared = tool.prepare(call.arguments.clone(), context).await?;
                        check_cancel(cancel)?;
                        // Read once per call: updates do not resolve an approval or revoke authorization.
                        let auto_approve = self.state().record.configuration.as_ref().unwrap().settings.auto_approve;
                        let asks_approval = !auto_approve && prepared.approval().is_some();
                        let approved = if let Some(description) = prepared.approval().filter(|_| !auto_approve) { self.ask(call,description.into(),prepared.details(),cancel).await? } else { true };
                        check_cancel(cancel)?;
                        if !approved { return Ok((ToolOutcome::Denied,"User denied this action. Nothing was executed. Do not retry without a new user request.".into())); }
                        if asks_approval { prepared.approval_granted()?; }
                        {
                            let resources = prepared.resources(); let mut s = self.state();
                            let mut ids: HashSet<_> = s.record.resources.iter().chain(&s.record.cleanup_resources).map(|r|r.id.clone()).collect();
                            if s.record.resources.len()+s.record.cleanup_resources.len()+resources.len()>4096 || resources.iter().any(|r|!valid_id(&r.id)||r.call_id!=call.id||!ids.insert(r.id.clone())) { return Err(Error::Internal); }
                            s.record.resources.extend(resources);
                            s.record.executing_tool_id=Some(call.id.clone());
                        }
                        self.checkpoint(None).await?; check_cancel(cancel)?;
                        {
                            let mut s = self.state();
                            started=true; s.active_tool=Some(call.id.clone());
                        }
                        // Poll once before announcing entry: Rust async functions are lazy.
                        let mut execution = AssertUnwindSafe(prepared.execute_output()).catch_unwind();
                        let first = futures_util::poll!(&mut execution);
                        { let s=self.state(); self.emit(&s,EventKind::ToolStarted{call_id:call.id.clone()}); }
                        let result = match first {
                            Poll::Ready(result) => result,
                            Poll::Pending => loop {
                                tokio::select! { biased;
                                    _ = self.input_arrived.notified() => {
                                        // Delegation may own the checkpoint lock. Keep polling
                                        // its executor while saving steering, and never drop an
                                        // in-flight save if execution settles first.
                                        let save = self.checkpoint(None);
                                        tokio::pin!(save);
                                        let saved = tokio::select! {
                                            saved = &mut save => saved,
                                            result = &mut execution => {
                                                if save.await.is_err() { cancel.cancel(); }
                                                break result;
                                            }
                                        };
                                        if saved.is_err() { cancel.cancel(); }
                                        // Never drop an executor to simulate cancellation: keep owning cleanup.
                                    }
                                    result = &mut execution => break result,
                                }
                            }
                        };
                        // A known successful effect stays completed even if cancellation
                        // raced its return. The runner stops subsequent work separately.
                        let result = result.unwrap_or(Err(Error::Internal))?;
                        details = result.details;
                        Ok((ToolOutcome::Completed,result.text))
                    }).catch_unwind().await.unwrap_or(Err(Error::Internal));
                    self.state().active_tool = None;
                    match action {
                        Ok((o, t)) => {
                            outcome = o;
                            text = t;
                        }
                        Err(Error::Storage) => {
                            // If execution started, keep its intent until settlement
                            // finalizes it and any running result under the same lock.
                            if !started {
                                self.state().record.executing_tool_id = None;
                            }
                            return Err(Error::Storage);
                        }
                        Err(error) => {
                            outcome = if cancel.is_cancelled() {
                                if started {
                                    ToolOutcome::Interrupted
                                } else {
                                    ToolOutcome::NotExecuted
                                }
                            } else {
                                ToolOutcome::Failed
                            };
                            text = if let Error::Tool(safe) = error {
                                format!("{safe}\nDo not retry without a new user request.")
                            } else if started {
                                "Action failed or was interrupted after execution began; it may have had effects. Do not retry without a new user request.".into()
                            } else {
                                "Action did not execute. Preparation failed or the operation was interrupted. Do not retry without a new user request.".into()
                            };
                        }
                    }
                } else {
                    outcome = ToolOutcome::Failed;
                    text = "Unknown tool. Nothing was executed.".into();
                }
            }
            {
                let mut s = self.state();
                let index = if let Some(index) = s.record.messages.iter().position(|m| matches!(m,
                    Message::Tool { call_id, outcome: ToolOutcome::Running, .. } if call_id == &call.id
                )) {
                    s.prefixes.invalidate(index);
                    let Message::Tool { text: saved_text, outcome: saved_outcome, details: saved_details, .. } = &mut s.record.messages[index] else { unreachable!() };
                    if outcome == ToolOutcome::Completed || *saved_text == text {
                        *saved_text = text;
                    } else {
                        append_delegation_notice(saved_text, &text);
                    }
                    *saved_outcome = outcome;
                    if details.is_some() { *saved_details = details; }
                    index
                } else {
                    s.record.messages.push(Message::Tool {
                        id: new_id(),
                        call_id: call.id.clone(),
                        text,
                        outcome,
                        details,
                    });
                    s.record.messages.len() - 1
                };
                s.record.executing_tool_id = None;
                self.changed(&s, index);
            }
            self.checkpoint(None).await?;
            if matches!(outcome, ToolOutcome::Completed | ToolOutcome::Failed)
                && let Some(tool) = self.tools.get(&call.name)
            {
                tool.result_saved(&self.id, &call.id).await?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct NoInference;
    impl ChatProvider for NoInference {
        fn stream(
            &self,
            _: ProviderRequest,
        ) -> futures_util::stream::BoxStream<'static, Result<ProviderEvent>> {
            panic!("A stale workspace must not reach inference")
        }
    }

    struct PolicyTool {
        name: &'static str,
        policy: ToolExecutionPolicy,
    }
    #[async_trait]
    impl Tool for PolicyTool {
        fn definition(&self) -> ToolDefinition {
            ToolDefinition {
                name: self.name.into(),
                description: String::new(),
                parameters: Arguments::new(),
            }
        }
        fn execution_policy(&self) -> ToolExecutionPolicy {
            self.policy
        }
        async fn prepare(&self, _: Arguments, _: ToolContext) -> Result<Box<dyn PreparedTool>> {
            panic!("Policy validation must precede preparation")
        }
    }
    fn policy_call(id: &str, name: &str) -> ToolCall {
        ToolCall {
            id: id.into(),
            name: name.into(),
            arguments: Arguments::new(),
        }
    }

    #[test]
    fn standalone_policy_requires_an_entire_response_and_a_continuation() {
        let mut options = ConversationOptions::new(Arc::new(NoInference), "fake", "/test");
        options.tools = vec![
            Arc::new(PolicyTool {
                name: "pause",
                policy: ToolExecutionPolicy::StandaloneWithContinuation,
            }),
            Arc::new(PolicyTool {
                name: "ordinary",
                policy: ToolExecutionPolicy::Standard,
            }),
        ];
        let c = Conversation::new(options, None).unwrap();
        let pause = policy_call("pause-1", "pause");
        let ordinary = policy_call("ordinary-1", "ordinary");
        assert!(
            c.validate_tool_batch(std::slice::from_ref(&pause), true)
                .is_ok()
        );
        assert!(
            c.validate_tool_batch(std::slice::from_ref(&pause), false)
                .is_err()
        );
        assert!(
            c.validate_tool_batch(&[pause.clone(), ordinary.clone()], true)
                .is_err()
        );
        assert!(
            c.validate_tool_batch(&[ordinary.clone(), pause.clone()], true)
                .is_err()
        );
        assert!(
            c.validate_tool_batch(&[pause, policy_call("pause-2", "pause")], true)
                .is_err()
        );
        assert!(c.validate_tool_batch(&[ordinary], false).is_ok());
        assert!(c.validate_tool_batch(&[], false).is_ok());
    }

    #[test]
    fn active_tool_name_is_derived_only_from_the_live_call_and_survives_catalog_stripping() {
        let c = Conversation::new(
            ConversationOptions::new(Arc::new(NoInference), "fake", "/test"),
            None,
        )
        .unwrap();
        {
            let mut s = c.state();
            s.record.messages.push(Message::Assistant {
                id: new_id(),
                text: String::new(),
                status: MessageStatus::Completed,
                calls: vec![policy_call("first", "one"), policy_call("second", "two")],
            });
            s.record.executing_tool_id = Some("second".into());
        }
        // A persisted execution intent (including one awaiting checkpoint) is not live ownership.
        assert!(c.snapshot().active_tool_name.is_none());
        c.state().active_tool = Some("second".into());
        let mut snapshot = c.snapshot();
        assert_eq!(snapshot.active_tool_name.as_deref(), Some("two"));
        snapshot.messages.clear();
        let mut wire = serde_json::to_value(&snapshot).unwrap();
        assert_eq!(wire["activeToolName"], "two");
        assert_eq!(wire["activeToolCallID"], "second");
        assert_eq!(
            serde_json::from_value::<ConversationSnapshot>(wire.clone()).unwrap(),
            snapshot
        );
        wire.as_object_mut().unwrap().remove("activeToolName");
        assert!(
            serde_json::from_value::<ConversationSnapshot>(wire)
                .unwrap()
                .active_tool_name
                .is_none()
        );
        c.state().active_tool = Some("first".into());
        assert_eq!(c.snapshot().active_tool_name.as_deref(), Some("one"));
        c.state().active_tool = None;
        assert!(c.snapshot().active_tool_name.is_none());
        assert!(
            serde_json::to_value(c.snapshot())
                .unwrap()
                .get("activeToolName")
                .is_none()
        );
        assert!(
            serde_json::to_value(c.record())
                .unwrap()
                .get("activeToolName")
                .is_none()
        );
    }

    #[tokio::test]
    async fn sync_cache_bounds_tail_work_and_invalidates_historical_replacement() {
        use sha2::{Digest, Sha256};
        let c = Conversation::new(
            ConversationOptions::new(Arc::new(NoInference), "fake", "/test"),
            None,
        )
        .unwrap();
        let hub = Arc::new(ChangeHub::default());
        c.attach_changes(&hub);
        let mut changes = hub.subscribe();
        {
            let mut s = c.state();
            s.record.configuration.as_mut().unwrap().instructions_frozen = true;
            s.record.messages = (0..200)
                .map(|n| Message::User {
                    id: new_id(),
                    text: format!("message {n}"),
                    images: vec![],
                    files: vec![],
                })
                .collect();
            s.record.operation = Some(Operation {
                id: new_id(),
                state: OperationState::Completed,
                error: None,
            });
        }
        let first = c.sync(SyncCursor::Latest).unwrap();
        assert_eq!(first.offset, 168);
        assert_eq!(first.snapshot.messages.len(), 32);
        let anchor = first.snapshot.messages.last().unwrap().id().to_owned();
        let proof = first.prefix.unwrap();
        let previous = changes.borrow_and_update().clone();
        for _ in 0..10 {
            let mut s = c.text_state();
            s.prefixes.invalidate(199);
            if let Message::User { text, .. } = &mut s.record.messages[199] {
                text.push('x');
            }
            c.changed(&s, 199);
            c.publish_snapshot(&s);
            drop(s);
            let page = c
                .sync(SyncCursor::After {
                    anchor: &anchor,
                    prefix: &proof,
                })
                .unwrap();
            assert!(!page.reset);
            assert_eq!(page.snapshot.messages.len(), 1);
            assert_eq!(page.prefix.as_deref(), Some(proof.as_str()));
            c.summary();
        }
        assert_eq!(c.state().prefixes.serialized, 199);
        assert_eq!(
            c.state().full_snapshots.get(),
            0,
            "notifications, sync, and summaries never construct full snapshots"
        );
        let next = changes.borrow_and_update().clone();
        assert_eq!(previous.catalog, next.catalog);
        assert_ne!(previous.conversations, next.conversations);
        c.mutate_record(|record| {
            if let Message::User { text, .. } = &mut record.messages[3] {
                *text = "historical edit".into();
            }
            Ok(())
        })
        .await
        .unwrap();
        let reset = c
            .sync(SyncCursor::After {
                anchor: &anchor,
                prefix: &proof,
            })
            .unwrap();
        assert!(reset.reset);
        assert_eq!(reset.offset, 168);
        assert_eq!(reset.snapshot.messages.len(), 32);
        let record = c.record();
        assert_eq!(
            reset.prefix.unwrap(),
            format!(
                "{:x}",
                Sha256::digest(serde_json::to_vec(&record.messages[..199]).unwrap())
            )
        );
        c.mutate_record(|record| {
            record.messages.clear();
            Ok(())
        })
        .await
        .unwrap();
        let empty = c.sync(SyncCursor::Latest).unwrap();
        assert_eq!(empty.total, 0);
        assert!(empty.prefix.is_none());
    }

    #[test]
    fn sync_late_growth_preserves_incremental_catch_up_until_lookup_boundary() {
        use sha2::{Digest, Sha256};
        for growth in [0, 31, 32, 63, 64] {
            let c = Conversation::new(
                ConversationOptions::new(Arc::new(NoInference), "fake", "/test"),
                None,
            )
            .unwrap();
            {
                let mut s = c.state();
                s.record.messages = (0..200)
                    .map(|n| Message::User {
                        id: new_id(),
                        text: format!("message {n}"),
                        images: vec![],
                        files: vec![],
                    })
                    .collect();
            }
            let initial = c.sync(SyncCursor::Latest).unwrap();
            let anchor = initial.snapshot.messages.last().unwrap().id().to_owned();
            let proof = initial.prefix.unwrap();
            {
                let mut s = c.state();
                s.record.messages.extend((0..growth).map(|n| Message::User {
                    id: new_id(),
                    text: format!("late message {n}"),
                    images: vec![],
                    files: vec![],
                }));
            }
            let page = c
                .sync(SyncCursor::After {
                    anchor: &anchor,
                    prefix: &proof,
                })
                .unwrap();
            let total = 200 + growth;
            let reset = growth >= 64;
            let offset = if reset { total - 32 } else { 199 };
            assert_eq!(page.reset, reset, "growth {growth}");
            assert_eq!(page.total, total);
            assert_eq!(page.offset, offset);
            assert_eq!(page.snapshot.messages.len(), total - offset);
            let record = c.record();
            assert_eq!(
                page.snapshot.messages,
                record.messages[offset..],
                "catch-up must include the anchor and every appended message"
            );
            assert_eq!(
                page.prefix.unwrap(),
                format!(
                    "{:x}",
                    Sha256::digest(serde_json::to_vec(&record.messages[..total - 1]).unwrap())
                )
            );
        }
    }

    #[test]
    fn replacement_registration_fences_old_handles_and_deletion() {
        let hub = Arc::new(ChangeHub::default());
        let old = Conversation::new(
            ConversationOptions::new(Arc::new(NoInference), "fake", "/test"),
            None,
        )
        .unwrap();
        old.attach_changes(&hub);
        let replacement = Conversation::new(
            ConversationOptions::new(Arc::new(NoInference), "fake", "/test"),
            Some(old.record()),
        )
        .unwrap();
        replacement.attach_changes(&hub);
        let mut rx = hub.subscribe();
        let before = rx.borrow_and_update().clone();
        old.state().record.metadata.title = Some("stale".into());
        assert!(!rx.has_changed().unwrap());
        replacement.state().record.metadata.title = Some("live".into());
        assert_ne!(rx.borrow_and_update().conversations, before.conversations);
        hub.remove(&old.id);
        assert!(rx.borrow_and_update().conversations.is_empty());
        replacement.state().record.metadata.title = Some("deleted".into());
        assert!(!rx.has_changed().unwrap());
    }

    #[test]
    fn stale_workspace_instructions_are_rejected_before_acceptance() {
        let c = Conversation::new(
            ConversationOptions::new(Arc::new(NoInference), "fake", "/new"),
            None,
        )
        .unwrap();
        assert!(matches!(
            c.submit_attachments_with_naming(
                "first".into(),
                vec![],
                vec![],
                Some("old instructions".into()),
                false,
                Some("/old"),
            ),
            Err(Error::Busy)
        ));
        let snapshot = c.snapshot();
        assert!(snapshot.messages.is_empty() && snapshot.operation.is_none());
        assert!(!snapshot.configuration.instructions_frozen);
        assert_eq!(snapshot.configuration.workspace_instructions, None);
    }
}
