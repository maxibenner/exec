use super::{SessionSettings, valid_id};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionMetadata {
    pub title: Option<String>,
    pub manually_named: bool,
    pub activity_at: u64,
}
impl SessionMetadata {
    pub fn validate(&self) -> Result<()> {
        if self.title.as_ref().is_some_and(|s| {
            s.trim().is_empty() || s.len() > 512 || s.chars().any(char::is_control)
        }) {
            return Err(Error::Invalid(
                "Session title must be a nonempty single line of at most 512 bytes.",
            ));
        }
        Ok(())
    }
    pub fn activity() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u64::MAX as u128) as u64
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LibraryConfiguration {
    pub default_model: Option<String>,
    pub settings: SessionSettings,
    pub order: Vec<String>,
}
impl LibraryConfiguration {
    pub fn validate(&self) -> Result<()> {
        self.settings.validate()?;
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
