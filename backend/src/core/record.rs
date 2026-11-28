use super::*;
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::{HashSet, VecDeque};

/// Append-only runtime policy at a safe request boundary, not a UI message.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ToolAvailability {
    pub id: String,
    pub after_message_id: String,
    /// Sorted effective tool names, including both selection and capability checks.
    pub enabled: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConversationRecord {
    pub version: u32,
    #[serde(default)]
    pub metadata: SessionMetadata,
    #[serde(default)]
    pub provider_state: Option<serde_json::Value>,
    #[serde(default)]
    pub usage: Option<TokenUsage>,
    #[serde(default)]
    pub resources: Vec<ResourceRef>,
    /// Cleared assets retain cleanup ownership without remaining usable attachments.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cleanup_resources: Vec<ResourceRef>,
    #[serde(default)]
    pub configuration: Option<ConversationConfiguration>,
    pub id: String,
    pub model: String,
    pub workspace: String,
    pub max_steps: usize,
    pub messages: Vec<Message>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_availability: Vec<ToolAvailability>,
    #[serde(default)]
    pub pending_input: Vec<Message>,
    #[serde(deserialize_with = "required_option")]
    pub operation: Option<Operation>,
    #[serde(rename = "executingToolID", deserialize_with = "required_option")]
    pub executing_tool_id: Option<String>,
}
// Nullable is not optional in the versioned disk schema. Missing fields indicate
// an incomplete record and must not silently become valid recovered state.
pub(super) fn required_option<'de, T: Deserialize<'de>, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<T>, D::Error> {
    Option::deserialize(deserializer)
}
impl ConversationRecord {
    /// Called only when preparing a model request, before its durable checkpoint.
    pub(super) fn update_tool_availability(&mut self, end: usize, enabled: Vec<String>) {
        if self
            .tool_availability
            .last()
            .is_some_and(|last| last.enabled == enabled)
        {
            return;
        }
        let after_message_id = self.messages[..end]
            .iter()
            .rev()
            .find(|m| m.in_context())
            .expect("model requests have history")
            .id()
            .to_owned();
        self.tool_availability.push(ToolAvailability {
            id: new_id(),
            after_message_id,
            enabled,
        });
        self.version = self.version.max(11);
    }

    /// Merge invisible runtime policy with transcript context, keeping IDs and image
    /// indices aligned. Anchors never split a tool-call/result batch.
    pub(super) fn provider_context(&self, end: usize) -> (Vec<ContextMessage>, Vec<String>) {
        let history = &self.messages[..end];
        let mut updates = self.tool_availability.iter().peekable();
        let mut messages = Vec::new();
        let mut ids = Vec::new();
        for (message, item) in history
            .iter()
            .filter(|m| m.in_context())
            .zip(context(history))
        {
            messages.push(item);
            ids.push(message.id().to_owned());
            while updates
                .peek()
                .is_some_and(|update| update.after_message_id == message.id())
            {
                let update = updates.next().unwrap();
                messages.push(ContextMessage::ToolAvailability {
                    enabled: update.enabled.clone(),
                });
                ids.push(update.id.clone());
            }
        }
        (messages, ids)
    }

    /// Any accepted input or operation permanently binds its workspace, including
    /// failed/interrupted turns and legacy records with frozen instructions.
    pub(crate) fn workspace_locked(&self) -> bool {
        self.configuration
            .as_ref()
            .is_some_and(|config| config.instructions_frozen)
            || !self.messages.is_empty()
            || !self.pending_input.is_empty()
            || self.operation.is_some()
    }

