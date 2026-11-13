//! A bounded, ephemeral WebSocket switch. Payloads are opaque to this process.
use axum::{
    Router,
    extract::{
        Path, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::get,
};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::mpsc;

const MAX_FRAME: usize = 1024 * 1024;
const MAX_HOSTS: usize = 64;
const MAX_CLIENTS: usize = 4;
type Outbox = mpsc::Sender<Message>;
#[derive(Default)]
struct Host {
    sender: Option<Outbox>,
    clients: HashMap<String, Outbox>,
}
#[derive(Default)]
pub struct Broker {
    hosts: Mutex<HashMap<String, Host>>,
}
#[derive(Serialize, Deserialize)]
struct Envelope {
    kind: String,
    client: String,
    #[serde(default)]
    data: String,
}
fn envelope(kind: &str, client: &str, data: String) -> Message {
    Message::Text(
        serde_json::to_string(&Envelope {
            kind: kind.into(),
            client: client.into(),
            data,
        })
        .unwrap()
        .into(),
    )
}
pub fn router() -> Router {
    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/host", get(host_upgrade))
        .route("/v1/client/{route}", get(client_upgrade))
        .with_state(Arc::new(Broker::default()))
}
async fn host_upgrade(
    State(state): State<Arc<Broker>>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    // The route is SHA-256 of the private host credential. Knowing a route does
    // not let a caller take over the host socket. Credentials never enter URLs.
    let mut auth = headers.get_all("authorization").iter();
    let token = auth
        .next()
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    let Some(token) = token.filter(|v| {
        v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()) && auth.next().is_none()
    }) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let route = format!("{:x}", Sha256::digest(token.as_bytes()));
    {
        let mut hosts = state.hosts.lock().unwrap();
        if hosts.contains_key(&route) {
            return StatusCode::CONFLICT.into_response();
        }
        if hosts.len() >= MAX_HOSTS {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
        hosts.insert(route.clone(), Host::default());
    }
    // A failed upgrade must release its reservation, too.
    let failure_state = state.clone();
    let failure_route = route.clone();
    ws.max_message_size(MAX_FRAME)
        .max_frame_size(MAX_FRAME)
        .on_failed_upgrade(move |_| {
            failure_state.hosts.lock().unwrap().remove(&failure_route);
        })
        .on_upgrade(move |socket| host_socket(state, route, socket))
        .into_response()
}
async fn client_upgrade(
    State(state): State<Arc<Broker>>,
    Path(route): Path<String>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = mpsc::channel(8);
    {
        let mut hosts = state.hosts.lock().unwrap();
        let Some(host) = hosts.get_mut(&route) else {
            return StatusCode::NOT_FOUND.into_response();
        };
        if host.sender.is_none() || host.clients.len() >= MAX_CLIENTS {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
        host.clients.insert(id.clone(), tx);
    }
    let failure_state = state.clone();
    let failure_route = route.clone();
    let failure_id = id.clone();
    ws.max_message_size(MAX_FRAME)
        .max_frame_size(MAX_FRAME)
        .on_failed_upgrade(move |_| {
            if let Some(h) = failure_state.hosts.lock().unwrap().get_mut(&failure_route) {
                h.clients.remove(&failure_id);
            }
        })
        .on_upgrade(move |socket| client_socket(state, route, id, socket, rx))
        .into_response()
}
async fn host_socket(state: Arc<Broker>, route: String, socket: WebSocket) {
    let (tx, mut rx) = mpsc::channel(32);
    state.hosts.lock().unwrap().get_mut(&route).unwrap().sender = Some(tx);
    let (mut sink, mut source) = socket.split();
    let mut ping = tokio::time::interval(Duration::from_secs(20));
    let mut last_seen = tokio::time::Instant::now();
    loop {
        tokio::select! {
            msg = rx.recv() => { let Some(msg) = msg else { break }; if send(&mut sink, msg).await.is_err() { break; } }
            _ = ping.tick() => {
                if last_seen.elapsed() > Duration::from_secs(70) || send(&mut sink, Message::Ping(vec![].into())).await.is_err() { break; }
            }
            msg = source.next() => {
                let Some(Ok(msg)) = msg else { break }; last_seen = tokio::time::Instant::now();
                match msg {
                    Message::Text(text) => {
                        let Ok(frame) = serde_json::from_str::<Envelope>(&text) else { break };
                        let mut hosts = state.hosts.lock().unwrap();
                        let Some(host) = hosts.get_mut(&route) else { break };
                        if frame.kind == "close" { host.clients.remove(&frame.client); }
                        else if frame.kind == "data" {
                            if let Some(client) = host.clients.get(&frame.client) {
                                if client.try_send(Message::Text(frame.data.into())).is_err() { host.clients.remove(&frame.client); }
                            }
                        } else { break; }
                    }
                    Message::Close(_) => break,
                    Message::Ping(_) | Message::Pong(_) => {},
                    _ => break,
                }
            }
        }
    }
    // No durable queue: disconnecting the host closes every attached client.
    state.hosts.lock().unwrap().remove(&route);
}
async fn client_socket(
    state: Arc<Broker>,
    route: String,
    id: String,
    socket: WebSocket,
    mut rx: mpsc::Receiver<Message>,
) {
    let host = state
        .hosts
        .lock()
        .unwrap()
        .get(&route)
        .and_then(|h| h.sender.clone());
    let Some(host) = host else { return };
    if host.try_send(envelope("open", &id, String::new())).is_err() {
        if let Some(h) = state.hosts.lock().unwrap().get_mut(&route) {
            h.clients.remove(&id);
        }
        return;
    }
    let (mut sink, mut source) = socket.split();
    let mut ping = tokio::time::interval(Duration::from_secs(20));
    let mut last_seen = tokio::time::Instant::now();
    loop {
        tokio::select! {
            msg = rx.recv() => { let Some(msg) = msg else { break }; if send(&mut sink, msg).await.is_err() { break; } }
            _ = ping.tick() => {
                if last_seen.elapsed() > Duration::from_secs(70) || send(&mut sink, Message::Ping(vec![].into())).await.is_err() { break; }
            }
            msg = source.next() => {
                let Some(Ok(msg)) = msg else { break }; last_seen = tokio::time::Instant::now();
                match msg {
                    Message::Text(text) => { if host.try_send(envelope("data", &id, text.to_string())).is_err() { break; } }
                    Message::Close(_) => break,
                    Message::Ping(_) | Message::Pong(_) => {},
                    _ => break,
                }
            }
        }
    }
    if let Some(h) = state.hosts.lock().unwrap().get_mut(&route) {
        h.clients.remove(&id);
    }
    let _ = host.try_send(envelope("close", &id, String::new()));
    let _ = send(&mut sink, Message::Close(None)).await;
}
async fn send<S>(sink: &mut S, message: Message) -> Result<(), ()>
where
    S: futures_util::Sink<Message> + Unpin,
{
    tokio::time::timeout(Duration::from_secs(10), sink.send(message))
        .await
        .map_err(|_| ())?
        .map_err(|_| ())
}
