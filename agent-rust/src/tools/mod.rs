mod fetch;
mod files;
pub use fetch::{create_fetch_tool, create_fetch_tool_with};
mod provider_search;
mod shell;
mod workspace;
use crate::{Error, Result, core::*};
use async_trait::async_trait;
pub use files::create_file_tools;
use futures_util::future::BoxFuture;
pub use provider_search::create_provider_tools;
pub use shell::{create_logged_shell_tool, create_shell_tool};
use std::sync::Arc;
pub use workspace::revision;

pub fn create_workspace_tools() -> Vec<Arc<dyn Tool>> {
    let mut tools = create_file_tools();
    tools.push(create_shell_tool());
    tools
}
struct Action {
    resources: Vec<ResourceRef>,
    approval: Option<String>,
    execute: Box<dyn FnOnce() -> BoxFuture<'static, Result<String>> + Send>,
}
#[async_trait]
impl PreparedTool for Action {
    fn resources(&self) -> Vec<ResourceRef> {
        self.resources.clone()
    }
    fn approval(&self) -> Option<&str> {
        self.approval.as_deref()
    }
    async fn execute(self: Box<Self>) -> Result<String> {
        (self.execute)().await
    }
}
fn failure(text: impl Into<String>) -> Error {
    Error::Tool(text.into())
}
fn fields(args: &Arguments, allowed: &[&str]) -> Result<()> {
    if args.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err(failure("Unexpected tool argument."));
    }
    Ok(())
}
fn string(args: &Arguments, key: &str, limit: usize) -> Result<String> {
    args.get(key)
        .and_then(|v| v.as_str())
        .filter(|s| !s.contains('\0') && s.len() <= limit)
        .map(str::to_owned)
        .ok_or_else(|| {
            failure(format!(
                "{key} must be a string without NUL bytes, at most {limit} UTF-8 bytes."
            ))
        })
}
fn integer(args: &Arguments, key: &str, min: u64, max: u64, fallback: Option<u64>) -> Result<u64> {
    let value = match args.get(key) {
        None => fallback,
        Some(v) => v.as_u64(),
    };
    value
        .filter(|&v| v >= min && v <= max)
        .ok_or_else(|| failure(format!("{key} must be an integer between {min} and {max}.")))
}
fn schema(properties: serde_json::Value, required: &[&str]) -> Arguments {
    serde_json::json!({"type":"object","properties":properties,"required":required,"additionalProperties":false}).as_object().unwrap().clone()
}
async fn blocking<T: Send + 'static>(
    action: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    tokio::task::spawn_blocking(action)
        .await
        .map_err(|_| Error::Internal)?
}