    pub fn validate(&self) -> Result<()> {
        self.metadata.validate()?;
        if self.usage.as_ref().is_some_and(|usage| !usage.valid()) {
            return Err(Error::Invalid("Invalid usage measurement."));
        }
        if self.provider_state.as_ref().is_some_and(|state| {
            !valid_json_depth(state, 0)
                || serde_json::to_vec(state).map_or(true, |bytes| bytes.len() > 8 * 1024 * 1024)
        }) {
            return Err(Error::Invalid("Invalid provider state."));
        }
        let bad = Error::Invalid("Invalid or unsupported conversation record.");
        if !matches!(self.version, 1..=12)
            || (self.version < 12 && !self.cleanup_resources.is_empty())
            || (self.version < 11 && !self.tool_availability.is_empty())
            || self
                .metadata
                .parent
                .as_ref()
                .is_some_and(|p| self.version < 9 || p.session_id == self.id)
            || (self.version >= 2 && self.configuration.is_none())
            || (self.version == 1 && self.configuration.is_some())
            || !valid_id(&self.id)
            || self.model.trim().is_empty()
            || self.workspace.trim().is_empty()
            || self.max_steps == 0
            || self.max_steps > 9_007_199_254_740_991
        {
            return Err(bad);
        }
        if let Some(configuration) = &self.configuration {
            configuration.validate()?;
            if !self.messages.is_empty() && !configuration.instructions_frozen {
                return Err(bad);
            }
        }
        if self.operation.as_ref().is_some_and(|op| !valid_id(&op.id)) {
            return Err(bad);
        }
        let active = self.operation.as_ref().is_some_and(|o| o.state.active());
        let mut ids = HashSet::new();
        let mut calls = HashSet::new();
        let mut pending = VecDeque::new();
        let mut availability = self.tool_availability.iter().peekable();
        for (index, message) in self.messages.iter().enumerate() {
            if !valid_id(message.id()) || !ids.insert(message.id()) {
                return Err(bad);
            }
            match message {
                Message::User { images, files, .. } => {
                    if (self.version < 8 && !files.is_empty())
                        || validate_message_files(files).is_err()
                        || files.iter().any(|f| {
                            !self
                                .resources
                                .iter()
                                .any(|r| r.id == f.id && r.kind == ResourceKind::File)
                        })
                    {
                        return Err(bad);
                    }
                    if images.len() > 8
                        || images.iter().any(|i| i.validate().is_err())
                        || images.iter().map(|i| i.byte_count).sum::<usize>() > 16 * 1024 * 1024
                        || images.iter().any(|i| {
                            !self
                                .resources
                                .iter()
                                .any(|r| r.id == i.id && r.kind == ResourceKind::Image)
                        })
                    {
                        return Err(bad);
                    }
                    if !pending.is_empty() {
                        return Err(bad);
                    }
                }
                Message::Assistant {
                    calls: batch,
                    status,
                    ..
                } => {
                    if index == 0
                        || !pending.is_empty()
                        || batch.len() > 64
                        || (*status != MessageStatus::Completed
                            && !batch.is_empty()
                            && !(message.is_compaction() && *status == MessageStatus::Streaming))
                    {
                        return Err(bad);
                    }
                    if *status == MessageStatus::Streaming
                        && (index + 1 != self.messages.len() || !active)
                    {
                        return Err(bad);
                    }
                    for call in batch {
                        if call.id.trim().is_empty()
                            || call.name.trim().is_empty()
                            || !calls.insert(call.id.as_str())
                            || !valid_json_depth(
                                &serde_json::Value::Object(call.arguments.clone()),
                                0,
                            )
                        {
                            return Err(bad);
                        }
                        pending.push_back(call.id.as_str());
                    }
                }
                Message::Tool {
                    call_id,
                    outcome,
                    details,
                    ..
                } => {
                    if let Some(ToolDetails::Windows { windows }) = details {
                        let mut ids = HashSet::new();
                        if windows.len() > 256
                            || windows.iter().any(|w| {
                                w.id == 0
                                    || w.title.len() > 1024
                                    || w.title.contains('\0')
                                    || !ids.insert(w.id)
                            })
                        {
                            return Err(bad);
                        }
                    }
                    if let Some(ToolDetails::Image { image, origin }) = details {
                        if !["generated", "screenshot"].contains(&origin.as_str()) {
                            return Err(bad);
                        }
                        image.validate()?;
                        if !self.resources.iter().any(|r| {
                            r.id == image.id
                                && r.kind == ResourceKind::Image
                                && r.call_id == *call_id
                        }) {
                            return Err(bad);
                        }
                    }
                    let delegation =
                        if let Some(ToolDetails::Delegation { total, results }) = details {
                            let mut children = HashSet::new();
                            if self.version < 10
                                || !(1..=8).contains(total)
                                || results.is_empty()
                                || results.len() > *total
                                || message.text().len() > MAX_DELEGATION_OUTPUT_BYTES
                                || results.iter().map(|r| r.text.len()).sum::<usize>()
                                    + 2 * (results.len() - 1)
                                    > DELEGATION_RESULT_BYTES
                                || results
                                    .windows(2)
                                    .any(|pair| pair[0].task_index >= pair[1].task_index)
                                || results.iter().any(|r| {
                                    r.task_index >= *total
                                        || !valid_id(&r.session_id)
                                        || !children.insert(&r.session_id)
                                        || !matches!(
                                            r.outcome,
                                            ToolOutcome::Completed
                                                | ToolOutcome::Failed
                                                | ToolOutcome::Interrupted
                                        )
                                })
                                || (*outcome == ToolOutcome::Completed && results.len() != *total)
                                || !self.messages.iter().any(|m| {
                                    matches!(m, Message::Assistant { calls, .. }
                                if calls.iter().any(|c| c.id == *call_id && c.name == "delegate"))
                                })
                            {
                                return Err(bad);
                            }
                            true
                        } else {
                            false
                        };
                    if details.is_some() && *outcome != ToolOutcome::Completed && !delegation {
                        return Err(bad);
                    }
                    if *outcome == ToolOutcome::Running {
                        if !delegation
                            || !active
                            || index + 1 != self.messages.len()
                            || self.executing_tool_id.as_ref() != Some(call_id)
                            || pending.front().copied() != Some(call_id.as_str())
                        {
                            return Err(bad);
                        }
                    } else if pending.pop_front() != Some(call_id.as_str()) {
                        return Err(bad);
                    }
                }
            }
            while availability
                .peek()
                .is_some_and(|update| update.after_message_id == message.id())
            {
                let update = availability.next().unwrap();
                if !message.in_context()
                    || !pending.is_empty()
                    || !valid_id(&update.id)
                    || !ids.insert(&update.id)
                    || update.enabled.iter().any(String::is_empty)
                    || update.enabled.windows(2).any(|pair| pair[0] >= pair[1])
                {
                    return Err(bad);
                }
            }
        }
        // Also rejects dangling/out-of-order anchors after restore or fork.
        if availability.next().is_some() {
            return Err(bad);
        }
        if (self.version < 3 && !self.pending_input.is_empty()) || self.pending_input.len() > 32 {
            return Err(bad);
        }
        for message in &self.pending_input {
            if !matches!(message, Message::User { text, images, files, .. }
                if validate_message_input(text, images, files).is_ok()
                    && (self.version >= 8 || files.is_empty())
                    && files.iter().all(|f| self.resources.iter().any(|r| r.id == f.id && r.kind == ResourceKind::File))
                    && images.iter().all(|image| self.resources.iter().any(|r| r.id == image.id && r.kind == ResourceKind::Image)))
                || !valid_id(message.id())
                || !ids.insert(message.id())
            {
                return Err(bad);
            }
        }
        let mut resources = HashSet::new();
        if self.resources.len() + self.cleanup_resources.len() > 4096
            || self
                .cleanup_resources
                .iter()
                .any(|r| !valid_id(&r.id) || !r.call_id.is_empty() || !resources.insert(&r.id))
            || self.resources.iter().any(|r| {
                !valid_id(&r.id)
                    || !(calls.contains(r.call_id.as_str())
                        || (matches!(r.kind, ResourceKind::Image | ResourceKind::File)
                            && r.call_id.is_empty()))
                    || !resources.insert(&r.id)
            })
        {
            return Err(bad);
        }
        if !self.pending_input.is_empty() && self.operation.is_none() {
            return Err(bad);
        }
        if !self.messages.is_empty()
            && (self.operation.is_none()
                || !matches!(self.messages.first(), Some(Message::User { .. })))
        {
            return Err(bad);
        }
        if !pending.is_empty() && !active {
            return Err(bad);
        }
        if let Some(id) = &self.executing_tool_id
            && (pending.front().copied() != Some(id.as_str())
                || !self.operation.as_ref().is_some_and(|o| {
                    matches!(
                        o.state,
                        OperationState::Running | OperationState::Cancelling
                    )
                }))
        {
            return Err(bad);
        }
        Ok(())
    }
    pub fn recover(mut self) -> Result<Self> {
        self.validate()?;
        if self.version == 1 {
            self.version = 2;
            self.configuration = Some(ConversationConfiguration::legacy());
        }
        self.version = self.version.max(9);
        if let Some(op) = &mut self.operation
            && op.state.active()
        {
            for message in &mut self.messages {
                let compaction = message.is_compaction();
                if let Message::Assistant { status, .. } = message
                    && *status == MessageStatus::Streaming
                {
                    *status = if compaction {
                        MessageStatus::Completed
                    } else {
                        MessageStatus::Interrupted
                    };
                }
            }
            finish_missing_results(&mut self.messages, self.executing_tool_id.as_deref());
            self.executing_tool_id = None;
            op.state = OperationState::Interrupted;
            op.error = Some(
                "Service restarted before the operation finished. No work was resumed.".into(),
            );
        }
        Ok(self)
    }
}
pub fn valid_json_depth(value: &serde_json::Value, depth: usize) -> bool {
    depth <= 64
        && match value {
            serde_json::Value::Array(a) => a.iter().all(|v| valid_json_depth(v, depth + 1)),
            serde_json::Value::Object(a) => a.values().all(|v| valid_json_depth(v, depth + 1)),
            _ => true,
        }
}
pub fn finish_missing_results(messages: &mut Vec<Message>, intent: Option<&str>) {
    for message in messages.iter_mut() {
        if let Message::Tool { text, outcome, .. } = message
            && *outcome == ToolOutcome::Running
        {
            *outcome = ToolOutcome::Interrupted;
            append_delegation_notice(
                text,
                "Delegation interrupted before all results were returned.",
            );
        }
    }
    let results: HashSet<_> = messages
        .iter()
        .filter_map(|m| {
            if let Message::Tool { call_id, .. } = m {
                Some(call_id.clone())
            } else {
                None
            }
        })
        .collect();
    let missing: Vec<_> = messages
        .iter()
        .flat_map(|m| match m {
            Message::Assistant {
                calls,
                status: MessageStatus::Completed,
                ..
            } => calls.as_slice(),
            _ => &[],
        })
        .filter(|c| !results.contains(&c.id))
        .map(|c| c.id.clone())
        .collect();
    for call_id in missing {
        let uncertain = intent == Some(call_id.as_str());
        messages.push(Message::Tool{id:new_id(),call_id,details:None,text: if uncertain {
            "Execution was interrupted before a durable result was recorded; it may have had effects."
        } else { "Not executed: operation interrupted before this action started." }.into(),
            outcome:if uncertain {ToolOutcome::Interrupted} else {ToolOutcome::NotExecuted}});
    }
}
