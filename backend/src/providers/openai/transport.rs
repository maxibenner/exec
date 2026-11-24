//! Fixed-origin, credential-redacting OpenAI transport. No redirects, proxies or retries.
use super::super::deepseek::HttpResponse;
use crate::provider_diagnostics::{http_error, transport_error};
use crate::{Error, ProviderFailure as Failure, ProviderTransportPhase as Phase, Result};
use async_trait::async_trait;
use futures_util::StreamExt;
use std::time::Duration;
use tokio_util::sync::CancellationToken;
#[derive(Clone)]
pub struct Request {
    pub endpoint: Endpoint,
    pub session_id: Option<String>,
    pub access: Option<String>,
    pub account: Option<String>,
    pub body: Option<String>,
}
#[derive(Clone, Copy)]
pub enum Endpoint {
    Token,
    DeviceUserCode,
    DeviceToken,
    Keys,
    Revoke,
    Models,
    Responses,
    Images,
    ImageEdits,
    Usage,
}
#[async_trait]
pub trait Transport: Send + Sync {
    async fn send(&self, request: Request, cancel: CancellationToken) -> Result<HttpResponse>;
}
pub struct Http {
    client: reqwest::Client,
}
impl Http {
    pub fn new() -> Result<Self> {
        Ok(Self {
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .retry(reqwest::retry::never())
                .no_proxy()
                .connect_timeout(Duration::from_secs(15))
                .build()
                .map_err(|e| transport_error(e, Phase::Setup))?,
        })
    }
}
#[async_trait]
impl Transport for Http {
    async fn send(&self, request: Request, cancel: CancellationToken) -> Result<HttpResponse> {
        let (url, form) = match request.endpoint {
            Endpoint::Token => ("https://auth.openai.com/oauth/token", true),
            Endpoint::DeviceUserCode => (
                "https://auth.openai.com/api/accounts/deviceauth/usercode",
                false,
            ),
            Endpoint::DeviceToken => (
                "https://auth.openai.com/api/accounts/deviceauth/token",
                false,
            ),
            Endpoint::Keys => ("https://auth.openai.com/.well-known/jwks.json", false),
            Endpoint::Revoke => ("https://auth.openai.com/api/accounts/oauth/revoke", true),
            Endpoint::Models => (
                "https://chatgpt.com/backend-api/codex/models?client_version=0.162.1",
                false,
            ),
            Endpoint::Responses => ("https://chatgpt.com/backend-api/codex/responses", false),
            Endpoint::Images => (
                "https://chatgpt.com/backend-api/codex/images/generations",
                false,
            ),
            Endpoint::ImageEdits => ("https://chatgpt.com/backend-api/codex/images/edits", false),
            Endpoint::Usage => ("https://chatgpt.com/backend-api/wham/usage", false),
        };
        let mut builder = if let Some(body) = request.body {
            self.client
                .post(url)
                .header(
                    "Content-Type",
                    if form {
                        "application/x-www-form-urlencoded"
                    } else {
                        "application/json"
                    },
                )
                .body(body)
        } else {
            self.client.get(url)
        };
        builder = builder.header("Cache-Control", "no-store").header(
            "Accept",
            if matches!(request.endpoint, Endpoint::Responses) {
                "text/event-stream"
            } else {
                "application/json"
            },
        );
        if let Some(access) = request.access {
            builder = builder
                .bearer_auth(access)
                .header("originator", "exec_agent_rust")
                .header("User-Agent", "exec_agent_rust/0.1.0");
        }
        if let Some(account) = request.account {
            builder = builder.header("ChatGPT-Account-ID", account);
        }
        if let Some(session) = request.session_id {
            builder = builder.header("session-id", session);
        }
        if matches!(request.endpoint, Endpoint::Responses) {
            builder = builder
                .header("OpenAI-Beta", "responses=experimental")
                .header("x-client-request-id", crate::core::new_id());
        }
        if matches!(request.endpoint, Endpoint::Images | Endpoint::ImageEdits) {
            builder = builder.header("x-codex-image-turn-id", crate::core::new_id());
        }
        let response = tokio::select! {biased;_=cancel.cancelled()=>return Err(Error::Cancelled), response=builder.send()=>response.map_err(|e| transport_error(e, Phase::Send))?};
        Ok(HttpResponse {
            status: response.status().as_u16(),
            content_type: response
                .headers()
                .get("content-type")
                .and_then(|h| h.to_str().ok())
                .map(str::to_owned),
            body: Box::pin(
                response
                    .bytes_stream()
                    .map(|r| r.map_err(|e| transport_error(e, Phase::Body))),
            ),
        })
    }
}
pub(crate) fn status(status: u16) -> Result<()> {
    match status {
        200..=299 => Ok(()),
        401 | 403 => Err(http_error(Failure::Authentication, status)),
        429 => Err(http_error(Failure::RateLimit, status)),
        400..=499 => Err(http_error(Failure::Request, status)),
        _ => Err(http_error(Failure::Transport, status)),
    }
}
pub(crate) async fn json(
    transport: &dyn Transport,
    request: Request,
    limit: usize,
    cancel: CancellationToken,
) -> Result<serde_json::Value> {
    let deadline = if matches!(request.endpoint, Endpoint::Images | Endpoint::ImageEdits) {
        600
    } else {
        30
    };
    let work = async {
        let response = transport.send(request, cancel.clone()).await?;
        status(response.status)?;
        json_body(response, limit).await
    };
    tokio::select! {biased;_=cancel.cancelled()=>Err(Error::Cancelled),r=tokio::time::timeout(Duration::from_secs(deadline),work)=>r.map_err(|_|Error::Provider(Failure::Timeout))?}
}
/// Read only successful responses; callers handle endpoint-specific pending statuses first.
pub(super) async fn json_body(response: HttpResponse, limit: usize) -> Result<serde_json::Value> {
    if response
        .content_type
        .as_deref()
        .and_then(|s| s.split(';').next())
        .is_none_or(|s| !s.trim().eq_ignore_ascii_case("application/json"))
    {
        return Err(Error::Provider(Failure::Response));
    }
    let mut bytes = Vec::new();
    let mut stream = response.body;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if chunk.len() > limit.saturating_sub(bytes.len()) {
            return Err(Error::Provider(Failure::Response));
        }
        bytes.extend(chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| Error::Provider(Failure::Response))
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::stream;

    #[test]
    fn http_status_details_preserve_failure_category_without_response_content() {
        for (status_code, reason) in [
            (302, Failure::Transport),
            (400, Failure::Request),
            (401, Failure::Authentication),
            (403, Failure::Authentication),
            (429, Failure::RateLimit),
            (500, Failure::Transport),
            (503, Failure::Transport),
            (504, Failure::Transport),
        ] {
            let error = status(status_code).unwrap_err();
            assert_eq!(
                error,
                Error::ProviderDetailed {
                    reason,
                    detail: crate::ProviderDiagnostic::HttpStatus {
                        status: status_code
                    },
                }
            );
            assert_eq!(error.to_string(), Error::Provider(reason).to_string());
        }
        assert!(status(200).is_ok());
    }

    #[tokio::test]
    async fn json_media_type_is_case_insensitive_but_not_a_prefix_match() {
        for (kind, valid) in [
            (Some("application/json"), true),
            (Some("Application/JSON; Charset=UTF-8"), true),
            (Some(" application/Json ; charset=utf-8 "), true),
            (None, false),
            (Some(""), false),
            (Some("text/json"), false),
            (Some("application/jsonx"), false),
            (Some("application/json, text/html"), false),
        ] {
            let response = HttpResponse {
                status: 200,
                content_type: kind.map(str::to_owned),
                body: Box::pin(stream::iter([Ok(bytes::Bytes::from_static(b"{}"))])),
            };
            assert_eq!(json_body(response, 2).await.is_ok(), valid, "{kind:?}");
        }
    }
}
