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
}
impl State {
    fn snapshot(&self, provider: &dyn ChatProvider) -> ConversationSnapshot {
        ConversationSnapshot {
            id: self.record.id.clone(),
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
            messages: self.record.messages.clone(),
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
            approval: self.pending.as_ref().map(|p| p.approval.clone()),
            active_tool_call_id: self.active_tool.clone(),
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
/// Keep an idle descendant from starting work across a parent's durable reset.
/// Dropping also wakes observers waiting for an in-flight mutation to settle.
pub(crate) struct IdleReservation(Arc<Conversation>);
impl Drop for IdleReservation {
    fn drop(&mut self) {
        let mut state = self.0.state();
        state.updating = false;
        self.0.events.send(Arc::new(ServiceEvent::Snapshot {
            snapshot: state.snapshot(self.0.provider.as_ref()),
        }));
    }
}

pub struct Submission {
    pub operation_id: String,
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
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().expect("conversation state lock poisoned")
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
            s.record.version = 10;
            index
        };
        let saved = self.checkpoint(None).await;
        self.changed(&self.state(), index);
        saved
    }
    pub fn resources(&self) -> Vec<ResourceRef> {
        self.state().record.resources.clone()
    }
    pub fn record(&self) -> ConversationRecord {
        self.state().record.clone()
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
    fn enabled_definitions<'a>(
        &'a self,
        record: &'a ConversationRecord,
    ) -> impl Iterator<Item = &'a ToolDefinition> {
        self.definitions
            .iter()
            .filter(|d| record.metadata.tool_enabled(&d.name))
    }
    pub(crate) fn reserve_idle(self: &Arc<Self>) -> Result<IdleReservation> {
        let mut state = self.state();
        if state.disposed || state.active.is_some() || state.updating {
            return Err(Error::Busy);
        }
        state.updating = true;
        Ok(IdleReservation(self.clone()))
    }
    /// Called under the manager's catalog lock after checking delegation ownership.
    /// Retain descendant reservations through both the save and publication.
    pub(crate) fn start_clear(
        self: &Arc<Self>,
        descendants: Vec<IdleReservation>,
    ) -> Result<tokio::task::JoinHandle<Result<ConversationSnapshot>>> {
        self.start_mutation(
            |record| {
                record.messages.clear();
                record.pending_input.clear();
                record.operation = None;
                record.executing_tool_id = None;
                record.provider_state = None;
                record.usage = None;
                // Drop ownership only; forks/other sessions may still use these files.
                record.resources.clear();
                record.metadata.activity_at = SessionMetadata::activity();
                Ok(())
            },
            descendants,
        )
    }
    pub(crate) async fn mutate_record(
        self: &Arc<Self>,
        mutate: impl FnOnce(&mut ConversationRecord) -> Result<()>,
    ) -> Result<ConversationSnapshot> {
        self.start_mutation(mutate, vec![])?
            .await
            .map_err(|_| Error::Internal)?
    }
    fn start_mutation(
        self: &Arc<Self>,
        mutate: impl FnOnce(&mut ConversationRecord) -> Result<()>,
        keep_idle: Vec<IdleReservation>,
    ) -> Result<tokio::task::JoinHandle<Result<ConversationSnapshot>>> {
        let record = {
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
            let mut record = s.record.clone();
            mutate(&mut record)?;
            record.validate()?;
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
    fn emit(&self, s: &State, kind: EventKind) {
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
            // Opaque provider context may include calls omitted from this snapshot.
            record.provider_state = None;
            record.usage = None;
        }
        record.id = new_id();
        // An explicit user fork is independent, not another execution of the parent's call.
        record.metadata.parent = None;
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
            s.record.metadata.title = Some(
                text.split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .chars()
                    .take(80)
                    .collect(),
            );
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
        s.record.messages.push(Message::User {
            id: new_id(),
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
            completion,
        })
    }
    async fn compact_history(&self, cancel: &CancellationToken, automatic: bool) -> Result<()> {
        check_cancel(cancel)?;
        let mut request = {
            let s = self.state();
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
                if tokens < window.saturating_mul(95).div_ceil(100) {
                    return Ok(());
                }
            }
            let mut end = s.record.messages.len();
            if automatic {
                while end > 0
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
            let messages = context(history);
            let message_ids = history
                .iter()
                .filter(|m| m.in_context())
                .map(|m| m.id().to_owned())
                .collect();
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
                instructions: s.record.configuration.as_ref().unwrap().instructions(
                    &s.record.workspace,
                    self.enabled_definitions(&s.record).next().is_some(),
                ),
                effort: None,
                provider_state: s.record.provider_state.clone(),
                tools: self.enabled_definitions(&s.record).cloned().collect(),
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
            let history = self.state().record.messages.clone();
            self.resolve_images(&mut request, &history).await?;
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
                .is_none_or(|a| a.finishing || a.compact_only || a.cancel.is_cancelled())
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
            if state.record.resources.len() >= 4096 {
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
            conversation.events.send(Arc::new(ServiceEvent::Snapshot {
                snapshot: state.snapshot(conversation.provider.as_ref()),
            }));
            result
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    async fn checkpoint(&self, terminal: Option<OperationState>) -> Result<()> {
        // Upload ownership and the runner share ordered, fresh snapshots.
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
        // Keep later upload checkpoints from persisting a pre-terminal operation.
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
            if compact_only {
                self.checkpoint(None).await?;
                self.compact_history(&cancel, false).await
            } else {
                self.checkpoint(None).await?;
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
                s.record.operation.as_mut().unwrap().error = Some(match error { Error::Provider(_) | Error::Storage | Error::Invalid("Agent step limit reached. No further request was sent.") => error.to_string(), _ => "Provider operation failed or returned an incomplete response. It was not retried.".into() });
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
        for _ in 0..max_steps {
            check_cancel(cancel)?;
            self.compact_history(cancel, true).await?;
            let calls = self.respond(cancel).await?;
            self.checkpoint(None).await?;
            self.execute_calls(&calls, cancel).await?;
            check_cancel(cancel)?;
            if calls.is_empty() {
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
    async fn respond(&self, cancel: &CancellationToken) -> Result<Vec<ToolCall>> {
        let (mut request, index, mut known) = {
            let mut s = self.state();
            // Include input accepted during compaction too. This lock establishes
            // which instructions belong to the response that is about to start.
            self.inject_pending_input(&mut s);
            let messages = context(&s.record.messages);
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
                    message_ids: s.record.messages[..index]
                        .iter()
                        .filter(|m| m.in_context())
                        .map(|m| m.id().to_owned())
                        .collect(),
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
                    instructions: s.record.configuration.as_ref().unwrap().instructions(
                        &s.record.workspace,
                        self.enabled_definitions(&s.record).next().is_some(),
                    ),
                    messages,
                    tools: {
                        let context = ToolContext {
                            conversation_id: self.id.clone(),
                            operation_id: s.record.operation.as_ref().unwrap().id.clone(),
                            call_id: String::new(),
                            model: s.record.model.clone(),
                            search_model: s
                                .record
                                .configuration
                                .as_ref()
                                .unwrap()
                                .settings
                                .search_model
                                .clone(),
                            workspace: s.record.workspace.clone(),
                            cancel: cancel.clone(),
                        };
                        self.enabled_definitions(&s.record)
                            .filter(|d| {
                                self.tools
                                    .get(&d.name)
                                    .is_some_and(|t| t.available(&context))
                            })
                            .cloned()
                            .collect()
                    },
                    cancel: cancel.clone(),
                },
                index,
                known,
            )
        };
        let mut metadata = None;
        let response: Result<Vec<ToolCall>> = async {
            self.checkpoint(None).await?;
            check_cancel(cancel)?;
            let history = self.state().record.messages[..index].to_vec();
            self.resolve_images(&mut request, &history).await?;
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
                        let mut s = self.state();
                        let Message::Assistant { text, .. } = &mut s.record.messages[index] else {
                            unreachable!()
                        };
                        *text = value;
                        self.changed(&s, index);
                    }
                    ProviderEvent::Text(delta) => {
                        {
                            let mut s = self.state();
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
                    ProviderEvent::Done => {
                        check_cancel(cancel)?;
                        return Ok(calls);
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
            let Message::Assistant { calls, status, .. } = &mut s.record.messages[index] else {
                unreachable!()
            };
            match &response {
                Ok(batch) => {
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
        response
    }
    async fn resolve_images(
        &self,
        request: &mut ProviderRequest,
        history: &[Message],
    ) -> Result<()> {
        let reader = self.images.lock().unwrap().clone();
        let mut total_bytes = 0usize;
        for (index, id) in request.message_ids.iter().enumerate() {
            let refs = match history.iter().find(|m| m.id() == id) {
                Some(Message::User { images, .. }) => images.clone(),
                Some(Message::Tool {
                    outcome: ToolOutcome::Completed,
                    details: Some(ToolDetails::Image { image, .. }),
                    ..
                }) => vec![image.clone()],
                _ => vec![],
            };
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
                inputs.push(reader.load(&image).await?);
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
                        let workspace = self.state().record.workspace.clone();
                        let model = self.state().record.model.clone();
                        let search_model = self.state().record.configuration.as_ref().unwrap().settings.search_model.clone();
                        let operation_id=self.state().record.operation.as_ref().unwrap().id.clone();
                        let prepared = tool.prepare(call.arguments.clone(),ToolContext{conversation_id:self.id.clone(),operation_id,search_model,call_id:call.id.clone(),model,workspace,cancel:cancel.clone()}).await?;
                        check_cancel(cancel)?;
                        let auto_approve = self.state().record.configuration.as_ref().unwrap().settings.auto_approve;
                        let asks_approval = !auto_approve && prepared.approval().is_some();
                        let approved = if let Some(description) = prepared.approval().filter(|_| !auto_approve) { self.ask(call,description.into(),prepared.details(),cancel).await? } else { true };
                        check_cancel(cancel)?;
                        if !approved { return Ok((ToolOutcome::Denied,"User denied this action. Nothing was executed. Do not retry without a new user request.".into())); }
                        if asks_approval { prepared.approval_granted()?; }
                        {
                            let resources = prepared.resources(); let mut s = self.state();
                            let mut ids: HashSet<_> = s.record.resources.iter().map(|r|r.id.clone()).collect();
                            if s.record.resources.len()+resources.len()>4096 || resources.iter().any(|r|!valid_id(&r.id)||r.call_id!=call.id||!ids.insert(r.id.clone())) { return Err(Error::Internal); }
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
                        let result = result.unwrap_or(Err(Error::Internal))?; check_cancel(cancel)?;
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
                            self.state().record.executing_tool_id = None;
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
