//! Synthetic relay sockets exercise the real host connector, without a provider.
use super::*;
use crate::remote::WritePause;
use tokio_tungstenite::{WebSocketStream, accept_async};

struct Fixture {
    directory: tempfile::TempDir,
    remote: Arc<RemoteAccess>,
    socket: WebSocketStream<tokio::net::TcpStream>,
    stop: CancellationToken,
    runner: tokio::task::JoinHandle<()>,
}
impl Fixture {
    async fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let remote = RemoteAccess::load(directory.path()).await.unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        remote
            .configure(Configure {
                relay: format!("ws://{}", listener.local_addr().unwrap()),
                enabled: true,
                local_development: true,
            })
            .await
            .unwrap();
        let stop = CancellationToken::new();
        let runner = tokio::spawn(remote.clone().run(Weak::new(), stop.clone()));
        let (socket, _) = listener.accept().await.unwrap();
        let socket = accept_async(socket).await.unwrap();
        Self {
            directory,
            remote,
            socket,
            stop,
            runner,
        }
    }
    async fn send(&mut self, kind: &str, id: &str, data: String) {
        self.socket
            .send(Message::Text(
                serde_json::to_string(&Envelope {
                    kind: kind.into(),
                    client: id.into(),
                    data,
                })
                .unwrap()
                .into(),
            ))
            .await
            .unwrap();
    }
    async fn frame(&mut self) -> Envelope {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                match self.socket.next().await.unwrap().unwrap() {
                    Message::Text(text) => {
                        assert!(text.len() <= MAX_FRAME);
                        return serde_json::from_str(&text).unwrap();
                    }
                    Message::Ping(_) | Message::Pong(_) => {}
                    other => panic!("unexpected host frame: {other:?}"),
                }
            }
        })
        .await
        .unwrap()
    }
    async fn open(&mut self, id: &str) -> String {
        self.send("open", id, String::new()).await;
        let frame = self.frame().await;
        assert_eq!(frame.kind, "data");
        assert_eq!(frame.client, id);
        let challenge: Value = serde_json::from_str(&frame.data).unwrap();
        assert_eq!(challenge["version"], crypto::VERSION);
        challenge["challenge"].as_str().unwrap().to_owned()
    }
    async fn hello(
        &mut self,
        id: &str,
        private: &str,
        challenge: &str,
        invitation: Option<&str>,
    ) -> String {
        let public = crypto::public_key(private).unwrap();
        let host = crypto::public_key(&self.remote.state.lock().await.config.private_key).unwrap();
        let (enc, mut sender) = crypto::sender(private, &host, challenge, "client").unwrap();
        let ciphertext = crypto::seal(
            &mut sender,
            &serde_json::to_vec(&json!({
                "name":"fixture", "invitation":invitation,
            }))
            .unwrap(),
        )
        .unwrap();
        self.send(
            "data",
            id,
            serde_json::to_string(&Packet {
                ciphertext,
                encapsulated_key: Some(enc.clone()),
                public_key: Some(public),
            })
            .unwrap(),
        )
        .await;
        crypto::response_context(challenge, &enc)
    }
    fn pause_next_write(&self) -> Arc<WritePause> {
        let pause = Arc::new(WritePause::default());
        *self.remote.write_pause.lock().unwrap() = Some(pause.clone());
        pause
    }
    fn pending_device(&self) -> String {
        let temporary = std::fs::read_dir(self.directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| path.extension().is_some_and(|extension| extension == "tmp"))
            .expect("delayed atomic configuration replacement");
        let config: Configuration =
            serde_json::from_slice(&std::fs::read(temporary).unwrap()).unwrap();
        config.devices.last().unwrap().id.clone()
    }
    async fn finish(self) {
        self.stop.cancel();
        tokio::time::timeout(Duration::from_secs(3), self.runner)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn client_queue_overflow_closes_only_that_client_and_aborts_its_buffer() {
    let mut fixture = Fixture::new().await;
    let (good, good_public) = crypto::keypair();
    let invitation = fixture.remote.invite().await.unwrap();
    fixture
        .remote
        .authorize_device(&good_public, invitation["secret"].as_str(), "good")
        .await
        .unwrap();
    let good_challenge = fixture.open("good").await;
    // Prepare good's response before delaying bad's write (the state lock must
    // remain held throughout that write).
    let host_key =
        crypto::public_key(&fixture.remote.state.lock().await.config.private_key).unwrap();
    let (good_enc, mut good_sender) =
        crypto::sender(&good, &host_key, &good_challenge, "client").unwrap();
    let good_hello = Packet {
        ciphertext: crypto::seal(&mut good_sender, br#"{"name":"good"}"#).unwrap(),
        encapsulated_key: Some(good_enc.clone()),
        public_key: Some(good_public),
    };
    let (bad, _) = crypto::keypair();
    let invitation = fixture.remote.invite().await.unwrap();
    let pause = fixture.pause_next_write();
    let challenge = fixture.open("bad").await;
    fixture
        .hello("bad", &bad, &challenge, invitation["secret"].as_str())
        .await;
    tokio::time::timeout(Duration::from_secs(3), pause.entered.notified())
        .await
        .unwrap();
    // Bad cannot drain these while accepted pairing is persisting. The fifth
    // message exceeds its four-message queue, not the shared host connection.
    for _ in 0..5 {
        fixture.send("data", "bad", "{}".into()).await;
    }
    let close = fixture.frame().await;
    assert_eq!(close.kind, "close");
    assert_eq!(close.client, "bad");
    pause.release();
    fixture
        .send("data", "good", serde_json::to_string(&good_hello).unwrap())
        .await;
    let ready = fixture.frame().await;
    assert_eq!(ready.client, "good");
    assert_eq!(ready.kind, "data");
    let packet: Packet = serde_json::from_str(&ready.data).unwrap();
    let mut recipient = crypto::receiver(
        &good,
        &host_key,
        packet.encapsulated_key.as_ref().unwrap(),
        &crypto::response_context(&good_challenge, &good_enc),
        "host",
    )
    .unwrap();
    let ready: Value =
        serde_json::from_slice(&crypto::open(&mut recipient, &packet.ciphertext).unwrap()).unwrap();
    assert_eq!(ready["ready"], true);
    assert_eq!(
        fixture.remote.status().await["devices"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    // Accepted pairing settles, but the offending socket receives no ready and
    // none of its buffered commands can start after overflow.
    fixture.send("close", "good", String::new()).await;
    fixture.finish().await;
}

#[tokio::test]
async fn disconnected_pairing_settles_before_later_revocation_and_configuration() {
    let mut fixture = Fixture::new().await;
    let (peer, public) = crypto::keypair();
    let invitation = fixture.remote.invite().await.unwrap();
    let pause = fixture.pause_next_write();
    let challenge = fixture.open("pairing").await;
    fixture
        .hello("pairing", &peer, &challenge, invitation["secret"].as_str())
        .await;
    tokio::time::timeout(Duration::from_secs(3), pause.entered.notified())
        .await
        .unwrap();
    let device = fixture.pending_device();
    fixture.socket.close(None).await.unwrap();
    // Wait until the connector has actually dropped its socket and JoinSet.
    tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(Ok(message)) = fixture.socket.next().await {
            if matches!(message, Message::Close(_)) {
                break;
            }
        }
    })
    .await
    .unwrap();
    assert!(
        fixture.remote.state.try_lock().is_err(),
        "socket cancellation released an unsettled transaction"
    );
    let mut revoke = {
        let remote = fixture.remote.clone();
        let device = device.clone();
        tokio::spawn(async move { remote.revoke(&device).await })
    };
    let configure = {
        let remote = fixture.remote.clone();
        tokio::spawn(async move {
            remote
                .configure(Configure {
                    relay: "ws://127.0.0.1:1".into(),
                    enabled: false,
                    local_development: true,
                })
                .await
        })
    };
    assert!(
        tokio::time::timeout(Duration::from_millis(50), &mut revoke)
            .await
            .is_err()
    );
    pause.release();
    revoke.await.unwrap().unwrap();
    configure.await.unwrap().unwrap();
    assert!(!fixture.remote.device_exists(&device).await);
    assert!(fixture.remote.state.lock().await.config.devices.is_empty());
    assert_eq!(fixture.remote.status().await["invitationActive"], false);
    let restored = RemoteAccess::load(fixture.directory.path()).await.unwrap();
    let state = restored.state.lock().await;
    assert!(state.config.devices.is_empty());
    assert!(!state.config.enabled);
    assert_eq!(state.config.relay, "ws://127.0.0.1:1");
    drop(state);
    // Re-enable only in memory to test that neither the revoked key nor the old
    // consumed invitation can authorize after restart.
    restored.state.lock().await.config.enabled = true;
    assert!(
        restored
            .authorize_device(&public, None, "revoked")
            .await
            .is_err()
    );
    assert!(
        restored
            .authorize_device(&public, invitation["secret"].as_str(), "reused")
            .await
            .is_err()
    );
    fixture.finish().await;
}

#[tokio::test]
async fn shutdown_waits_for_accepted_pairing_write_and_memory_settlement() {
    let mut fixture = Fixture::new().await;
    let (peer, public) = crypto::keypair();
    let invitation = fixture.remote.invite().await.unwrap();
    let pause = fixture.pause_next_write();
    let challenge = fixture.open("pairing").await;
    fixture
        .hello("pairing", &peer, &challenge, invitation["secret"].as_str())
        .await;
    tokio::time::timeout(Duration::from_secs(3), pause.entered.notified())
        .await
        .unwrap();
    fixture.stop.cancel();
    assert!(
        tokio::time::timeout(Duration::from_millis(50), &mut fixture.runner)
            .await
            .is_err()
    );
    pause.release();
    tokio::time::timeout(Duration::from_secs(3), &mut fixture.runner)
        .await
        .unwrap()
        .unwrap();
    let restored = RemoteAccess::load(fixture.directory.path()).await.unwrap();
    let id = restored
        .authorize_device(&public, None, "restored")
        .await
        .unwrap();
    assert!(fixture.remote.device_exists(&id).await);
    assert_eq!(fixture.remote.status().await["invitationActive"], false);
}

#[tokio::test]
async fn outgoing_envelope_limit_includes_serialization_and_does_not_poison_the_queue() {
    let (out, mut incoming) = mpsc::channel(2);
    assert!(
        send(&out, "bad", json!("x".repeat(MAX_FRAME)))
            .await
            .is_err()
    );
    assert!(
        send(&out, "bad", json!("\u{0001}".repeat(MAX_FRAME / 6)))
            .await
            .is_err()
    );
    assert!(incoming.try_recv().is_err());
    send(&out, "good", json!({"ok":true})).await.unwrap();
    assert_eq!(incoming.recv().await.unwrap().client, "good");
}
