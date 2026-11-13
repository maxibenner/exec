use super::response_stream::{ByteStream, read_json, read_sse};
use crate::{Error, ProviderFailure as Failure, Result, check_cancel, core::*};
use async_trait::async_trait;
use futures_util::{StreamExt, future::BoxFuture, stream::BoxStream};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashSet},
    sync::Arc,
    time::Duration,
};
use tokio_util::sync::CancellationToken;
pub type CredentialSource =
    Arc<dyn Fn(CancellationToken) -> BoxFuture<'static, Result<String>> + Send + Sync>;
pub struct HttpResponse {
    pub status: u16,
    pub content_type: Option<String>,
    pub body: ByteStream,
}
#[async_trait]
pub trait HttpTransport: Send + Sync {
    async fn request(
        &self,
        path: &str,
        key: &str,
        body: Option<String>,
        cancel: CancellationToken,
    ) -> Result<HttpResponse>;
}
pub struct ReqwestTransport {
    client: reqwest::Client,
}
impl ReqwestTransport {
    pub fn new() -> Result<Self> {
        Ok(Self {
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .retry(reqwest::retry::never())
                .no_proxy()
                .build()
                .map_err(|_| error(Failure::Transport))?,
        })
    }
}
#[async_trait]
impl HttpTransport for ReqwestTransport {
    async fn request(
        &self,
        path: &str,
        key: &str,
        body: Option<String>,
        cancel: CancellationToken,
    ) -> Result<HttpResponse> {
        let url = format!("https://api.deepseek.com/{path}");
        let builder = if let Some(body) = body {
            self.client
                .post(url)
                .header(
                    "Accept",
                    if path == "chat/completions" {
                        "text/event-stream"
                    } else {
                        "application/json"
                    },
                )
                .header("Content-Type", "application/json")
                .body(body)
        } else {
            self.client.get(url).header("Accept", "application/json")
        };
        let response = tokio::select! {biased;_=cancel.cancelled()=>return Err(Error::Cancelled),r=builder.bearer_auth(key).header("Cache-Control","no-store").send()=>r.map_err(|_|error(Failure::Transport))?};
        Ok(HttpResponse {
            status: response.status().as_u16(),
            content_type: response
                .headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned),
            body: Box::pin(
                response
                    .bytes_stream()
                    .map(|r| r.map_err(|_| error(Failure::Transport))),
            ),
        })
    }
}
fn error(code: Failure) -> Error {
    Error::Provider(code)
}
fn object(v: &Value) -> Result<&serde_json::Map<String, Value>> {
    v.as_object().ok_or(error(Failure::Response))
}
fn optional_text(v: Option<&Value>) -> Result<&str> {
    match v {
        None | Some(Value::Null) => Ok(""),
        Some(Value::String(s)) => Ok(s),
        _ => Err(error(Failure::Response)),
    }
}
fn valid_model(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.as_bytes()[0].is_ascii_alphanumeric()
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}
fn valid_tool(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
}
#[derive(Default)]
struct Fragment {
    id: String,
    name: String,
    arguments: String,
}
#[derive(Default)]
struct Decoder {
    calls: BTreeMap<usize, Fragment>,
    finish: Option<String>,
    text_bytes: usize,
    has_text: bool,
}
impl Decoder {
    fn decode(&mut self, data: &str) -> Result<Vec<ProviderEvent>> {
        let invalid = error(Failure::Response);
        if data == "[DONE]" {
            if self.finish.is_none()
                || (!self.has_text && self.calls.is_empty())
                || (self.finish.as_deref() == Some("tool_calls")) == self.calls.is_empty()
            {
                return Err(invalid);
            }
            let mut ids = HashSet::new();
            let mut events = vec![];
            for (position, (index, call)) in self.calls.iter().enumerate() {
                if *index != position
                    || call.id.trim().is_empty()
                    || !ids.insert(&call.id)
                    || !valid_tool(&call.name)
                {
                    return Err(invalid);
                }
                let args: Value =
                    serde_json::from_str(&call.arguments).map_err(|_| invalid.clone())?;
                if !valid_json_depth(&args, 0) {
                    return Err(invalid);
                }
                events.push(ProviderEvent::ToolCall(ToolCall {
                    id: call.id.clone(),
                    name: call.name.clone(),
                    arguments: object(&args)?.clone(),
                }));
            }
            events.push(ProviderEvent::Done);
            return Ok(events);
        }
        let chunk: Value = serde_json::from_str(data).map_err(|_| invalid.clone())?;
        let chunk = object(&chunk)?;
        let choices = chunk
            .get("choices")
            .and_then(Value::as_array)
            .ok_or(invalid.clone())?;
        if chunk.get("error").is_some_and(|v| !v.is_null()) || choices.len() > 1 {
            return Err(invalid);
        }
        if choices.is_empty() {
            if self.finish.is_none() {
                return Err(invalid);
            }
            object(chunk.get("usage").ok_or(invalid)?)?;
            return Ok(vec![]);
        }
        let choice = object(&choices[0])?;
        if choice.get("index").and_then(Value::as_u64) != Some(0) || self.finish.is_some() {
            return Err(invalid);
        }
        let delta = object(choice.get("delta").ok_or(invalid.clone())?)?;
        if delta.get("role").is_some_and(|v| v != "assistant") {
            return Err(invalid);
        }
        if !optional_text(delta.get("reasoning_content"))?.is_empty() {
            return Err(error(Failure::Unsupported));
        }
        let content = optional_text(delta.get("content"))?;
        self.text_bytes += content.len();
        if self.text_bytes > 4 * 1024 * 1024 {
            return Err(invalid);
        }
        self.has_text |= !content.trim().is_empty();
        if let Some(calls) = delta.get("tool_calls").filter(|v| !v.is_null()) {
            for fragment in calls.as_array().ok_or(invalid.clone())? {
                let fragment = object(fragment)?;
                let index = fragment
                    .get("index")
                    .and_then(Value::as_u64)
                    .filter(|i| *i < 64)
                    .ok_or(invalid.clone())? as usize;
                if fragment
                    .get("type")
                    .is_some_and(|v| !v.is_null() && v != "function")
                {
                    return Err(invalid);
                }
                let call = self.calls.entry(index).or_default();
                call.id.push_str(optional_text(fragment.get("id"))?);
                if let Some(function) = fragment.get("function").filter(|v| !v.is_null()) {
                    let function = object(function)?;
                    call.name.push_str(optional_text(function.get("name"))?);
                    call.arguments
                        .push_str(optional_text(function.get("arguments"))?);
                    if call.arguments.len() > 32768 {
                        return Err(invalid);
                    }
                }
                if call.id.len() > 256 || call.name.len() > 128 {
                    return Err(invalid);
                }
            }
        }
        if let Some(finish) = choice.get("finish_reason").filter(|v| !v.is_null()) {
            if finish != "stop" && finish != "tool_calls" {
                return Err(invalid);
            }
            self.finish = Some(finish.as_str().unwrap().into());
        }
        Ok(if content.is_empty() {
            vec![]
        } else {
            vec![ProviderEvent::Text(content.into())]
        })
    }
}
pub fn request_body(request: &ProviderRequest) -> Result<String> {
    if !valid_model(&request.model) || request.messages.is_empty() || request.tools.len() > 64 {
        return Err(error(Failure::Request));
    }
    let mut names = HashSet::new();
    for tool in &request.tools {
        if !valid_tool(&tool.name) || !names.insert(&tool.name) {
            return Err(error(Failure::Request));
        }
    }
    let mut messages:Vec<_>=request.messages.iter().map(|message|match message{
        ContextMessage::User{text}=>json!({"role":"user","content":text}),
        ContextMessage::Tool{call_id,text,outcome}=>json!({"role":"tool","tool_call_id":call_id,"content":if *outcome==ToolOutcome::Completed{text.clone()}else{format!("[Tool outcome: {}]\n{text}",serde_json::to_value(outcome).unwrap().as_str().unwrap())}}),
        ContextMessage::Assistant{text,calls}=>{let mut value=json!({"role":"assistant","content":text});if !calls.is_empty(){value["tool_calls"]=json!(calls.iter().map(|call|json!({"id":call.id,"type":"function","function":{"name":call.name,"arguments":serde_json::to_string(&call.arguments).unwrap()}})).collect::<Vec<_>>());}value},
    }).collect();
    if !request.instructions.is_empty() {
        if request.instructions.len() > 3 * 64 * 1024 || request.instructions.contains('\0') {
            return Err(error(Failure::Request));
        }
        messages.insert(0, json!({"role":"system", "content":request.instructions}));
    }
    let mut value = json!({"model":request.model,"stream":true,"thinking":{"type":"disabled"},"reasoning_effort":"none","messages":messages});
    if !request.tools.is_empty() {
        value["tools"]=json!(request.tools.iter().map(|t|json!({"type":"function","function":{"name":t.name,"description":t.description,"parameters":t.parameters}})).collect::<Vec<_>>());
    }
    let body = serde_json::to_string(&value).map_err(|_| error(Failure::Request))?;
    if body.len() > 16 * 1024 * 1024 {
        return Err(error(Failure::Request));
    }
    Ok(body)
}
#[derive(Clone)]
pub struct DeepSeekProvider {
    credentials: CredentialSource,
    transport: Arc<dyn HttpTransport>,
    timeout: Duration,
    authentication: Option<Arc<super::credential_store::DeepSeekCredentials>>,
}
impl DeepSeekProvider {
    pub fn managed(
        authentication: Arc<super::credential_store::DeepSeekCredentials>,
    ) -> Result<Self> {
        Self::with_authentication(
            authentication,
            Arc::new(ReqwestTransport::new()?),
            Duration::from_secs(120),
        )
    }
    pub fn with_authentication(
        authentication: Arc<super::credential_store::DeepSeekCredentials>,
        transport: Arc<dyn HttpTransport>,
        timeout: Duration,
    ) -> Result<Self> {
        let source = authentication.clone();
        let mut provider = Self::with_transport(
            Arc::new(move |cancel| {
                let source = source.clone();
                Box::pin(async move { source.key(&cancel) })
            }),
            transport,
            timeout,
        )?;
        provider.authentication = Some(authentication);
        Ok(provider)
    }
    pub fn new(credentials: CredentialSource) -> Result<Self> {
        Self::with_transport(
            credentials,
            Arc::new(ReqwestTransport::new()?),
            Duration::from_secs(120),
        )
    }
    pub fn with_transport(
        credentials: CredentialSource,
        transport: Arc<dyn HttpTransport>,
        timeout: Duration,
    ) -> Result<Self> {
        if timeout.is_zero() || timeout > Duration::from_secs(900) {
            return Err(error(Failure::Request));
        }
        Ok(Self {
            credentials,
            transport,
            timeout,
            authentication: None,
        })
    }
    async fn json_service(
        &self,
        path: &str,
        body: Option<String>,
        parent: CancellationToken,
    ) -> Result<Value> {
        check_cancel(&parent)?;
        let cancel = parent.child_token();
        let _guard = cancel.clone().drop_guard();
        let request = async {
            let response = self.request(path, cancel, body).await?;
            content_type(&response, "application/json")?;
            read_json(response.body).await
        };
        tokio::select! { biased;
            _ = parent.cancelled() => Err(Error::Cancelled),
            _ = tokio::time::sleep(self.timeout) => Err(error(Failure::Timeout)),
            result = request => result,
        }
    }
    async fn request(
        &self,
        path: &str,
        cancel: CancellationToken,
        body: Option<String>,
    ) -> Result<HttpResponse> {
        check_cancel(&cancel)?;
        let key = (self.credentials)(cancel.clone())
            .await
            .map_err(|_| error(Failure::Authentication))?;
        check_cancel(&cancel)?;
        let key = key.trim();
        if key.is_empty() || key.len() > 8192 || !key.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
            return Err(error(Failure::Authentication));
        }
        let response = self
            .transport
            .request(path, key, body, cancel)
            .await
            .map_err(|e| {
                if e == Error::Cancelled {
                    e
                } else {
                    error(Failure::Transport)
                }
            })?;
        if !(200..300).contains(&response.status) {
            return Err(error(match response.status {
                401 | 403 => Failure::Authentication,
                402 => Failure::Quota,
                429 => Failure::RateLimit,
                408 | 504 => Failure::Timeout,
                400..=499 => Failure::Request,
                _ => Failure::Transport,
            }));
        }
        Ok(response)
    }
}
fn content_type(response: &HttpResponse, expected: &str) -> Result<()> {
    if response
        .content_type
        .as_deref()
        .and_then(|s| s.split(';').next())
        .is_none_or(|s| !s.trim().eq_ignore_ascii_case(expected))
    {
        return Err(error(Failure::Response));
    }
    Ok(())
}
#[async_trait]
impl ChatProvider for DeepSeekProvider {
    fn supports_web_search(&self) -> bool {
        true
    }
    async fn search_web(
        &self,
        _model: &str,
        query: String,
        cancel: CancellationToken,
    ) -> Result<WebSearchResult> {
        search_query(&query)?;
        if query.chars().count() > 128 {
            return Err(Error::Invalid(
                "DeepSeek search queries must contain at most 128 characters.",
            ));
        }
        let body = json!({"query":query,"count":10,"need_content":false}).to_string();
        let response = self
            .json_service("v1/tools/search", Some(body), cancel)
            .await?;
        super::deepseek_services::search(response, query)
    }
    async fn account_balances(
        &self,
        provider: &str,
        cancel: CancellationToken,
    ) -> Result<Vec<AccountBalance>> {
        if provider != "deepseek" {
            return Err(Error::Invalid("Unknown provider."));
        }
        super::deepseek_services::balances(self.json_service("user/balance", None, cancel).await?)
    }
    fn connections(&self) -> Vec<ProviderConnection> {
        self.authentication
            .as_ref()
            .map(|a| vec![a.connection()])
            .unwrap_or_default()
    }
    async fn set_credential(&self, provider: &str, key: Option<String>) -> Result<()> {
        if provider != "deepseek" {
            return Err(Error::Invalid("Unknown provider."));
        }
        self.authentication
            .as_ref()
            .ok_or(Error::Invalid("Credentials are externally managed."))?
            .set(key)
            .await
    }
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        let provider = self.clone();
        Box::pin(async_stream::try_stream! {
            check_cancel(&request.cancel)?;let body=request_body(&request)?;
            let cancel=request.cancel.child_token();let _guard=cancel.clone().drop_guard();
            let source_cancel=cancel.clone();
            let deadline=tokio::time::sleep(provider.timeout);tokio::pin!(deadline);
            let source=async_stream::try_stream!{
                let response=provider.request("chat/completions",source_cancel,Some(body)).await?;content_type(&response,"text/event-stream")?;
                let mut frames=read_sse(response.body);let mut decoder=Decoder::default();
                while let Some(frame)=frames.next().await{for event in decoder.decode(&frame?)?{let done=matches!(event,ProviderEvent::Done);yield event;if done{return;}}}
                Err(error(Failure::Response))?;
            };
            futures_util::pin_mut!(source);
            loop{
                let next=tokio::select!{biased;_=request.cancel.cancelled()=>Err(Error::Cancelled),_=&mut deadline=>Err(error(Failure::Timeout)),value=source.next()=>Ok(value)}?;
                let Some(event):Option<Result<ProviderEvent>>=next else {break;};check_cancel(&request.cancel)?;
                let event=event?;let done=matches!(event,ProviderEvent::Done);yield event;if done{break;}
            }
        })
    }
    async fn models(&self, parent: CancellationToken) -> Result<Vec<ChatModel>> {
        check_cancel(&parent)?;
        let cancel = parent.child_token();
        let _guard = cancel.clone().drop_guard();
        let request = async {
            let response = self.request("models", cancel, None).await?;
            content_type(&response, "application/json")?;
            let result = read_json(response.body).await?;
            let object = object(&result)?;
            if object.get("object") != Some(&json!("list")) {
                return Err(error(Failure::Response));
            }
            let data = object
                .get("data")
                .and_then(Value::as_array)
                .filter(|a| a.len() <= 256)
                .ok_or(error(Failure::Response))?;
            let mut ids = HashSet::new();
            let mut models = vec![];
            for model in data {
                let id = model
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|id| valid_model(id))
                    .ok_or(error(Failure::Response))?;
                if !ids.insert(id) {
                    return Err(error(Failure::Response));
                }
                let name = match model.get("name") {
                    None => id,
                    Some(v) => optional_text(Some(v))?,
                };
                if name.trim().is_empty()
                    || name.chars().count() > 256
                    || name.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}')
                {
                    return Err(error(Failure::Response));
                }
                let limit = |key| -> Result<Option<u64>> {
                    match model.get(key) {
                        None => Ok(None),
                        Some(v) => Ok(Some(
                            v.as_u64()
                                .filter(|v| *v > 0 && *v <= 1_000_000_000)
                                .ok_or(error(Failure::Response))?,
                        )),
                    }
                };
                models.push(ChatModel {
                    id: id.into(),
                    name: name.into(),
                    context_window: limit("context_window")?,
                    max_output_tokens: limit("max_output_tokens")?,
                });
            }
            Ok(models)
        };
        tokio::select! {biased;_=parent.cancelled()=>Err(Error::Cancelled),_=tokio::time::sleep(self.timeout)=>Err(error(Failure::Timeout)),result=request=>result}
    }
}
