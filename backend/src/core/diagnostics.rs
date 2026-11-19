//! Content-free, session-owned troubleshooting records. Never serialize error text,
//! provider payloads, instructions, tool arguments, or account information here.
use crate::{Error, ProviderFailure};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionDiagnostic {
    pub timestamp_ms: u64,
    pub conversation_id: String,
    pub operation_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    pub event: DiagnosticEvent,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure: Option<DiagnosticFailure>,
}
impl SessionDiagnostic {
    pub fn new(
        conversation_id: String,
        operation_id: String,
        message_id: Option<String>,
        event: DiagnosticEvent,
        error: Option<&Error>,
    ) -> Self {
        Self {
            timestamp_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64,
            conversation_id,
            operation_id,
            message_id,
            event,
            failure: error.map(DiagnosticFailure::from),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticEvent {
    OperationStarted,
    OperationCompleted,
    OperationFailed,
    OperationInterrupted,
    ResponseStarted,
    ResponseCompleted,
    ResponseFailed,
    ResponseInterrupted,
    CompactionStarted,
    CompactionCompleted,
    CompactionFailed,
    CompactionInterrupted,
}

/// An allowlist rather than Display/Debug output, which may contain tool or user text.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "category", rename_all = "snake_case")]
pub enum DiagnosticFailure {
    Cancelled,
    Busy,
    WorkspaceLocked,
    Storage,
    Internal,
    Invalid,
    Tool,
    Provider { reason: ProviderFailure },
    Api { status: u16 },
}
impl From<&Error> for DiagnosticFailure {
    fn from(error: &Error) -> Self {
        match error {
            Error::Cancelled => Self::Cancelled,
            Error::Busy => Self::Busy,
            Error::WorkspaceLocked => Self::WorkspaceLocked,
            Error::Storage => Self::Storage,
            Error::Internal => Self::Internal,
            Error::Invalid(_) => Self::Invalid,
            Error::Tool(_) => Self::Tool,
            Error::Provider(reason) => Self::Provider { reason: *reason },
            Error::Api(status) => Self::Api { status: *status },
        }
    }
}
