use super::Result;
use reqwest::{Client, Method, header};
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::time::Duration;

const MAX_RESPONSE: usize = 65536;
const REQUEST_FAILED: &str = "Local HTTP request failed; it may have taken effect. No retry was made. Inspect service state before continuing.";
pub(super) const INVALID_RESPONSE: &str = "The local service returned an invalid response.";

pub(super) struct Api {
    client: Client,
    base: String,
}

impl Api {
    pub(super) fn new() -> Result<Self> {
        let port = match std::env::var("EXEC_AGENT_PORT") {
            Ok(value) if !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) => value
                .parse::<u16>()
                .ok()
                .filter(|p| *p != 0)
                .ok_or("EXEC_AGENT_PORT must be a port from 1 to 65535.")?,
            Err(std::env::VarError::NotPresent) => 8765,
            _ => return Err("EXEC_AGENT_PORT must be a port from 1 to 65535."),
        };
        let mut headers = header::HeaderMap::new();
        headers.insert(
            header::ACCEPT,
            header::HeaderValue::from_static("application/json"),
        );
        if let Some(token) = exec_agent::server_config::api_token()
            .map_err(|_| "Cannot load the administrator token. Check EXEC_AGENT_TOKEN / EXEC_AGENT_TOKEN_FILE.")?
        {
            let mut value = header::HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|_| "Invalid administrator token configuration.")?;
            value.set_sensitive(true);
            headers.insert(header::AUTHORIZATION, value);
        }
        let client = Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .http1_only()
            .pool_max_idle_per_host(0)
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(15))
            .default_headers(headers)
            .build()
            .map_err(|_| "Cannot initialize the local HTTP client.")?;
        Ok(Self {
            client,
            // Never accept a configurable host, URL, proxy or redirect for this credential.
            base: format!("http://127.0.0.1:{port}"),
        })
    }

    pub(super) async fn request<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<T> {
        let mut request = self.client.request(method, format!("{}{path}", self.base));
        // The backend bounds challenge startup to 45s; allow time to receive its result.
        if path.ends_with("/connect") {
            request = request.timeout(Duration::from_secs(60));
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        let mut response = request.send().await.map_err(|_| REQUEST_FAILED)?;
        if !response.status().is_success() {
            // Do not read or display error bodies, which can contain credentials or provider errors.
            return Err(match response.status().as_u16() {
                401 | 403 => "The local service rejected administrator authentication or access.",
                404 => "The requested operation is unavailable on the local service.",
                409 => {
                    "The local service is busy or the operation is no longer active. No retry was made."
                }
                _ => REQUEST_FAILED,
            });
        }
        if response
            .content_length()
            .is_some_and(|n| n > MAX_RESPONSE as u64)
        {
            return Err(INVALID_RESPONSE);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| REQUEST_FAILED)? {
            if chunk.len() > MAX_RESPONSE - bytes.len() {
                return Err(INVALID_RESPONSE);
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| INVALID_RESPONSE)
    }
}
