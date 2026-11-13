use super::*;
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::{HashSet, VecDeque};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConversationRecord {
    pub version: u32,
    #[serde(default)]
    pub configuration: Option<ConversationConfiguration>,
    pub id: String,
    pub model: String,
    pub workspace: String,
    pub max_steps: usize,
    pub messages: Vec<Message>,
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
    pub fn validate(&self) -> Result<()> {
        let bad = Error::Invalid("Invalid or unsupported conversation record.");
        if !matches!(self.version, 1 | 2)
            || (self.version == 2 && self.configuration.is_none())
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
        for (index, message) in self.messages.iter().enumerate() {
            if !valid_id(message.id()) || !ids.insert(message.id()) {
                return Err(bad);
            }
            match message {
                Message::User { .. } => {
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
                        || (*status != MessageStatus::Completed && !batch.is_empty())
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
                Message::Tool { call_id, .. } => {
                    if pending.pop_front() != Some(call_id.as_str()) {
                        return Err(bad);
                    }
                }
            }
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
        if let Some(op) = &mut self.operation
            && op.state.active()
        {
            for message in &mut self.messages {
                if let Message::Assistant { status, .. } = message
                    && *status == MessageStatus::Streaming
                {
                    *status = MessageStatus::Interrupted;
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
        messages.push(Message::Tool{id:new_id(),call_id,text: if uncertain {
            "Execution was interrupted before a durable result was recorded; it may have had effects. Do not retry without a new user request."
        } else { "Not executed: operation interrupted before this action started. Do not retry without a new user request." }.into(),
            outcome:if uncertain {ToolOutcome::Interrupted} else {ToolOutcome::NotExecuted}});
    }
}
