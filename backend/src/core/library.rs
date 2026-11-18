use super::{SessionSettings, valid_id};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};

/// Immutable provenance of a delegated session, including its owning tool call.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionParent {
    pub session_id: String,
    pub operation_id: String,
    pub tool_call_id: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<SessionParent>,
    /// Empty means every available tool is enabled. Retain names across tool availability changes.
    #[serde(default)]
    pub disabled_tools: Vec<String>,
    pub title: Option<String>,
    pub manually_named: bool,
    pub activity_at: u64,
}
impl SessionMetadata {
    pub fn validate(&self) -> Result<()> {
        validate_disabled_tools(&self.disabled_tools)?;
        if self.parent.as_ref().is_some_and(|parent| {
            !valid_id(&parent.session_id)
                || !valid_id(&parent.operation_id)
                || parent.tool_call_id.trim().is_empty()
                || parent.tool_call_id.len() > 512
                || parent.tool_call_id.chars().any(char::is_control)
        }) {
            return Err(Error::Invalid("Invalid parent session."));
        }
        if self.title.as_ref().is_some_and(|s| {
            s.trim().is_empty() || s.len() > 512 || s.chars().any(char::is_control)
        }) {
            return Err(Error::Invalid(
                "Session title must be a nonempty single line of at most 512 bytes.",
            ));
        }
        Ok(())
    }
    pub fn tool_enabled(&self, name: &str) -> bool {
        !self.disabled_tools.iter().any(|disabled| disabled == name)
    }
    pub fn activity() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u64::MAX as u128) as u64
    }
}

fn validate_disabled_tools(disabled_tools: &[String]) -> Result<()> {
    let mut names = std::collections::HashSet::new();
    if disabled_tools.len() > 256
        || disabled_tools.iter().any(|name| {
            name.is_empty()
                || name.len() > 128
                || name.chars().any(|c| c.is_control() || c.is_whitespace())
                || !names.insert(name)
        })
    {
        return Err(Error::Invalid("Invalid disabled tools."));
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LibraryConfiguration {
    #[serde(default = "enabled")]
    pub automatic_titles: bool,
    pub default_model: Option<String>,
    /// Defaults for new top-level sessions only; retain unavailable tool names.
    #[serde(default = "default_disabled_tools")]
    pub default_disabled_tools: Vec<String>,
    pub settings: SessionSettings,
    pub order: Vec<String>,
}
fn enabled() -> bool {
    true
}
fn default_disabled_tools() -> Vec<String> {
    vec!["shell".into()]
}
impl Default for LibraryConfiguration {
    fn default() -> Self {
        Self {
            automatic_titles: true,
            default_model: None,
            default_disabled_tools: default_disabled_tools(),
            settings: SessionSettings::default(),
            order: vec![],
        }
    }
}
impl LibraryConfiguration {
    pub fn validate(&self) -> Result<()> {
        self.settings.validate()?;
        validate_disabled_tools(&self.default_disabled_tools)?;
        if self
            .default_model
            .as_ref()
            .is_some_and(|s| !valid_model_id(s))
            || self.order.len() > 10000
        {
            return Err(Error::Invalid("Invalid library configuration."));
        }
        let mut ids = std::collections::HashSet::new();
        if self.order.iter().any(|id| !valid_id(id) || !ids.insert(id)) {
            return Err(Error::Invalid("Invalid conversation ordering."));
        }
        Ok(())
    }
}
pub fn valid_model_id(model: &str) -> bool {
    !model.trim().is_empty()
        && model.encode_utf16().count() <= 128
        && !model.chars().any(char::is_control)
}
