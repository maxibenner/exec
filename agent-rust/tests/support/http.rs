#![allow(dead_code)]
use bytes::Bytes;
use exec_agent::{
    Result,
    core::*,
    providers::{
        CredentialSource, DeepSeekProvider, HttpResponse, HttpTransport,
        response_stream::ByteStream,
    },
};
use futures_util::{
    Stream, StreamExt,
    future::BoxFuture,
    stream::{self},
};
use serde_json::{Value, json};
use std::{
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll},
    time::Duration,
};
use tokio_util::sync::CancellationToken;
#[derive(Clone)]
pub struct Request {
    pub path: String,
    pub key: String,
    pub body: Option<String>,
    pub cancel: CancellationToken,
}
pub struct Transport {
    pub requests: Mutex<Vec<Request>>,
    pub send: Arc<dyn Fn(Request) -> BoxFuture<'static, Result<HttpResponse>> + Send + Sync>,
}
impl Transport {
    pub fn new<F, Fut>(f: F) -> Arc<Self>
    where
        F: Fn(Request) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = Result<HttpResponse>> + Send + 'static,
    {
        Arc::new(Self {
            requests: Mutex::new(vec![]),
            send: Arc::new(move |r| Box::pin(f(r))),
        })
    }
    pub fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}
#[async_trait::async_trait]
impl HttpTransport for Transport {
    async fn request(
        &self,
        path: &str,
        key: &str,
        body: Option<String>,
        cancel: CancellationToken,
    ) -> Result<HttpResponse> {
        let r = Request {
            path: path.into(),
            key: key.into(),
            body,
            cancel,
        };
        self.requests.lock().unwrap().push(r.clone());
        (self.send)(r).await
    }
}
pub fn credentials() -> CredentialSource {
    Arc::new(|_| Box::pin(async { Ok("synthetic-test-key".into()) }))
}
pub fn provider(transport: Arc<dyn HttpTransport>) -> DeepSeekProvider {
    DeepSeekProvider::with_transport(credentials(), transport, Duration::from_secs(2)).unwrap()
}
pub fn request() -> ProviderRequest {
    ProviderRequest {
        instructions: String::new(),
        effort: Some("none".into()),
        provider_state: None,
        model: "deepseek-flash".into(),
        messages: vec![ContextMessage::User {
            text: "Hello".into(),
        }],
        tools: vec![],
        cancel: CancellationToken::new(),
    }
}
pub fn event(value: Value) -> String {
    format!(
        "data: {}\n\n",
        if let Some(s) = value.as_str() {
            s.to_owned()
        } else {
            value.to_string()
        }
    )
}
pub fn delta(value: Value, finish: Option<&str>) -> Value {
    json!({"choices":[{"index":0,"delta":value,"finish_reason":finish}]})
}
pub fn call(arguments: &str, index: usize, id: &str) -> Value {
    delta(
        json!({"tool_calls":[{"index":index,"id":id,"type":"function","function":{"name":"edit_file","arguments":arguments}}]}),
        None,
    )
}
pub fn complete(text: &str) -> String {
    event(delta(json!({"content":text}), None))
        + &event(delta(json!({}), Some("stop")))
        + &event(json!("[DONE]"))
}
struct Tracked {
    inner: ByteStream,
    dropped: Arc<AtomicBool>,
}
impl Drop for Tracked {
    fn drop(&mut self) {
        self.dropped.store(true, Ordering::SeqCst);
    }
}
impl Stream for Tracked {
    type Item = Result<Bytes>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.inner.as_mut().poll_next(cx)
    }
}
pub fn tracked(body: ByteStream, dropped: Arc<AtomicBool>) -> ByteStream {
    Box::pin(Tracked {
        inner: body,
        dropped,
    })
}
pub fn response(
    data: impl Into<Vec<u8>>,
    chunk: usize,
    keep_open: bool,
    dropped: Arc<AtomicBool>,
) -> HttpResponse {
    let data = data.into();
    let chunks: Vec<_> = data
        .chunks(chunk)
        .map(|b| Ok(Bytes::copy_from_slice(b)))
        .collect();
    let bytes: ByteStream = if keep_open {
        Box::pin(stream::iter(chunks).chain(stream::pending()))
    } else {
        Box::pin(stream::iter(chunks))
    };
    HttpResponse {
        status: 200,
        content_type: Some("text/event-stream; charset=utf-8".into()),
        body: tracked(bytes, dropped),
    }
}
pub fn wire(data: impl Into<Vec<u8>>) -> HttpResponse {
    response(data, 19, false, Arc::new(AtomicBool::new(false)))
}
pub fn json_response(value: Value) -> HttpResponse {
    let mut response = wire(value.to_string());
    response.content_type = Some("application/json".into());
    response
}
pub async fn collect(p: &DeepSeekProvider, r: ProviderRequest) -> Result<Vec<ProviderEvent>> {
    use futures_util::TryStreamExt;
    p.stream(r).try_collect().await
}
