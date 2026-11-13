//! DeepSeek-specific service wire decoding. No account identifiers or raw errors escape.
use crate::{Error, ProviderFailure, Result, core::*};
use serde_json::Value;
fn invalid() -> Error {
    Error::Provider(ProviderFailure::Response)
}
fn bounded(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.into();
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{} [Excerpt truncated.]", &text[..end])
}
pub(super) fn search(value: Value, query: String) -> Result<WebSearchResult> {
    let results = value
        .get("results")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    let mut sources = Vec::new();
    let mut excerpts = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for result in results.iter().take(10) {
        let text = |key| result.get(key).and_then(Value::as_str).ok_or_else(invalid);
        let title = text("title")?;
        let url = text("url")?;
        let summary = text("summary")?;
        let snippet = text("snippet")?;
        let Ok(parsed) = reqwest::Url::parse(url) else {
            continue;
        };
        if url.len() > 2048
            || parsed.scheme() != "https"
            || !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.host_str().is_none()
            || url.chars().any(char::is_control)
            || !seen.insert(url.to_owned())
        {
            continue;
        }
        sources.push(SearchSource {
            title: bounded(title, 200),
            url: url.into(),
        });
        excerpts.push(format!(
            "[{}] {}",
            sources.len(),
            bounded(if summary.is_empty() { snippet } else { summary }, 1000)
        ));
    }
    Ok(WebSearchResult {
        query,
        answer: if excerpts.is_empty() {
            "No usable search results returned.".into()
        } else {
            excerpts.join("\n\n")
        },
        sources,
    })
}
pub(super) fn balances(value: Value) -> Result<Vec<AccountBalance>> {
    let balances = value
        .get("balance_infos")
        .and_then(Value::as_array)
        .filter(|a| !a.is_empty() && a.len() <= 16)
        .ok_or_else(invalid)?;
    balances
        .iter()
        .map(|balance| {
            let amount = balance
                .get("total_balance")
                .and_then(Value::as_str)
                .ok_or_else(invalid)?;
            let currency = balance
                .get("currency")
                .and_then(Value::as_str)
                .filter(|c| ["USD", "CNY"].contains(c))
                .ok_or_else(invalid)?;
            let digits = amount.strip_prefix('-').unwrap_or(amount);
            let parts: Vec<_> = digits.split('.').collect();
            if amount.len() > 64
                || parts.len() > 2
                || parts
                    .iter()
                    .any(|s| s.is_empty() || !s.bytes().all(|c| c.is_ascii_digit()))
            {
                return Err(invalid());
            }
            Ok(AccountBalance {
                amount: amount.into(),
                currency: currency.into(),
            })
        })
        .collect()
}
