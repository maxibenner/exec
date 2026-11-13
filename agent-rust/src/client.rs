use crate::{Error, Result, core::*};
use futures_util::{StreamExt, stream::BoxStream};
use serde_json::{Value, json};
use std::{path::Path, time::Duration};
use tokio_util::sync::CancellationToken;
const MAX_RESPONSE: usize = 32 * 1024 * 1024;
const CONNECTION: &str = "Service connection failed. The request may have taken effect; inspect the conversation before continuing.";
const INVALID: &str =
    "Invalid or interrupted service response. Do not automatically repeat the request.";
const INTERRUPTED: &str = "Event stream interrupted. Reconnect explicitly to obtain the latest snapshot; do not resubmit work.";
#[derive(Clone)]
pub struct AgentClient {
    client: reqwest::Client,
}
impl AgentClient {
    pub fn new(socket: impl AsRef<Path>) -> Result<Self> {
        let client = reqwest::Client::builder()
            .unix_socket(socket.as_ref().to_owned())
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .no_proxy()
            .pool_max_idle_per_host(0)
            .build()
            .map_err(|_| Error::Invalid(CONNECTION))?;
        Ok(Self { client })
    }
    async fn open(
        &self,
        method: &str,
        route: &str,
        value: Option<Value>,
    ) -> Result<reqwest::Response> {
        let method = method
            .parse::<reqwest::Method>()
            .map_err(|_| Error::Invalid(CONNECTION))?;
        let mut request = self
            .client
            .request(method, format!("http://localhost{route}"));
        if let Some(value) = value {
            request = request.json(&value);
        }
        request.send().await.map_err(|_| Error::Invalid(CONNECTION))
    }
    async fn read(response: reqwest::Response) -> Result<Value> {
        let status = response.status().as_u16();
        // Drop arbitrary error bodies without displaying them.
        if status >= 400 {
            return Err(Error::Api(status));
        }
        let mut bytes = response.bytes_stream();
        let mut data = vec![];
        while let Some(chunk) = bytes.next().await {
            let chunk = chunk.map_err(|_| Error::Invalid(INVALID))?;
            if data.len() + chunk.len() > MAX_RESPONSE {
                return Err(Error::Invalid(INVALID));
            }
            data.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&data).map_err(|_| Error::Invalid(INVALID))
    }
    pub async fn call(&self, method: &str, route: &str, value: Option<Value>) -> Result<Value> {
        tokio::time::timeout(Duration::from_secs(130), async {
            Self::read(self.open(method, route, value).await?).await
        })
        .await
        .map_err(|_| Error::Invalid(INVALID))?
    }
    pub async fn search_web(&self, model: &str, query: &str) -> Result<WebSearchResult> {
        decode(
            self.call(
                "POST",
                "/v1/search",
                Some(json!({"model":model,"query":query})),
            )
            .await?,
        )
    }
    pub async fn balances(&self, provider: &str) -> Result<Vec<AccountBalance>> {
        if !provider
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        {
            return Err(Error::Invalid("Invalid provider ID."));
        }
        decode(
            self.call("GET", &format!("/v1/providers/{provider}/balance"), None)
                .await?,
        )
    }
    pub async fn connections(&self) -> Result<Vec<ProviderConnection>> {
        decode(self.call("GET", "/v1/providers", None).await?)
    }
    pub async fn connect_api_key(
        &self,
        provider: &str,
        key: &str,
    ) -> Result<Vec<ProviderConnection>> {
        if !provider
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        {
            return Err(Error::Invalid("Invalid provider ID."));
        }
        decode(
            self.call(
                "PUT",
                &format!("/v1/providers/{provider}"),
                Some(json!({"apiKey":key})),
            )
            .await?,
        )
    }
    pub async fn disconnect(&self, provider: &str) -> Result<Vec<ProviderConnection>> {
        if !provider
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        {
            return Err(Error::Invalid("Invalid provider ID."));
        }
        decode(
            self.call("DELETE", &format!("/v1/providers/{provider}"), None)
                .await?,
        )
    }
    pub async fn library(&self) -> Result<LibraryConfiguration> {
        decode(self.call("GET", "/v1/library", None).await?)
    }
    pub async fn update_library(
        &self,
        config: LibraryConfiguration,
    ) -> Result<LibraryConfiguration> {
        decode(
            self.call("PUT", "/v1/library", Some(serde_json::to_value(config)?))
                .await?,
        )
    }
    pub async fn rename(&self, id: &str, title: &str) -> Result<ConversationSnapshot> {
        decode(
            self.call(
                "PUT",
                &format!("{}/title", path(id)),
                Some(json!({"title":title})),
            )
            .await?,
        )
    }
    pub async fn select_model(&self, id: &str, model: &str) -> Result<ConversationSnapshot> {
        decode(
            self.call(
                "PUT",
                &format!("{}/model", path(id)),
                Some(json!({"model":model})),
            )
            .await?,
        )
    }
    pub async fn fork(&self, id: &str) -> Result<ConversationSnapshot> {
        decode(
            self.call("POST", &format!("{}/fork", path(id)), Some(json!({})))
                .await?,
        )
    }
    pub async fn health(&self) -> Result<Value> {
        self.call("GET", "/v1/health", None).await
    }
    pub async fn models(&self) -> Result<Value> {
        self.call("GET", "/v1/models", None).await
    }
    pub async fn list(&self) -> Result<Value> {
        self.call("GET", "/v1/conversations", None).await
    }
    pub async fn create(&self, model: &str, workspace: &str) -> Result<ConversationSnapshot> {
        decode(
            self.call(
                "POST",
                "/v1/conversations",
                Some(json!({"model":model,"workspace":workspace})),
            )
            .await?,
        )
    }
    pub async fn create_with_settings(
        &self,
        model: &str,
        workspace: &str,
        settings: SessionSettings,
    ) -> Result<ConversationSnapshot> {
        decode(
            self.call(
                "POST",
                "/v1/conversations",
                Some(json!({"model":model,"workspace":workspace,"settings":settings})),
            )
            .await?,
        )
    }
    pub async fn update_settings(
        &self,
        id: &str,
        settings: SessionSettings,
    ) -> Result<ConversationSnapshot> {
        decode(
            self.call(
                "PUT",
                &format!("{}/settings", path(id)),
                Some(serde_json::to_value(settings)?),
            )
            .await?,
        )
    }
    pub async fn get(&self, id: &str) -> Result<ConversationSnapshot> {
        decode(self.call("GET", &path(id), None).await?)
    }
    pub async fn delete(&self, id: &str) -> Result<()> {
        let response = self.call("DELETE", &path(id), None).await?;
        if response != json!({"deleted":true}) {
            return Err(Error::Invalid(INVALID));
        }
        Ok(())
    }
    pub async fn submit(&self, id: &str, text: &str) -> Result<String> {
        let value = self
            .call(
                "POST",
                &format!("{}/turns", path(id)),
                Some(json!({"text":text})),
            )
            .await?;
        value
            .get("operationID")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or(Error::Invalid(INVALID))
    }
    pub async fn steer(&self, id: &str, operation_id: &str, text: &str) -> Result<Value> {
        self.call(
            "POST",
            &format!("{}/steer", path(id)),
            Some(json!({"operationID":operation_id,"text":text})),
        )
        .await
    }
    pub async fn cancel(&self, id: &str, operation_id: &str) -> Result<Value> {
        self.call(
            "POST",
            &format!("{}/cancel", path(id)),
            Some(json!({"operationID":operation_id})),
        )
        .await
    }
    pub async fn approve(
        &self,
        id: &str,
        operation_id: &str,
        approval_id: &str,
        approved: bool,
    ) -> Result<Value> {
        self.call(
            "POST",
            &format!("{}/approvals", path(id)),
            Some(json!({"operationID":operation_id,"approvalID":approval_id,"approved":approved})),
        )
        .await
    }
    pub fn events(
        &self,
        id: &str,
        cancel: CancellationToken,
    ) -> BoxStream<'static, Result<ServiceEvent>> {
        let client = self.clone();
        let route = format!("{}/events", path(id));
        Box::pin(async_stream::try_stream! {
            let response=tokio::select!{biased;_=cancel.cancelled()=>return,result=tokio::time::timeout(Duration::from_secs(15),client.open("GET",&route,None))=>result.map_err(|_|Error::Invalid(INTERRUPTED))}??;
            if response.status().as_u16()!=200{Err(Error::Api(response.status().as_u16()))?;}
            if response.headers().get("content-type").and_then(|s|s.to_str().ok())!=Some("application/x-ndjson"){Err(Error::Invalid(INTERRUPTED))?;}
            let mut bytes=response.bytes_stream();let mut pending=Vec::new();
            loop{
                let chunk=tokio::select!{biased;_=cancel.cancelled()=>return,next=bytes.next()=>next};
                let Some(chunk)=chunk else{Err(Error::Invalid(INTERRUPTED))?;break;};let chunk=chunk.map_err(|_|Error::Invalid(INTERRUPTED))?;
                if pending.len()+chunk.len()>MAX_RESPONSE{Err(Error::Invalid(INTERRUPTED))?;}pending.extend_from_slice(&chunk);
                let mut consumed=0;
                while let Some(index)=pending[consumed..].iter().position(|b|*b==b'\n'){
                    let end=consumed+index;let frame:ServiceEvent=serde_json::from_slice(&pending[consumed..end]).map_err(|_|Error::Invalid(INTERRUPTED))?;
                    consumed=end+1;yield frame;
                }
                pending.drain(..consumed);
            }
        })
    }
}
fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T> {
    serde_json::from_value(value).map_err(|_| Error::Invalid(INVALID))
}
fn path(id: &str) -> String {
    let encoded: String = id
        .bytes()
        .map(|c| {
            if c.is_ascii_alphanumeric() || b"-_.~".contains(&c) {
                (c as char).to_string()
            } else {
                format!("%{c:02X}")
            }
        })
        .collect();
    format!("/v1/conversations/{encoded}")
}
