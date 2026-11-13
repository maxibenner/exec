use crate::{Error, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SearchSource {
    pub title: String,
    pub url: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct WebSearchResult {
    pub query: String,
    pub answer: String,
    pub sources: Vec<SearchSource>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccountBalance {
    pub amount: String,
    pub currency: String,
}
pub fn search_query(query: &str) -> Result<()> {
    if query.trim().is_empty() || query.len() > 2048 || query.chars().any(char::is_control) {
        return Err(Error::Invalid(
            "Search query must be a nonempty single line of at most 2048 bytes.",
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FetchedContent {
    pub url: String,
    pub content_type: String,
    pub text: String,
    pub truncated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AllowanceWindow {
    pub duration_seconds: u64,
    pub used_percent: f64,
    pub resets_at: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AccountUsage {
    pub windows: Vec<AllowanceWindow>,
    pub fetched_at: u64,
    pub stale: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ContextUsage {
    pub tokens: u64,
    pub limit: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionAttempt {
    pub id: String,
    pub provider: String,
    pub state: String,
    pub error: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionChallenge {
    pub attempt: ConnectionAttempt,
    pub authorization_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MetadataFreshness {
    pub provider: String,
    pub models_fetched_at: Option<u64>,
    pub models_stale: bool,
    pub usage_fetched_at: Option<u64>,
    pub usage_stale: bool,
    pub balance_fetched_at: Option<u64>,
    pub balance_stale: bool,
}
