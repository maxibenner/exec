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
