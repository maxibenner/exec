use super::{
    Result,
    http::{Api, INVALID_RESPONSE},
    output,
    terminal::{self, Signals},
};
use reqwest::{Method, Url};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io::Write,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
enum State {
    Running,
    Completed,
    Failed,
    Interrupted,
}
#[derive(Deserialize, Serialize)]
struct Attempt {
    id: String,
    provider: String,
    state: State,
    // Deliberately do not deserialize error: it may contain provider/account details.
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceCode {
    user_code: String,
    expires_at: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Challenge {
    attempt: Attempt,
    authorization_url: Option<String>,
    device_code: Option<DeviceCode>,
}

pub(super) async fn connect(api: &Api, signals: Signals) -> Result<()> {
    if signals.cancel.is_cancelled() {
        return Err(terminal::INTERRUPTED);
    }
    // Do not abandon this mutation on a signal: get its ID so cancellation stays targeted.
    let challenge: Challenge = api
        .request(
            Method::POST,
            "/v1/providers/openai/connect",
            Some(json!({"method":"device_code"})),
        )
        .await?;
    if !exec_agent::core::valid_id(&challenge.attempt.id) || challenge.attempt.provider != "openai"
    {
        return Err(INVALID_RESPONSE);
    }
    let id = challenge.attempt.id.clone();
    let mut active = challenge.attempt.state == State::Running;
    let result = follow(api, challenge, &signals.cancel, &mut active).await;
    if active && result.is_err() {
        let _ = cancel_and_observe(api, &id).await;
    }
    result
}

async fn follow(
    api: &Api,
    challenge: Challenge,
    cancel: &CancellationToken,
    active: &mut bool,
) -> Result<()> {
    if !*active {
        return settled(challenge.attempt.state);
    }
    if cancel.is_cancelled() {
        return Err(terminal::INTERRUPTED);
    }
    let url = challenge.authorization_url.ok_or(INVALID_RESPONSE)?;
    let code = challenge.device_code.ok_or(INVALID_RESPONSE)?;
    let parsed = Url::parse(&url).map_err(|_| INVALID_RESPONSE)?;
    if url.len() > 2048
        || url.chars().any(char::is_control)
        || parsed.scheme() != "https"
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || code.user_code.is_empty()
        || code.user_code.len() > 128
        || !code.user_code.bytes().all(|b| (0x21..=0x7e).contains(&b))
    {
        return Err(INVALID_RESPONSE);
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "Cannot read the system clock.")?
        .as_secs();
    let remaining = code.expires_at.saturating_sub(now).min(900);
    if remaining == 0 {
        return Err("The device login challenge expired; cancellation was requested.");
    }
    let deadline = Instant::now() + Duration::from_secs(remaining);
    terminal::require_interactive()?;
    {
        let mut stdout = std::io::stdout().lock();
        // Challenge material is written only here, and only to an interactive terminal.
        writeln!(stdout, "Open {url}\nEnter code: {}", code.user_code)
            .and_then(|_| stdout.flush())
            .map_err(|_| "Cannot display the login challenge; cancellation was requested.")?;
    }
    tokio::time::timeout_at(deadline, async {
        loop {
            let current: Option<Attempt> = tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(terminal::INTERRUPTED),
                result = api.request(Method::GET, "/v1/connection-attempt", None) => result?,
            };
            let current = current.ok_or("The connection attempt is unavailable; inspect provider status.")?;
            if current.id != challenge.attempt.id || current.provider != "openai" {
                return Err("The connection attempt changed; no other attempt was cancelled.");
            }
            *active = current.state == State::Running;
            if !*active {
                return settled(current.state);
            }
            tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(terminal::INTERRUPTED),
                _ = tokio::time::sleep(Duration::from_secs(2)) => {},
            }
        }
    }).await.map_err(|_| "Device login timed out; cancellation was requested. Inspect provider status before continuing.")?
}

fn settled(state: State) -> Result<()> {
    match state {
        State::Completed => output(&json!({"id":"openai","connected":true})),
        State::Failed => Err("OpenAI connection failed. No retry was made."),
        State::Interrupted => Err("OpenAI connection was interrupted."),
        State::Running => Err(INVALID_RESPONSE),
    }
}

pub(super) async fn status(api: &Api) -> Result<()> {
    let current: Option<Attempt> = api
        .request(Method::GET, "/v1/connection-attempt", None)
        .await?;
    if let Some(attempt) = &current
        && (!exec_agent::core::valid_id(&attempt.id)
            || !matches!(attempt.provider.as_str(), "openai" | "deepseek"))
    {
        return Err(INVALID_RESPONSE);
    }
    output(&current)
}

pub(super) async fn cancel(api: &Api, id: &str) -> Result<()> {
    cancel_and_observe(api, id).await?;
    output(&json!({"attemptID":id,"cancellationRequested":true}))
}

async fn cancel_and_observe(api: &Api, id: &str) -> Result<()> {
    // Exactly one cancellation mutation, even if it fails or further signals arrive.
    let _: Value = api
        .request(
            Method::POST,
            "/v1/connection-attempt/cancel",
            Some(json!({"operationID":id})),
        )
        .await?;
    let _ = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let Ok(Some(current)) = api
                .request::<Option<Attempt>>(Method::GET, "/v1/connection-attempt", None)
                .await
            else {
                break;
            };
            if current.id != id || current.provider != "openai" || current.state != State::Running {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    })
    .await;
    Ok(())
}
