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
    pub settings: SessionSettings,
    pub checkpoint: Option<Arc<dyn Checkpoint>>,
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
            max_steps: 32,
            settings: SessionSettings::default(),
            checkpoint: None,
        }
    }
}
struct Active {
    cancel: CancellationToken,
    finishing: bool,
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
    fn snapshot(&self) -> ConversationSnapshot {
        ConversationSnapshot {
            id: self.record.id.clone(),
            configuration: self
                .record
                .configuration
                .clone()
                .expect("validated configuration"),
            model: self.record.model.clone(),
            workspace: self.record.workspace.clone(),
            messages: self.record.messages.clone(),
            pending_input: self.record.pending_input.clone(),
            metadata: self.record.metadata.clone(),
            usage: self.record.usage.clone(),
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
    events: EventHub,
    input_arrived: Notify,
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
                version: 5,
                resources: vec![],
                provider_state: None,
                usage: None,
                metadata: SessionMetadata {
                    activity_at: SessionMetadata::activity(),
                    ..SessionMetadata::default()
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
            events,
            input_arrived: Notify::new(),
        }))
    }
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().expect("conversation state lock poisoned")
    }
    pub fn snapshot(&self) -> ConversationSnapshot {
        self.state().snapshot()
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
    pub(crate) async fn mutate_record(
        self: &Arc<Self>,
        mutate: impl FnOnce(&mut ConversationRecord) -> Result<()>,
    ) -> Result<ConversationSnapshot> {
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
        tokio::spawn(async move {
            let saved = AssertUnwindSafe(async {
                if let Some(persist) = &conversation.persist {
                    persist.save(record.clone()).await?;
                }
                Ok::<_, Error>(())
            })
            .catch_unwind()
            .await
            .unwrap_or(Err(Error::Internal));
            let mut state = conversation.state();
            state.updating = false;
            if saved.is_ok() {
                state.record = record;
            } else {
                state.storage_error = Some(Error::Storage.to_string());
            }
            let snapshot = state.snapshot();
            conversation.events.send(Arc::new(ServiceEvent::Snapshot {
                snapshot: snapshot.clone(),
            }));
            saved.map_err(|_| Error::Storage)?;
            Ok(snapshot)
        })
        .await
        .map_err(|_| Error::Internal)?
    }
    /// Subscription and initial snapshot are taken under the same lock as events.
    /// Lagging observers must reconnect explicitly; they can never block execution.
    pub fn subscribe(&self) -> (ConversationSnapshot, EventReceiver) {
        let s = self.state();
        let receiver = self.events.subscribe();
        (s.snapshot(), receiver)
    }
    fn emit(&self, s: &State, kind: EventKind) {
        let Some(op) = &s.record.operation else {
            return;
        };
        let snapshot = if matches!(kind, EventKind::Text { .. }) {
            None
        } else {
            Some(s.snapshot())
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
        if state.active.is_some() || state.updating || !state.record.pending_input.is_empty() {
            return Err(Error::Busy);
        }
        if state.storage_error.is_some() {
            return Err(Error::Storage);
        }
        if state.disposed {
            return Err(Error::Invalid("Conversation is closed."));
        }
        let mut record = state.record.clone();
        record.id = new_id();
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
        if !valid_input(&text) {
            return Err(Error::Invalid("Message must not be empty."));
        }
        if let Some(value) = &instructions {
            validate_instructions(value)?;
        }
        let config = s.record.configuration.as_mut().unwrap();
        if !config.instructions_frozen {
            config.workspace_instructions = instructions;
            config.instructions_frozen = true;
        }
        s.record.metadata.activity_at = SessionMetadata::activity();
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
        });
        s.record.operation = Some(Operation {
            id: operation_id.clone(),
            state: OperationState::Running,
            error: None,
        });
        let pending = std::mem::take(&mut s.record.pending_input);
        s.record.messages.extend(pending);
        s.record.messages.push(Message::User { id: new_id(), text });
        let runner = self.clone();
        let (settled, completion) = oneshot::channel();
        tokio::spawn(async move {
            tokio::task::yield_now().await;
            let operation = runner.run(cancel).await;
            let _ = settled.send(operation);
        });
        Ok(Submission {
            operation_id,
            completion,
        })
    }
    /// In-memory acceptance, like submit. The runner checkpoints pending input;
    /// no client-side queue or competing execution loop is involved.
    pub fn steer(&self, operation_id: &str, text: String) -> Result<String> {
        if !valid_input(&text) {
            return Err(Error::Invalid("Invalid steering input."));
        }
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
        if s.record.pending_input.len() >= 32 {
            return Err(Error::Busy);
        }
        let id = new_id();
        s.record.metadata.activity_at = SessionMetadata::activity();
        s.record.pending_input.push(Message::User {
            id: id.clone(),
            text,
        });
        if s.pending.take().is_some() {
            // Dropping the one-shot withdraws the exact old approval, never grants it.
            self.emit(&s, EventKind::Approval { approval_id: None });
        }
        self.emit(
            &s,
            EventKind::Input {
                message_id: id.clone(),
            },
        );
        self.input_arrived.notify_one();
        Ok(id)
    }
    fn has_pending_input(&self) -> bool {
        !self.state().record.pending_input.is_empty()
    }
    fn inject_pending_input(&self) -> bool {
        let mut s = self.state();
        let pending = std::mem::take(&mut s.record.pending_input);
        let changed = !pending.is_empty();
        for message in pending {
            s.record.messages.push(message);
            self.changed(&s, s.record.messages.len() - 1);
        }
        changed
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
    async fn checkpoint(&self, terminal: Option<OperationState>) -> Result<()> {
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
        Ok(())
    }
    async fn run(&self, cancel: CancellationToken) -> Operation {
        let result = AssertUnwindSafe(self.steps(&cancel))
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
            let intent = s.record.executing_tool_id.take();
            finish_missing_results(&mut s.record.messages, intent.as_deref());
            s.active_tool = None;
            s.pending = None;
            s.active.as_mut().unwrap().finishing = true;
            for index in previous..s.record.messages.len() {
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
        let max_steps = self.state().record.max_steps;
        for _ in 0..max_steps {
            check_cancel(cancel)?;
            self.inject_pending_input();
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
        let (request, index, mut known) = {
            let mut s = self.state();
            s.record.usage = None;
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
                    tools: self.definitions.clone(),
                    cancel: cancel.clone(),
                },
                index,
                known,
            )
        };
        let response: Result<Vec<ToolCall>> = async {
            self.checkpoint(None).await?;
            check_cancel(cancel)?;
            let mut stream = self.provider.stream(request);
            let mut calls = vec![];
            let mut metadata = None;
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
                        if let Some((state, usage)) = metadata {
                            let mut s = self.state();
                            s.record.provider_state = state;
                            s.record.usage = usage;
                        }
                        return Ok(calls);
                    }
                }
            }
            Err(Error::Internal)
        }
        .await;
        {
            let mut s = self.state();
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
    async fn ask(
        &self,
        call: &ToolCall,
        description: String,
        cancel: &CancellationToken,
    ) -> Result<bool> {
        check_cancel(cancel)?;
        {
            self.state().record.operation.as_mut().unwrap().state =
                OperationState::AwaitingApproval;
        }
        self.checkpoint(None).await?;
        check_cancel(cancel)?;
        let (send, receive) = oneshot::channel();
        {
            let mut s = self.state();
            check_cancel(cancel)?;
            if !s.record.pending_input.is_empty() {
                self.set_state(&mut s, OperationState::Running);
                return Ok(false);
            }
            let approval = Approval {
                id: new_id(),
                operation_id: s.record.operation.as_ref().unwrap().id.clone(),
                call: call.clone(),
                description,
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
        let decision = tokio::select! { biased; _ = cancel.cancelled() => false, value = receive => value.unwrap_or(false) };
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
            let mut text =
                "Not executed: operation interrupted. Do not retry without a new user request."
                    .to_string();
            if self.has_pending_input() {
                text = "Not executed: new user input superseded this action. Reconsider using the new instructions.".into();
            } else if !cancel.is_cancelled() {
                if let Some(tool) = self.tools.get(&call.name) {
                    let mut started = false;
                    let action = AssertUnwindSafe(async {
                        let workspace = self.state().record.workspace.clone();
                        let model = self.state().record.model.clone();
                        let prepared = tool.prepare(call.arguments.clone(),ToolContext{call_id:call.id.clone(),model,workspace,cancel:cancel.clone()}).await?;
                        check_cancel(cancel)?;
                        let auto_approve = self.state().record.configuration.as_ref().unwrap().settings.auto_approve;
                        let approved = if let Some(description) = prepared.approval().filter(|_| !auto_approve) { self.ask(call,description.into(),cancel).await? } else { true };
                        check_cancel(cancel)?;
                        if self.has_pending_input() { return Ok((ToolOutcome::NotExecuted, "Not executed: new user input superseded this action. Reconsider using the new instructions.".into())); }
                        if !approved { return Ok((ToolOutcome::Denied,"User denied this action. Nothing was executed. Do not retry without a new user request.".into())); }
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
                            if !s.record.pending_input.is_empty() {
                                return Ok((ToolOutcome::NotExecuted, "Not executed: new user input superseded this action. Reconsider using the new instructions.".into()));
                            }
                            // Executor ownership is the safe-boundary linearization point.
                            started=true; s.active_tool=Some(call.id.clone());
                        }
                        // Poll once before announcing entry: Rust async functions are lazy.
                        let mut execution = AssertUnwindSafe(prepared.execute()).catch_unwind();
                        let first = futures_util::poll!(&mut execution);
                        { let s=self.state(); self.emit(&s,EventKind::ToolStarted{call_id:call.id.clone()}); }
                        let result = match first {
                            Poll::Ready(result) => result,
                            Poll::Pending => loop {
                                tokio::select! { biased;
                                    _ = self.input_arrived.notified() => {
                                        if self.checkpoint(None).await.is_err() { cancel.cancel(); }
                                        // Never drop an executor to simulate cancellation: keep owning cleanup.
                                    }
                                    result = &mut execution => break result,
                                }
                            }
                        };
                        let result = result.unwrap_or(Err(Error::Internal))?; check_cancel(cancel)?;
                        Ok((ToolOutcome::Completed,result))
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
                s.record.messages.push(Message::Tool {
                    id: new_id(),
                    call_id: call.id.clone(),
                    text,
                    outcome,
                });
                s.record.executing_tool_id = None;
                self.changed(&s, s.record.messages.len() - 1);
            }
            self.checkpoint(None).await?;
        }
        Ok(())
    }
}
