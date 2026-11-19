//! Codex device authorization. Only the admin challenge carries the user code.
use super::{
    auth::{CLIENT_ID, now, token},
    transport::{self, Endpoint, Request, Transport},
};
use crate::{
    Error, ProviderFailure, Result, check_cancel,
    core::{AuthenticationChallenge, DeviceCodeChallenge},
};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::{sync::oneshot, time::Instant};
use tokio_util::sync::CancellationToken;

pub(super) const REDIRECT: &str = "https://auth.openai.com/deviceauth/callback";
const VERIFICATION_URL: &str = "https://auth.openai.com/codex/device";
const LIFETIME: Duration = Duration::from_secs(15 * 60);
const RESPONSE_LIMIT: usize = 16 * 1024;

pub(super) struct Authorization {
    pub code: String,
    pub verifier: String,
}
fn invalid() -> Error {
    Error::Provider(ProviderFailure::Response)
}
fn timeout() -> Error {
    Error::Provider(ProviderFailure::Timeout)
}
fn field<'a>(value: &'a Value, name: &str, limit: usize) -> Result<&'a str> {
    value[name]
        .as_str()
        .filter(|s| s.len() <= limit && token(s))
        .ok_or_else(invalid)
}
fn interval(value: &Value) -> Result<Duration> {
    // Codex returns a decimal string; also accept JSON integers. Never busy-poll.
    let seconds = match value.get("interval") {
        None => 5,
        Some(Value::String(s)) => s.trim().parse::<u64>().map_err(|_| invalid())?,
        Some(v) => v.as_u64().ok_or_else(invalid)?,
    };
    if seconds > LIFETIME.as_secs() {
        return Err(invalid());
    }
    Ok(Duration::from_secs(seconds.max(1)))
}
fn request(endpoint: Endpoint, body: Value) -> Request {
    Request {
        endpoint,
        session_id: None,
        access: None,
        account: None,
        body: Some(body.to_string()),
    }
}

pub(super) async fn authorize(
    transport: &dyn Transport,
    challenge: oneshot::Sender<AuthenticationChallenge>,
    cancel: CancellationToken,
) -> Result<Authorization> {
    check_cancel(&cancel)?;
    // The public Codex protocol specifies a 15-minute lifetime, not an expires_in field.
    // Start before issuance so request latency cannot extend the displayed lifetime.
    let deadline = Instant::now() + LIFETIME;
    let expires_at = now().saturating_add(LIFETIME.as_secs());
    let work = async {
        let value = transport::json(
            transport,
            request(Endpoint::DeviceUserCode, json!({"client_id": CLIENT_ID})),
            RESPONSE_LIMIT,
            cancel.clone(),
        )
        .await?;
        let device_auth_id = field(&value, "device_auth_id", 4096)?;
        let user_code = match (value.get("user_code"), value.get("usercode")) {
            (Some(_), None) => field(&value, "user_code", 64)?,
            (None, Some(_)) => field(&value, "usercode", 64)?,
            _ => return Err(invalid()),
        };
        if !user_code
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        {
            return Err(invalid());
        }
        let interval = interval(&value)?;
        check_cancel(&cancel)?;
        challenge
            .send(AuthenticationChallenge {
                authorization_url: VERIFICATION_URL.into(),
                device_code: Some(DeviceCodeChallenge {
                    user_code: user_code.into(),
                    expires_at,
                }),
            })
            .map_err(|_| Error::Cancelled)?;
        loop {
            check_cancel(&cancel)?;
            if Instant::now() >= deadline {
                return Err(timeout());
            }
            let poll = async {
                let response = transport
                    .send(
                        request(
                            Endpoint::DeviceToken,
                            json!({"device_auth_id": device_auth_id, "user_code": user_code}),
                        ),
                        cancel.clone(),
                    )
                    .await?;
                // These statuses alone mean pending in Codex, only on this endpoint.
                // Drop pending/error bodies without parsing or exposing their contents.
                if matches!(response.status, 403 | 404) {
                    return Ok(None);
                }
                transport::status(response.status)?;
                let value = transport::json_body(response, RESPONSE_LIMIT).await?;
                let code = field(&value, "authorization_code", 4096)?;
                let verifier = field(&value, "code_verifier", 128)?;
                if verifier.len() < 43
                    || !verifier.bytes().all(|b| {
                        b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~')
                    })
                {
                    return Err(invalid());
                }
                Ok(Some(Authorization {
                    code: code.into(),
                    verifier: verifier.into(),
                }))
            };
            let authorization = tokio::time::timeout(Duration::from_secs(30), poll)
                .await
                .map_err(|_| timeout())??;
            if Instant::now() >= deadline {
                return Err(timeout());
            }
            if let Some(authorization) = authorization {
                return Ok(authorization);
            }
            tokio::time::sleep(interval).await;
        }
    };
    tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(Error::Cancelled),
        result = tokio::time::timeout_at(deadline, work) => result.map_err(|_| timeout())?,
    }
}
