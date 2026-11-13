use super::{AccountBalance, WebSearchResult};
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
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ResourceKind {
    ShellLog,
    Image,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ResourceRef {
    pub id: String,
    #[serde(rename = "callID")]
    pub call_id: String,
    pub kind: ResourceKind,
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
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<super::ImageRef>,
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
        details: Option<ToolDetails>,
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
    /// Stable IDs parallel to completed context messages; never provider wire identifiers.
    pub message_ids: Vec<String>,
    pub images: std::collections::BTreeMap<usize, Vec<super::ImageInput>>,
    pub model: String,
    pub messages: Vec<ContextMessage>,
    pub instructions: String,
    pub effort: Option<String>,
    pub provider_state: Option<Value>,
    pub tools: Vec<ToolDefinition>,
    pub cancel: CancellationToken,
}
#[derive(Debug, Clone, PartialEq)]
pub enum ProviderEvent {
    Text(String),
    TextSnapshot(String),
    ToolCall(ToolCall),
    Metadata {
        state: Option<Value>,
        usage: Option<TokenUsage>,
    },
    Done,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
}
impl TokenUsage {
    pub fn valid(&self) -> bool {
        [self.input_tokens, self.output_tokens, self.total_tokens]
            .into_iter()
            .flatten()
            .all(|n| n <= 1_000_000_000)
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatEffort {
    pub id: String,
    pub name: String,
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
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub efforts: Vec<ChatEffort>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accepts_images: Option<bool>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderConnection {
    pub id: String,
    pub name: String,
    pub connected: bool,
    pub source: String,
    pub manageable: bool,
    pub blocked: bool,
}
#[async_trait]
pub trait ChatProvider: Send + Sync {
    async fn prepare_model(&self, _model: &str, _cancel: CancellationToken) -> Result<()> {
        Ok(())
    }
    async fn accepts_images(&self, _model: &str, _cancel: CancellationToken) -> Result<bool> {
        Ok(false)
    }
    fn supports_image_generation(&self) -> bool {
        false
    }
    fn image_generation_available(&self) -> bool {
        self.supports_image_generation()
            && (self.connections().is_empty() || self.connections().iter().any(|c| c.connected))
    }
    async fn generate_image(
        &self,
        _input: super::ImageGeneration,
        _cancel: CancellationToken,
    ) -> Result<super::GeneratedImage> {
        Err(crate::Error::Provider(crate::ProviderFailure::Unsupported))
    }

    fn metadata_identity(&self, _provider: &str) -> Option<String> {
        None
    }
    async fn connect(
        &self,
        _provider: &str,
        _challenge: tokio::sync::oneshot::Sender<String>,
        _cancel: CancellationToken,
    ) -> Result<()> {
        Err(crate::Error::Provider(crate::ProviderFailure::Unsupported))
    }
    async fn settle(&self) {}
    async fn account_usage(
        &self,
        _provider: &str,
        _cancel: CancellationToken,
    ) -> Result<super::AccountUsage> {
        Err(crate::Error::Provider(crate::ProviderFailure::Unsupported))
    }
    fn context_window(&self, _model: &str) -> Option<u64> {
        None
    }
    fn supports_compaction(&self, _model: &str) -> bool {
        false
    }
    async fn compact(&self, _request: ProviderRequest) -> Result<Value> {
        Err(crate::Error::Provider(crate::ProviderFailure::Unsupported))
    }

    fn metadata_freshness(&self) -> Vec<super::MetadataFreshness> {
        vec![]
    }
    fn model_warnings(&self) -> Vec<String> {
        vec![]
    }
    fn supports_web_search(&self) -> bool {
        false
    }
    async fn search_web(
        &self,
        _model: &str,
        _query: String,
        _cancel: CancellationToken,
    ) -> Result<WebSearchResult> {
        Err(crate::Error::Provider(crate::ProviderFailure::Unsupported))
    }
    async fn account_balances(
        &self,
        _provider: &str,
        _cancel: CancellationToken,
    ) -> Result<Vec<AccountBalance>> {
        Err(crate::Error::Provider(crate::ProviderFailure::Unsupported))
    }
    fn connections(&self) -> Vec<ProviderConnection> {
        vec![]
    }
    async fn set_credential(&self, _provider: &str, _credential: Option<String>) -> Result<()> {
        Err(crate::Error::Invalid(
            "This provider's credentials are externally managed.",
        ))
    }
    /// Implementations must cooperate with cancellation and never retry inference.
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>>;
    async fn models(&self, _cancel: CancellationToken) -> Result<Vec<ChatModel>> {
        Ok(vec![])
    }
}
#[derive(Clone)]
pub struct ToolContext {
    pub conversation_id: String,
    pub operation_id: String,
    pub search_model: Option<String>,
    pub call_id: String,
    pub model: String,
    pub workspace: String,
    pub cancel: CancellationToken,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum ToolDetails {
    Windows {
        windows: Vec<super::WindowInfo>,
    },
    Image {
        image: super::ImageRef,
        origin: String,
    },
    Edit {
        path: String,
        diff: String,
        truncated: bool,
    },
    Search {
        result: super::WebSearchResult,
    },
    Page {
        content: super::FetchedContent,
    },
}
pub struct ToolOutput {
    pub text: String,
    pub details: Option<ToolDetails>,
}
#[async_trait]
pub trait PreparedTool: Send {
    fn details(&self) -> Option<ToolDetails> {
        None
    }
    async fn execute_output(self: Box<Self>) -> Result<ToolOutput> {
        let details = self.details();
        let text = self.execute().await?;
        Ok(ToolOutput { text, details })
    }
    fn resources(&self) -> Vec<ResourceRef> {
        vec![]
    }
    fn approval(&self) -> Option<&str>;
    /// Ownership is consumed so a prepared side effect cannot accidentally run twice.
    async fn execute(self: Box<Self>) -> Result<String>;
}
#[async_trait]
pub trait Tool: Send + Sync {
    fn available(&self, _context: &ToolContext) -> bool {
        true
    }
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
    pub details: Option<ToolDetails>,
    pub workspace: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSnapshot {
    pub id: String,
    pub configuration: super::ConversationConfiguration,
    pub pending_input: Vec<Message>,
    pub metadata: super::SessionMetadata,
    pub usage: Option<TokenUsage>,
    pub context_usage: Option<super::ContextUsage>,
    pub resources: Vec<ResourceRef>,
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
    Input {
        #[serde(rename = "messageID")]
        message_id: String,
    },
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
