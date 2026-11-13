//! Provider-neutral agent runtime and private local service. No automatic retries.
#![cfg(unix)]
pub mod client;
pub mod content_fetch;
pub mod core;
pub mod manager;
pub mod providers;
pub mod service;
pub mod shell_logs;
pub mod storage;
pub mod terminal;
pub mod tools;
mod workspace_instructions;

use std::fmt;
pub type Result<T> = std::result::Result<T, Error>;

/// Only explicitly safe diagnostics cross runtime and transport boundaries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Cancelled,
    Busy,
    Storage,
    Internal,
    Invalid(&'static str),
    Tool(String),
    Provider(ProviderFailure),
    Api(u16),
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderFailure {
    Authentication,
    Quota,
    RateLimit,
    Request,
    Timeout,
    Transport,
    Response,
    Unsupported,
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            Self::Cancelled => "Operation interrupted.",
            Self::Busy => {
                "Conversation is busy. Wait for execution or configuration changes to settle."
            }
            Self::Storage => {
                "Could not save conversation. Work stopped; prior actions may have had effects. Reload the last durable checkpoint before continuing."
            }
            Self::Internal => "Operation failed. Inspect conversation state before continuing.",
            Self::Invalid(text) => text,
            Self::Tool(text) => text,
            Self::Api(status) => {
                return write!(
                    f,
                    "Service rejected request (HTTP {status}). Inspect conversation state before continuing."
                );
            }
            Self::Provider(code) => match code {
                ProviderFailure::Authentication => {
                    "Provider authentication failed. Check the configured credential. No retry was made."
                }
                ProviderFailure::Quota => {
                    "Provider balance or quota is insufficient. No retry was made."
                }
                ProviderFailure::RateLimit => "Provider rate limit reached. No retry was made.",
                ProviderFailure::Request => {
                    "Provider request was rejected. Check the model and input configuration. No retry was made."
                }
                ProviderFailure::Timeout => {
                    "Provider request timed out; it may have been processed. No retry was made."
                }
                ProviderFailure::Transport => {
                    "Provider connection failed; the request may have been processed. No retry was made."
                }
                ProviderFailure::Response => {
                    "Provider returned an invalid or incomplete response. No retry was made."
                }
                ProviderFailure::Unsupported => {
                    "The provider returned an unsupported response mode. No retry was made."
                }
            },
        };
        f.write_str(text)
    }
}
impl std::error::Error for Error {}
impl From<std::io::Error> for Error {
    fn from(_: std::io::Error) -> Self {
        Self::Internal
    }
}
impl From<serde_json::Error> for Error {
    fn from(_: serde_json::Error) -> Self {
        Self::Internal
    }
}
pub(crate) fn check_cancel(token: &tokio_util::sync::CancellationToken) -> Result<()> {
    if token.is_cancelled() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}
