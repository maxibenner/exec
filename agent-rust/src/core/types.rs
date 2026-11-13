use crate::Result;
use async_trait::async_trait;
use futures_util::stream::BoxStream;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tokio_util::sync::CancellationToken;

pub type Arguments = Map<String, Value>;
pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
pub fn valid_id(id: &str) -> bool {
    id.len() == 36
        && uuid::Uuid::parse_str(id).is_ok()
        && [8, 13, 18, 23].iter().all(|&i| id.as_bytes()[i] == b'-')
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Arguments,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters: Arguments,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ToolOutcome {
    Completed,
    Denied,
    Failed,
    Interrupted,
    NotExecuted,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MessageStatus {
    Streaming,
    Completed,
    Failed,
    Interrupted,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "role", rename_all = "snake_case")]
pub enum Message {
    User {
        id: String,
        text: String,
    },
    Assistant {
        id: String,
        text: String,
        calls: Vec<ToolCall>,
        status: MessageStatus,
    },
    Tool {
        id: String,
        #[serde(rename = "callID")]
        call_id: String,
        text: String,
        outcome: ToolOutcome,
    },
}
impl Message {
    pub fn id(&self) -> &str {
        match self {
            Self::User { id, .. } | Self::Assistant { id, .. } | Self::Tool { id, .. } => id,
        }
    }
    pub fn text(&self) -> &str {
        match self {
            Self::User { text, .. } | Self::Assistant { text, .. } | Self::Tool { text, .. } => {
                text
            }
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "role", rename_all = "snake_case")]
pub enum ContextMessage {
    User {
        text: String,
    },
    Assistant {
        text: String,
        calls: Vec<ToolCall>,
    },
    Tool {
        #[serde(rename = "callID")]
        call_id: String,
        text: String,
        outcome: ToolOutcome,
    },
}
pub fn context(messages: &[Message]) -> Vec<ContextMessage> {
    messages
        .iter()
        .filter_map(|m| match m {
            Message::User { text, .. } => Some(ContextMessage::User { text: text.clone() }),
            Message::Assistant {
                text,
                calls,
                status: MessageStatus::Completed,
                ..
            } => Some(ContextMessage::Assistant {
                text: text.clone(),
                calls: calls.clone(),
            }),
            Message::Tool {
                call_id,
                text,
                outcome,
                ..
            } => Some(ContextMessage::Tool {
                call_id: call_id.clone(),
                text: text.clone(),
                outcome: *outcome,
            }),
            _ => None,
        })
        .collect()
}
#[derive(Clone)]
pub struct ProviderRequest {
    pub model: String,
    pub messages: Vec<ContextMessage>,
    pub tools: Vec<ToolDefinition>,
    pub cancel: CancellationToken,
}
#[derive(Debug, Clone, PartialEq)]
pub enum ProviderEvent {
    Text(String),
    ToolCall(ToolCall),
    Done,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChatModel {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u64>,
}
#[async_trait]
pub trait ChatProvider: Send + Sync {
    /// Implementations must cooperate with cancellation and never retry inference.
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>>;
    async fn models(&self, _cancel: CancellationToken) -> Result<Vec<ChatModel>> {
        Ok(vec![])
    }
}
#[derive(Clone)]
pub struct ToolContext {
    pub workspace: String,
    pub cancel: CancellationToken,
}
#[async_trait]
pub trait PreparedTool: Send {
    fn approval(&self) -> Option<&str>;
    /// Ownership is consumed so a prepared side effect cannot accidentally run twice.
    async fn execute(self: Box<Self>) -> Result<String>;
}
#[async_trait]
pub trait Tool: Send + Sync {
    fn definition(&self) -> ToolDefinition;
    async fn prepare(
        &self,
        arguments: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>>;
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OperationState {
    Running,
    AwaitingApproval,
    Cancelling,
    Completed,
    Failed,
    Interrupted,
}
impl OperationState {
    pub fn active(self) -> bool {
        matches!(
            self,
            Self::Running | Self::AwaitingApproval | Self::Cancelling
        )
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Operation {
    pub id: String,
    pub state: OperationState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Approval {
    pub id: String,
    #[serde(rename = "operationID")]
    pub operation_id: String,
    pub call: ToolCall,
    pub description: String,
    pub workspace: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSnapshot {
    pub id: String,
    pub model: String,
    pub workspace: String,
    pub messages: Vec<Message>,
    pub operation: Option<Operation>,
    pub approval: Option<Approval>,
    #[serde(rename = "activeToolCallID")]
    pub active_tool_call_id: Option<String>,
    pub storage_error: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RuntimeEvent {
    #[serde(rename = "conversationID")]
    pub conversation_id: String,
    #[serde(rename = "operationID")]
    pub operation_id: String,
    #[serde(flatten)]
    pub kind: EventKind,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EventKind {
    Operation {
        state: OperationState,
    },
    Message {
        #[serde(rename = "messageID")]
        message_id: String,
    },
    Text {
        #[serde(rename = "messageID")]
        message_id: String,
        delta: String,
    },
    Approval {
        #[serde(rename = "approvalID")]
        approval_id: Option<String>,
    },
    ToolStarted {
        #[serde(rename = "callID")]
        call_id: String,
    },
    ToolFinished {
        #[serde(rename = "callID")]
        call_id: String,
        #[serde(rename = "messageID")]
        message_id: String,
        outcome: ToolOutcome,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServiceEvent {
    Snapshot {
        snapshot: ConversationSnapshot,
    },
    Runtime {
        event: RuntimeEvent,
        #[serde(skip_serializing_if = "Option::is_none")]
        snapshot: Option<ConversationSnapshot>,
    },
}
