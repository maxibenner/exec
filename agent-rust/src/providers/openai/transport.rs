//! Fixed-origin, credential-redacting OpenAI transport. No redirects, proxies or retries.
use super::super::deepseek::HttpResponse;
use crate::{Error, ProviderFailure as Failure, Result};
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
    Keys,
    Revoke,
    Models,
    Responses,
    Images,
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
                .map_err(|_| Error::Provider(Failure::Transport))?,
        })
    }
}
#[async_trait]
impl Transport for Http {
    async fn send(&self, request: Request, cancel: CancellationToken) -> Result<HttpResponse> {
        let (url, form) = match request.endpoint {
            Endpoint::Token => ("https://auth.openai.com/oauth/token", true),
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
        if matches!(request.endpoint, Endpoint::Images) {
            builder = builder.header("x-codex-image-turn-id", crate::core::new_id());
        }
        let response = tokio::select! {biased;_=cancel.cancelled()=>return Err(Error::Cancelled), response=builder.send()=>response.map_err(|_|Error::Provider(Failure::Transport))?};
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
                    .map(|r| r.map_err(|_| Error::Provider(Failure::Transport))),
            ),
        })
    }
}
pub(crate) fn status(status: u16) -> Result<()> {
    match status {
        200..=299 => Ok(()),
        401 | 403 => Err(Error::Provider(Failure::Authentication)),
        429 => Err(Error::Provider(Failure::RateLimit)),
        400..=499 => Err(Error::Provider(Failure::Request)),
        _ => Err(Error::Provider(Failure::Transport)),
    }
}
pub(crate) async fn json(
    transport: &dyn Transport,
    request: Request,
    limit: usize,
    cancel: CancellationToken,
) -> Result<serde_json::Value> {
    let deadline = if matches!(request.endpoint, Endpoint::Images) {
        600
    } else {
        30
    };
    let work = async {
        let response = transport.send(request, cancel.clone()).await?;
        status(response.status)?;
        if response
            .content_type
            .as_deref()
            .is_none_or(|s| s.split(';').next() != Some("application/json"))
        {
            return Err(Error::Provider(Failure::Response));
        }
        let mut bytes = Vec::new();
        let mut stream = response.body;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            if bytes.len() + chunk.len() > limit {
                return Err(Error::Provider(Failure::Response));
            }
            bytes.extend(chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| Error::Provider(Failure::Response))
    };
    tokio::select! {biased;_=cancel.cancelled()=>Err(Error::Cancelled),r=tokio::time::timeout(Duration::from_secs(deadline),work)=>r.map_err(|_|Error::Provider(Failure::Timeout))?}
}
