use super::crypto::{Packet, Receiver, Sender};
use super::*;
use crate::{core::ChangeNotification, service::Host};
use axum::{
    body::{Body, to_bytes},
    http::Request,
};
use futures_util::{SinkExt, StreamExt};
use std::{
    collections::HashMap,
    sync::{OnceLock, Weak},
    time::Duration,
};
use tokio::sync::mpsc;
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{Message, client::IntoClientRequest, protocol::WebSocketConfig},
};
use tokio_util::sync::CancellationToken;

const MAX_FRAME: usize = 1024 * 1024;

#[derive(Serialize, Deserialize)]
struct Envelope {
    kind: String,
    client: String,
    #[serde(default)]
    data: String,
}
impl Envelope {
    fn close(client: String) -> Self {
        Self {
            kind: "close".into(),
            client,
            data: String::new(),
        }
    }
    fn text(&self) -> Result<String> {
        let text = serde_json::to_string(self).map_err(|_| Error::Internal)?;
        if text.len() > MAX_FRAME {
            return Err(Error::Invalid("Remote frame is too large."));
        }
        Ok(text)
    }
}
struct ClientFrame {
    envelope: Envelope,
    device: Arc<OnceLock<String>>,
}
struct ClientOutput {
    client: String,
    device: Arc<OnceLock<String>>,
    frames: mpsc::Sender<ClientFrame>,
}
impl ClientOutput {
    fn new(client: String, frames: mpsc::Sender<ClientFrame>) -> Self {
        Self {
            client,
            device: Arc::default(),
            frames,
        }
    }
    async fn enqueue(&self, envelope: Envelope) -> Result<()> {
        envelope.text()?;
        tokio::time::timeout(
            Duration::from_secs(10),
            self.frames.send(ClientFrame {
                envelope,
                device: self.device.clone(),
            }),
        )
        .await
        .map_err(|_| Error::Internal)?
        .map_err(|_| Error::Internal)
    }
}
struct Client {
    incoming: mpsc::Sender<String>,
    task: tokio::task::AbortHandle,
    // Published before ready is queued, so revocation also gates queued output
    // and can abort a busy client without closing the shared host socket.
    device: Arc<OnceLock<String>>,
}
impl Client {
    fn is_revoked(&self, config: &Configuration) -> bool {
        !config.enabled
            || self
                .device
                .get()
                .is_some_and(|id| !config.devices.iter().any(|device| device.id == *id))
    }
    fn owns(&self, frame: &ClientFrame) -> bool {
        // A relay may reuse a client ID. Never deliver an old session's queued
        // data/close to its replacement, even when the device key is the same.
        Arc::ptr_eq(&self.device, &frame.device)
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        // Stop buffered commands/handshakes immediately, but not separately
        // tracked accepted API or pairing transactions.
        self.task.abort();
    }
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
// One watch value per opted-in client, not an event/HTTP-body queue. No task owns
// a second HPKE sender: replies and notices are sealed by the client loop below.
struct ChangeObserver {
    changes: watch::Receiver<ChangeNotification>,
    next_notice: tokio::time::Instant,
    heartbeat: tokio::time::Instant,
}
impl ChangeObserver {
    fn new(mut changes: watch::Receiver<ChangeNotification>) -> (Self, ChangeNotification) {
        let initial = changes.borrow_and_update().clone();
        let now = tokio::time::Instant::now();
        (
            Self {
                changes,
                next_notice: now + Duration::from_millis(200),
                heartbeat: now + Duration::from_secs(20),
            },
            initial,
        )
    }
    async fn next(&mut self) -> Result<ChangeNotification> {
        // Cancellation-safe: the watch value is consumed only when this branch wins.
        tokio::time::sleep_until(self.next_notice).await;
        tokio::select! {
            result = self.changes.changed() => { result.map_err(|_| Error::Internal)?; }
            _ = tokio::time::sleep_until(self.heartbeat) => {}
        }
        let value = self.changes.borrow_and_update().clone();
        let now = tokio::time::Instant::now();
        self.next_notice = now + Duration::from_millis(200);
        self.heartbeat = now + Duration::from_secs(20);
        Ok(value)
    }
}
async fn next_notice(observation: &mut Option<ChangeObserver>) -> Result<ChangeNotification> {
    match observation {
        Some(observation) => observation.next().await,
        None => std::future::pending().await,
    }
}

impl RemoteAccess {
    async fn set_connection(&self, revision: u64, connection: ConnectionStatus) {
        let mut state = self.state.lock().await;
        if *self.revision.borrow() == revision && state.config.enabled {
            state.connection = connection;
        }
    }
    async fn authorized_output(
        &self,
        output: ClientFrame,
        clients: &mut HashMap<String, Client>,
    ) -> Option<Envelope> {
        let client = clients
            .get(&output.envelope.client)
            .filter(|client| client.owns(&output))?;
        // Challenges/rejections must not wait behind a pairing write.
        if let Some(device) = client.device.get()
            && !self.device_exists(device).await
        {
            clients.remove(&output.envelope.client);
            return Some(Envelope::close(output.envelope.client));
        }
        let frame = output.envelope;
        if frame.kind == "close" {
            clients.remove(&frame.client);
        }
        Some(frame)
    }
    pub(crate) async fn run(self: Arc<Self>, host: Weak<Host>, stop: CancellationToken) {
        let mut changed = self.revision.subscribe();
        loop {
            let (config, revision) = {
                let mut state = self.state.lock().await;
                state.connection = if state.config.enabled {
                    ConnectionStatus::Connecting
                } else {
                    ConnectionStatus::Disconnected
                };
                (state.config.clone(), *changed.borrow_and_update())
            };
            let attempt = async {
                if config.enabled {
                    let _ = self.connection(host.clone(), config, revision).await;
                    let mut state = self.state.lock().await;
                    if *self.revision.borrow() == revision && state.config.enabled {
                        state.connection = if state.connection == ConnectionStatus::Connecting {
                            ConnectionStatus::RelayNotFound
                        } else {
                            ConnectionStatus::Disconnected
                        };
                    }
                } else {
                    std::future::pending::<()>().await;
                }
            };
            tokio::select! { biased;
                _ = stop.cancelled() => break,
                _ = changed.changed() => {},
                _ = attempt => {
                    // Reconnect only the transport. Never replay an API request.
                    tokio::select! { _ = stop.cancelled() => break, _ = changed.changed() => {}, _ = tokio::time::sleep(Duration::from_secs(3)) => {} }
                }
            }
        }
        // The connection future (and its JoinSet) has been dropped before this
        // drain. Accepted pairing writes keep their lock until memory settles.
        self.transactions.close();
        self.transactions.wait().await;
        self.state.lock().await.connection = ConnectionStatus::Disconnected;
    }
    async fn connection(
        self: &Arc<Self>,
        host: Weak<Host>,
        config: Configuration,
        revision: u64,
    ) -> Result<()> {
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
            .max_message_size(Some(MAX_FRAME))
            .max_frame_size(Some(MAX_FRAME));
        let (socket, _) = tokio::time::timeout(
            Duration::from_secs(15),
            connect_async_with_config(request, Some(limits), false),
        )
        .await
        .map_err(|_| Error::Internal)?
        .map_err(|_| Error::Internal)?;
        self.set_connection(revision, ConnectionStatus::Connected)
            .await;
        let (mut sink, mut source) = socket.split();
        let (out, mut outgoing) = mpsc::channel::<ClientFrame>(16);
        let mut authorization = self.authorization_revision.subscribe();
        let mut clients = HashMap::<String, Client>::new();
        let mut tasks = tokio::task::JoinSet::new();
        let mut ping = tokio::time::interval(Duration::from_secs(20));
        let mut seen = tokio::time::Instant::now();
        loop {
            tokio::select! {
                _ = authorization.changed() => {
                    let revoked = {
                        let state = self.state.lock().await;
                        clients.iter().filter_map(|(id, client)| {
                            client.is_revoked(&state.config).then_some(id.clone())
                        }).collect::<Vec<_>>()
                    };
                    for id in revoked {
                        clients.remove(&id);
                        write(&mut sink, Message::Text(Envelope::close(id).text()?.into())).await?;
                    }
                }
                Some(_) = tasks.join_next() => {},
                Some(queued) = outgoing.recv() => {
                    // Recheck at egress, even before the revocation watcher runs.
                    let Some(frame) = self.authorized_output(queued, &mut clients).await else { continue; };
                    let text = match frame.text() {
                        Ok(text) => text,
                        Err(_) => {
                            clients.remove(&frame.client);
                            Envelope::close(frame.client).text()?
                        }
                    };
                    write(&mut sink, Message::Text(text.into())).await?;
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
                                "open" if clients.len() < MAX_CLIENTS && !clients.contains_key(&frame.client) => {
                                    let (tx, rx) = mpsc::channel(4);
                                    let remote = self.clone(); let host = host.clone(); let key = config.private_key.clone();
                                    let out = ClientOutput::new(frame.client.clone(), out.clone());
                                    let device = out.device.clone();
                                    let task = tasks.spawn(async move {
                                        let _ = remote.client(host, &key, &out, rx).await;
                                        let _ = out.enqueue(Envelope::close(out.client.clone())).await;
                                    });
                                    clients.insert(frame.client, Client { incoming: tx, task, device });
                                }
                                "data" => {
                                    if let Some(client) = clients.get(&frame.client)
                                        && client.incoming.try_send(frame.data).is_err()
                                    {
                                        // Backpressure belongs to this peer, not to the
                                        // shared host socket and all its other clients.
                                        clients.remove(&frame.client);
                                        write(&mut sink, Message::Text(Envelope::close(frame.client).text()?.into())).await?;
                                    }
                                }
                                "close" => { clients.remove(&frame.client); }
                                "open" => {
                                    clients.remove(&frame.client);
                                    write(&mut sink, Message::Text(Envelope::close(frame.client).text()?.into())).await?;
                                }
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
        // Dropping JoinSet aborts observers/handshakes. Accepted API and pairing
        // mutations are separately tracked and settle if the socket disappears.
    }
    async fn client(
        self: &Arc<Self>,
        host: Weak<Host>,
        key: &str,
        out: &ClientOutput,
        mut incoming: mpsc::Receiver<String>,
    ) -> Result<()> {
        let mut authorization = self.authorization_revision.subscribe();
        let challenge = random();
        send(
            out,
            json!({"challenge":challenge,"version":crypto::VERSION}),
        )
        .await?;
        let first = tokio::time::timeout(Duration::from_secs(20), incoming.recv())
            .await
            .map_err(|_| Error::Internal)?
            .ok_or(Error::Internal)?;
        let packet: Packet = serde_json::from_str(&first).map_err(|_| Error::Internal)?;
        let peer = packet.public_key.ok_or(Error::Internal)?;
        let client_encapsulated = packet.encapsulated_key.ok_or(Error::Internal)?;
        let mut receiver: Receiver =
            crypto::receiver(key, &peer, &client_encapsulated, &challenge, "client")?;
        let hello: Hello =
            serde_json::from_slice(&crypto::open(&mut receiver, &packet.ciphertext)?)
                .map_err(|_| Error::Internal)?;
        let device = self
            .authorize_device(&peer, hello.invitation.as_deref(), &hello.name)
            .await?;
        out.device
            .set(device.clone())
            .map_err(|_| Error::Internal)?;
        let response_context = crypto::response_context(&challenge, &client_encapsulated);
        let (enc, mut sender) = crypto::sender(key, &peer, &response_context, "host")?;
        let ready = crypto::seal(
            &mut sender,
            &serde_json::to_vec(
                &json!({"ready":true,"version":crypto::VERSION,"deviceID":device,"changeNotifications":true}),
            )
            .unwrap(),
        )?;
        send(
            out,
            serde_json::to_value(Packet {
                ciphertext: ready,
                encapsulated_key: Some(enc),
                public_key: None,
            })
            .unwrap(),
        )
        .await?;
        let mut observation = None;
        loop {
            // Discard buffered commands after a peer closes; never start a new mutation.
            if incoming.is_closed() {
                break;
            }
            let text = tokio::select! { biased;
                // Keep unrelated devices' HPKE contexts and subscriptions intact.
                _ = authorization.changed() => {
                    if !self.device_exists(&device).await { return Err(Error::Internal); }
                    continue;
                },
                notice = next_notice(&mut observation) => {
                    if incoming.is_closed() || !self.device_exists(&device).await { break; }
                    let value = serde_json::to_vec(&json!({"notification": notice?}))
                        .map_err(|_| Error::Internal)?;
                    // Unfragmented notices must fit the relay's 1 MiB frame limit,
                    // including base64/envelope overhead. Oversize fails closed.
                    if value.len() > 512 * 1024 { return Err(Error::Internal); }
                    encrypted(out, &mut sender, &value).await?;
                    continue;
                }
                text = incoming.recv() => {
                    let Some(text) = text else { break; };
                    text
                }
            };
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
            let (status, bytes) = if command.method == "GET"
                && command.path == "/v1/changes/subscribe"
            {
                // Register BEFORE reading/responding. A change during the initial
                // reply remains in the watch slot and cannot fall through a gap.
                let (observer, initial) = ChangeObserver::new(host.subscribe_changes());
                observation = Some(observer);
                (
                    200,
                    bytes::Bytes::from(serde_json::to_vec(&initial).map_err(|_| Error::Internal)?),
                )
            } else {
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
                // No wait-for-change in the request path. Busy requests simply
                // coalesce watch updates until their complete reply is sealed.
                let response = crate::service::remote_request(host, request).await;
                let status = response.status().as_u16();
                let bytes = to_bytes(response.into_body(), 32 * 1024 * 1024)
                    .await
                    .map_err(|_| Error::Internal)?;
                (status, bytes)
            };
            if incoming.is_closed() || !self.device_exists(&device).await {
                break;
            }
            reply_body(out, &mut sender, &command.id, status, &bytes).await?;
        }
        Ok(())
    }
}
async fn write<S>(sink: &mut S, message: Message) -> Result<()>
where
    S: futures_util::Sink<Message> + Unpin,
{
    tokio::time::timeout(Duration::from_secs(10), sink.send(message))
        .await
        .map_err(|_| Error::Internal)?
        .map_err(|_| Error::Internal)
}
async fn send(out: &ClientOutput, data: Value) -> Result<()> {
    out.enqueue(Envelope {
        kind: "data".into(),
        client: out.client.clone(),
        data: data.to_string(),
    })
    .await
}
async fn reply_body(
    out: &ClientOutput,
    sender: &mut Sender,
    id: &str,
    status: u16,
    bytes: &[u8],
) -> Result<()> {
    if bytes.len() > 32 * 1024 * 1024 {
        return Err(Error::Internal);
    }
    if bytes.is_empty() {
        return reply(out, sender, id, status, &[], true).await;
    }
    let count = bytes.len().div_ceil(48 * 1024);
    for (index, chunk) in bytes.chunks(48 * 1024).enumerate() {
        reply(out, sender, id, status, chunk, index + 1 == count).await?;
    }
    Ok(())
}
async fn reply(
    out: &ClientOutput,
    sender: &mut Sender,
    id: &str,
    status: u16,
    body: &[u8],
    done: bool,
) -> Result<()> {
    let value = json!({"id":id,"status":status,"body":crypto::encode(body),"done":done});
    encrypted(out, sender, &serde_json::to_vec(&value).unwrap()).await
}
async fn encrypted(out: &ClientOutput, sender: &mut Sender, plaintext: &[u8]) -> Result<()> {
    send(
        out,
        serde_json::to_value(Packet {
            ciphertext: crypto::seal(sender, plaintext)?,
            encapsulated_key: None,
            public_key: None,
        })
        .unwrap(),
    )
    .await
}

#[cfg(test)]
#[path = "tunnel_tests.rs"]
mod connection_tests;

#[cfg(test)]
mod tests {
    use super::*;

    fn change(revision: &str) -> ChangeNotification {
        ChangeNotification {
            epoch: "epoch".into(),
            catalog: revision.into(),
            conversations: [("session".into(), revision.into())].into(),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn observation_registers_before_initial_reply_coalesces_and_heartbeats() {
        let (tx, rx) = watch::channel(change("0"));
        let (mut observer, initial) = ChangeObserver::new(rx);
        assert_eq!(initial.catalog, "0");
        // A burst while the initial/ordinary reply is in progress retains one value.
        for revision in 1..=100 {
            tx.send_replace(change(&revision.to_string()));
        }
        let start = tokio::time::Instant::now();
        assert!(
            tokio::time::timeout(Duration::from_millis(199), observer.next())
                .await
                .is_err()
        );
        assert_eq!(observer.next().await.unwrap().catalog, "100");
        assert!(start.elapsed() >= Duration::from_millis(200));
        tx.send_replace(change("101"));
        let start = tokio::time::Instant::now();
        assert_eq!(observer.next().await.unwrap().catalog, "101");
        assert!(start.elapsed() >= Duration::from_millis(200));
        let start = tokio::time::Instant::now();
        assert_eq!(observer.next().await.unwrap().catalog, "101");
        assert!(start.elapsed() >= Duration::from_secs(20));
        drop(tx);
        assert!(observer.next().await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn waiting_for_change_does_not_hold_an_ordinary_command() {
        let (tx, rx) = watch::channel(change("0"));
        let (observer, _) = ChangeObserver::new(rx);
        let mut observation = Some(observer);
        tokio::select! {
            _ = next_notice(&mut observation) => panic!("notice must not precede command"),
            _ = tokio::time::sleep(Duration::from_millis(1)) => {},
        }
        // Losing the select must not consume a future revision.
        tx.send_replace(change("1"));
        assert_eq!(next_notice(&mut observation).await.unwrap().catalog, "1");
        let mut unregistered = None;
        assert!(
            tokio::time::timeout(Duration::from_secs(60), next_notice(&mut unregistered))
                .await
                .is_err()
        );
        drop(observation);
        assert_eq!(tx.receiver_count(), 0);
    }

    #[tokio::test]
    async fn fragments_errors_and_notices_share_one_ordered_hpke_context() {
        let (private, public) = crypto::keypair();
        let (peer_private, peer_public) = crypto::keypair();
        let (enc, mut sender) =
            crypto::sender(&private, &peer_public, "challenge", "host").unwrap();
        let mut receiver =
            crypto::receiver(&peer_private, &public, &enc, "challenge", "host").unwrap();
        let (out, mut frames) = mpsc::channel(16);
        let out = ClientOutput::new("client".into(), out);
        let id = uuid::Uuid::new_v4().to_string();
        let body = vec![b'x'; 48 * 1024 + 10];
        reply_body(&out, &mut sender, &id, 200, &body)
            .await
            .unwrap();
        encrypted(
            &out,
            &mut sender,
            &serde_json::to_vec(&json!({"notification": change("1")})).unwrap(),
        )
        .await
        .unwrap();
        reply_body(&out, &mut sender, &id, 403, b"{}")
            .await
            .unwrap();
        reply_body(&out, &mut sender, &id, 200, b"{}")
            .await
            .unwrap();
        for index in 0..5 {
            let envelope = frames.recv().await.unwrap().envelope;
            assert_eq!(envelope.client, "client");
            let packet: Packet = serde_json::from_str(&envelope.data).unwrap();
            assert!(packet.encapsulated_key.is_none());
            let value: Value =
                serde_json::from_slice(&crypto::open(&mut receiver, &packet.ciphertext).unwrap())
                    .unwrap();
            if index == 2 {
                assert_eq!(value, json!({"notification": change("1")}));
                assert!(value.get("body").is_none());
            } else {
                assert_eq!(value["id"], id);
                assert_eq!(value["done"], index != 0);
                assert_eq!(value["status"], if index == 3 { 403 } else { 200 });
                if index == 0 {
                    assert_eq!(
                        crypto::decode(value["body"].as_str().unwrap())
                            .unwrap()
                            .len(),
                        48 * 1024
                    );
                }
                if index == 1 {
                    assert_eq!(
                        crypto::decode(value["body"].as_str().unwrap())
                            .unwrap()
                            .len(),
                        10
                    );
                }
            }
        }
    }

    // Exercise the real authenticated client loop without a websocket/Host/provider.
    // Unsubscribed v2 clients remain silent; closure and revocation end the loop.
    async fn idle_client(revoke: bool) {
        let directory = tempfile::tempdir().unwrap();
        let remote = RemoteAccess::load(directory.path()).await.unwrap();
        let (peer_private, peer_public) = crypto::keypair();
        let device = uuid::Uuid::new_v4().to_string();
        let key = {
            let mut state = remote.state.lock().await;
            state.config.enabled = true;
            state.config.devices.push(Device {
                id: device.clone(),
                name: "fixture".into(),
                public_key: peer_public.clone(),
            });
            state.config.private_key.clone()
        };
        let public = crypto::public_key(&key).unwrap();
        let (out, mut frames) = mpsc::channel(16);
        let out = ClientOutput::new("client".into(), out);
        let (input, incoming) = mpsc::channel(4);
        let task = {
            let remote = remote.clone();
            tokio::spawn(async move { remote.client(Weak::new(), &key, &out, incoming).await })
        };
        let challenge: Value =
            serde_json::from_str(&frames.recv().await.unwrap().envelope.data).unwrap();
        assert!(challenge.get("changeNotifications").is_none());
        let challenge = challenge["challenge"].as_str().unwrap();
        let (enc, mut sender) =
            crypto::sender(&peer_private, &public, challenge, "client").unwrap();
        let response_context = crypto::response_context(challenge, &enc);
        let hello = crypto::seal(&mut sender, br#"{"name":"fixture"}"#).unwrap();
        input
            .send(
                serde_json::to_string(&Packet {
                    ciphertext: hello,
                    encapsulated_key: Some(enc),
                    public_key: Some(peer_public),
                })
                .unwrap(),
            )
            .await
            .unwrap();
        let packet: Packet =
            serde_json::from_str(&frames.recv().await.unwrap().envelope.data).unwrap();
        let mut receiver = crypto::receiver(
            &peer_private,
            &public,
            packet.encapsulated_key.as_ref().unwrap(),
            &response_context,
            "host",
        )
        .unwrap();
        let ready: Value =
            serde_json::from_slice(&crypto::open(&mut receiver, &packet.ciphertext).unwrap())
                .unwrap();
        assert_eq!(ready["ready"], true);
        // Capability is authenticated inside ready, never an unauthenticated
        // challenge flag. Unsubscribed clients receive no unsolicited notices.
        assert_eq!(ready["changeNotifications"], true);
        assert!(
            tokio::time::timeout(Duration::from_secs(21), frames.recv())
                .await
                .is_err()
        );
        if revoke {
            remote.revoke(&device).await.unwrap();
            assert!(task.await.unwrap().is_err());
        } else {
            drop(input);
            assert!(task.await.unwrap().is_ok());
        }
    }
    #[tokio::test(start_paused = true)]
    async fn unsubscribed_client_has_no_notices_and_disconnect_ends_observation() {
        idle_client(false).await;
    }
    #[tokio::test(start_paused = true)]
    async fn revocation_closes_an_idle_authenticated_client() {
        idle_client(true).await;
    }
}
