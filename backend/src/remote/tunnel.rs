use super::crypto::{Packet, Receiver, Sender};
use super::*;
use crate::service::Host;
use axum::{
    body::{Body, to_bytes},
    http::Request,
};
use futures_util::{SinkExt, StreamExt};
use std::{
    collections::HashMap,
    sync::{Weak, atomic::Ordering},
    time::Duration,
};
use tokio::sync::mpsc;
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{Message, client::IntoClientRequest, protocol::WebSocketConfig},
};
use tokio_util::sync::CancellationToken;

#[derive(Serialize, Deserialize)]
struct Envelope {
    kind: String,
    client: String,
    #[serde(default)]
    data: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Hello {
    name: String,
    invitation: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    id: String,
    method: String,
    path: String,
    body: Option<Value>,
}
impl RemoteAccess {
    pub(crate) async fn run(self: Arc<Self>, host: Weak<Host>, stop: CancellationToken) {
        let mut changed = self.revision.subscribe();
        loop {
            let config = self.state.lock().await.config.clone();
            let attempt = async {
                if config.enabled {
                    let _ = self.connection(host.clone(), config).await;
                } else {
                    std::future::pending::<()>().await;
                }
            };
            tokio::select! { biased;
                _ = stop.cancelled() => break,
                _ = changed.changed() => {},
                _ = attempt => {
                    self.connected.store(false, Ordering::Relaxed);
                    // Reconnect only the transport. Never replay an API request.
                    tokio::select! { _ = stop.cancelled() => break, _ = changed.changed() => {}, _ = tokio::time::sleep(Duration::from_secs(3)) => {} }
                }
            }
            self.connected.store(false, Ordering::Relaxed);
        }
        self.connected.store(false, Ordering::Relaxed);
    }
    async fn connection(self: &Arc<Self>, host: Weak<Host>, config: Configuration) -> Result<()> {
        let mut request = format!("{}/v1/host", config.relay)
            .into_client_request()
            .map_err(|_| Error::Internal)?;
        request.headers_mut().insert(
            "authorization",
            format!("Bearer {}", config.host_token)
                .parse()
                .map_err(|_| Error::Internal)?,
        );
        let limits = WebSocketConfig::default()
            .max_message_size(Some(1024 * 1024))
            .max_frame_size(Some(1024 * 1024));
        let (socket, _) = tokio::time::timeout(
            Duration::from_secs(15),
            connect_async_with_config(request, Some(limits), false),
        )
        .await
        .map_err(|_| Error::Internal)?
        .map_err(|_| Error::Internal)?;
        self.connected.store(true, Ordering::Relaxed);
        let (mut sink, mut source) = socket.split();
        let (out, mut outgoing) = mpsc::channel::<Envelope>(16);
        let mut clients = HashMap::<String, mpsc::Sender<String>>::new();
        let mut tasks = tokio::task::JoinSet::new();
        let mut ping = tokio::time::interval(Duration::from_secs(20));
        let mut seen = tokio::time::Instant::now();
        loop {
            tokio::select! {
                Some(_) = tasks.join_next() => {},
                Some(frame) = outgoing.recv() => {
                    if frame.kind == "close" { clients.remove(&frame.client); }
                    let text = serde_json::to_string(&frame).map_err(|_| Error::Internal)?;
                    tokio::time::timeout(Duration::from_secs(10), sink.send(Message::Text(text.into()))).await.map_err(|_| Error::Internal)?.map_err(|_| Error::Internal)?;
                }
                _ = ping.tick() => {
                    if seen.elapsed() > Duration::from_secs(70) { return Err(Error::Internal); }
                    tokio::time::timeout(Duration::from_secs(10), sink.send(Message::Ping(vec![].into()))).await.map_err(|_| Error::Internal)?.map_err(|_| Error::Internal)?;
                }
                message = source.next() => {
                    let Some(Ok(message)) = message else { return Err(Error::Internal) }; seen = tokio::time::Instant::now();
                    match message {
                        Message::Text(text) => {
                            let frame: Envelope = serde_json::from_str(&text).map_err(|_| Error::Internal)?;
                            if frame.client.len() > 64 { return Err(Error::Internal); }
                            match frame.kind.as_str() {
                                "open" if clients.len() < 4 && !clients.contains_key(&frame.client) => {
                                    let (tx, rx) = mpsc::channel(4); clients.insert(frame.client.clone(), tx);
                                    let remote = self.clone(); let host = host.clone(); let out = out.clone(); let key = config.private_key.clone();
                                    tasks.spawn(async move {
                                        let _ = remote.client(host, &frame.client, &key, &out, rx).await;
                                        let _ = out.send(Envelope { kind:"close".into(), client:frame.client, data:String::new() }).await;
                                    });
                                }
                                "data" => { if let Some(client) = clients.get(&frame.client) { if client.try_send(frame.data).is_err() { return Err(Error::Busy); } } }
                                "close" => { clients.remove(&frame.client); }
                                _ => return Err(Error::Internal),
                            }
                        }
                        Message::Close(_) => return Ok(()),
                        Message::Ping(_) | Message::Pong(_) => {},
                        _ => return Err(Error::Internal),
                    }
                }
            }
        }
        // Dropping JoinSet aborts observers/handshakes. Accepted API mutations are
        // separately tracked by Host and settle even if the caller disappears.
    }
    async fn client(
        &self,
        host: Weak<Host>,
        id: &str,
        key: &str,
        out: &mpsc::Sender<Envelope>,
        mut incoming: mpsc::Receiver<String>,
    ) -> Result<()> {
        let challenge = random();
        send(out, id, json!({"challenge":challenge,"version":1})).await?;
        let first = tokio::time::timeout(Duration::from_secs(20), incoming.recv())
            .await
            .map_err(|_| Error::Internal)?
            .ok_or(Error::Internal)?;
        let packet: Packet = serde_json::from_str(&first).map_err(|_| Error::Internal)?;
        let peer = packet.public_key.ok_or(Error::Internal)?;
        let mut receiver: Receiver = crypto::receiver(
            key,
            &peer,
            &packet.encapsulated_key.ok_or(Error::Internal)?,
            &challenge,
            "client",
        )?;
        let hello: Hello =
            serde_json::from_slice(&crypto::open(&mut receiver, &packet.ciphertext)?)
                .map_err(|_| Error::Internal)?;
        let device = self
            .authorize_device(&peer, hello.invitation.as_deref(), &hello.name)
            .await?;
        let (enc, mut sender) = crypto::sender(key, &peer, &challenge, "host")?;
        let ready = crypto::seal(
            &mut sender,
            &serde_json::to_vec(&json!({"ready":true,"deviceID":device})).unwrap(),
        )?;
        send(
            out,
            id,
            serde_json::to_value(Packet {
                ciphertext: ready,
                encapsulated_key: Some(enc),
                public_key: None,
            })
            .unwrap(),
        )
        .await?;
        while let Some(text) = incoming.recv().await {
            if text.len() > 300_000 || !self.device_exists(&device).await {
                return Err(Error::Internal);
            }
            let packet: Packet = serde_json::from_str(&text).map_err(|_| Error::Internal)?;
            if packet.encapsulated_key.is_some() || packet.public_key.is_some() {
                return Err(Error::Internal);
            }
            let command: Command =
                serde_json::from_slice(&crypto::open(&mut receiver, &packet.ciphertext)?)
                    .map_err(|_| Error::Internal)?;
            if uuid::Uuid::parse_str(&command.id).is_err() {
                return Err(Error::Internal);
            }
            let host = host.upgrade().ok_or(Error::Internal)?;
            let body = command
                .body
                .map(|v| serde_json::to_vec(&v).unwrap())
                .unwrap_or_default();
            let request = Request::builder()
                .method(command.method.as_str())
                .uri(&command.path)
                .header("content-type", "application/json")
                .body(Body::from(body))
                .map_err(|_| Error::Internal)?;
            let response = crate::service::remote_request(host, request).await;
            let status = response.status().as_u16();
            let bytes = to_bytes(response.into_body(), 32 * 1024 * 1024)
                .await
                .map_err(|_| Error::Internal)?;
            // Fragment large snapshots; bound both broker queues and Swift reassembly.
            if bytes.is_empty() {
                reply(out, id, &mut sender, &command.id, status, &[], true).await?;
            } else {
                let count = bytes.len().div_ceil(48 * 1024);
                for (index, chunk) in bytes.chunks(48 * 1024).enumerate() {
                    reply(
                        out,
                        id,
                        &mut sender,
                        &command.id,
                        status,
                        chunk,
                        index + 1 == count,
                    )
                    .await?;
                }
            }
        }
        Ok(())
    }
}
async fn send(out: &mpsc::Sender<Envelope>, client: &str, data: Value) -> Result<()> {
    tokio::time::timeout(
        Duration::from_secs(10),
        out.send(Envelope {
            kind: "data".into(),
            client: client.into(),
            data: data.to_string(),
        }),
    )
    .await
    .map_err(|_| Error::Internal)?
    .map_err(|_| Error::Internal)
}
async fn reply(
    out: &mpsc::Sender<Envelope>,
    client: &str,
    sender: &mut Sender,
    id: &str,
    status: u16,
    body: &[u8],
    done: bool,
) -> Result<()> {
    let value = json!({"id":id,"status":status,"body":crypto::encode(body),"done":done});
    send(
        out,
        client,
        serde_json::to_value(Packet {
            ciphertext: crypto::seal(sender, &serde_json::to_vec(&value).unwrap())?,
            encapsulated_key: None,
            public_key: None,
        })
        .unwrap(),
    )
    .await
}
