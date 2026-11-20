//! Synthetic relay sockets exercise the real host connector, without a provider.
use super::*;
use crate::remote::WritePause;
use tokio_tungstenite::{WebSocketStream, accept_async};

struct Fixture {
    directory: tempfile::TempDir,
    remote: Arc<RemoteAccess>,
    host_key: String,
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
        let host_key = crypto::public_key(&remote.state.lock().await.config.private_key).unwrap();
        let stop = CancellationToken::new();
        let runner = tokio::spawn(remote.clone().run(Weak::new(), stop.clone()));
        let (socket, _) = listener.accept().await.unwrap();
        let socket = accept_async(socket).await.unwrap();
        Self {
            directory,
            remote,
            host_key,
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
        // Invitation-pinned public identity remains available to peers even
        // while the host's private configuration mutex is held by persistence.
        let (enc, mut sender) =
            crypto::sender(private, &self.host_key, challenge, "client").unwrap();
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
    async fn authenticate(&mut self, id: &str, private: &str, invitation: Option<&str>) -> String {
        let challenge = self.open(id).await;
        let context = self.hello(id, private, &challenge, invitation).await;
        let frame = self.frame().await;
        assert_eq!(frame.kind, "data");
        assert_eq!(frame.client, id);
        let packet: Packet = serde_json::from_str(&frame.data).unwrap();
        let mut receiver = crypto::receiver(
            private,
            &self.host_key,
            packet.encapsulated_key.as_ref().unwrap(),
            &context,
            "host",
        )
        .unwrap();
        let ready: Value =
            serde_json::from_slice(&crypto::open(&mut receiver, &packet.ciphertext).unwrap())
                .unwrap();
        assert_eq!(ready["ready"], true);
        ready["deviceID"].as_str().unwrap().to_owned()
    }
    fn pause_next_write(&self) -> Arc<WritePause> {
        let pause = Arc::new(WritePause::default());
        *self.remote.write_pause.lock().unwrap() = Some(pause.clone());
        pause
    }
    async fn wait_transactions(&self, count: usize) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while self.remote.transactions.len() != count {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }
    async fn cycle_hellos_behind_paused_pairing(&mut self, peer: &str, invitation: Option<&str>) {
        self.send("close", "pairing", String::new()).await;
        for count in 2..=MAX_CLIENTS {
            let id = format!("pending-{count}");
            let challenge = self.open(&id).await;
            self.hello(&id, peer, &challenge, invitation).await;
            self.wait_transactions(count).await;
            assert_eq!(
                self.remote.authorization_slots.available_permits(),
                MAX_CLIENTS - count
            );
            self.send("close", &id, String::new()).await;
        }
        // Each new hello reaches authorization after the previous live client
        // has disconnected. None may spawn a transaction or wait for the mutex.
        for index in 0..MAX_CLIENTS * 3 {
            let id = format!("excess-{index}");
            let challenge = self.open(&id).await;
            self.hello(&id, peer, &challenge, invitation).await;
            let closed = self.frame().await;
            assert_eq!(closed.kind, "close");
            assert_eq!(closed.client, id);
            assert_eq!(self.remote.transactions.len(), MAX_CLIENTS);
            assert_eq!(self.remote.authorization_slots.available_permits(), 0);
            assert!(self.remote.state.try_lock().is_err());
        }
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
async fn revocation_closes_only_that_devices_sessions_on_the_existing_host_socket() {
    let mut fixture = Fixture::new().await;
    let (revoked_key, revoked_public) = crypto::keypair();
    let invitation = fixture.remote.invite().await.unwrap();
    let revoked = fixture
        .authenticate("revoked-1", &revoked_key, invitation["secret"].as_str())
        .await;
    let same_device = fixture.authenticate("revoked-2", &revoked_key, None).await;
    assert_eq!(same_device, revoked);
    let (healthy_key, _) = crypto::keypair();
    let invitation = fixture.remote.invite().await.unwrap();
    let healthy = fixture
        .authenticate("healthy", &healthy_key, invitation["secret"].as_str())
        .await;

    fixture.remote.revoke(&revoked).await.unwrap();
    let mut closed = Vec::new();
    for _ in 0..2 {
        let frame = fixture.frame().await;
        assert_eq!(frame.kind, "close");
        closed.push(frame.client);
    }
    closed.sort();
    assert_eq!(closed, ["revoked-1", "revoked-2"]);
    assert_eq!(
        fixture.remote.status().await["connectionStatus"],
        "connected"
    );
    assert_eq!(fixture.remote.status().await["connected"], true);
    assert!(fixture.remote.device_exists(&healthy).await);

    // Ignore anything buffered from the removed client, without resetting the
    // host socket or disturbing another authenticated client on it.
    fixture.send("data", "revoked-1", "{}".into()).await;
    assert_eq!(
        fixture.authenticate("probe", &healthy_key, None).await,
        healthy
    );
    fixture.send("close", "probe", String::new()).await;
    let challenge = fixture.open("rejected").await;
    fixture
        .hello("rejected", &revoked_key, &challenge, None)
        .await;
    let frame = fixture.frame().await;
    assert_eq!(frame.kind, "close");
    assert_eq!(frame.client, "rejected");

    let restored = RemoteAccess::load(fixture.directory.path()).await.unwrap();
    assert!(
        restored
            .authorize_device(&revoked_public, None, "revoked")
            .await
            .is_err()
    );
    fixture.finish().await;
}

#[tokio::test]
async fn queued_output_is_revocation_gated_and_cannot_target_a_reused_relay_id() {
    let directory = tempfile::tempdir().unwrap();
    let remote = RemoteAccess::load(directory.path()).await.unwrap();
    remote.state.lock().await.config.enabled = true;
    let (_, public) = crypto::keypair();
    let invitation = remote.invite().await.unwrap();
    let revoked = remote
        .authorize_device(&public, invitation["secret"].as_str(), "revoked")
        .await
        .unwrap();
    let (frames, mut outgoing) = mpsc::channel(4);
    let old = ClientOutput::new("reused".into(), frames.clone());
    old.device.set(revoked.clone()).unwrap();
    let healthy = ClientOutput::new("healthy".into(), frames.clone());
    // A pending handshake's output must remain independent of the revoked peer.
    fn client(output: &ClientOutput) -> Client {
        let (incoming, _) = mpsc::channel(1);
        let task = tokio::spawn(std::future::pending::<()>());
        Client {
            incoming,
            task: task.abort_handle(),
            device: output.device.clone(),
        }
    }
    let mut clients = HashMap::from([
        (old.client.clone(), client(&old)),
        (healthy.client.clone(), client(&healthy)),
    ]);
    send(&old, json!({"late":"reply"})).await.unwrap();
    send(&healthy, json!({"challenge":"fixture"}))
        .await
        .unwrap();
    old.enqueue(Envelope::close(old.client.clone()))
        .await
        .unwrap();
    send(&old, json!({"late":"notice"})).await.unwrap();
    remote.revoke(&revoked).await.unwrap();

    // Exercise egress before its revocation watcher removes the client.
    let frame = remote
        .authorized_output(outgoing.recv().await.unwrap(), &mut clients)
        .await
        .unwrap();
    assert_eq!(frame.kind, "close");
    assert_eq!(frame.client, old.client);
    let frame = remote
        .authorized_output(outgoing.recv().await.unwrap(), &mut clients)
        .await
        .unwrap();
    assert_eq!(frame.kind, "data");
    assert_eq!(frame.client, healthy.client);

    let replacement = ClientOutput::new(old.client.clone(), frames);
    clients.insert(replacement.client.clone(), client(&replacement));
    for _ in 0..2 {
        assert!(
            remote
                .authorized_output(outgoing.recv().await.unwrap(), &mut clients)
                .await
                .is_none()
        );
    }
    assert!(clients.contains_key(&replacement.client));
    assert!(clients.contains_key(&healthy.client));
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
async fn disconnected_hellos_are_bounded_until_pairing_settles_before_revocation() {
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
    fixture
        .cycle_hellos_behind_paused_pairing(&peer, invitation["secret"].as_str())
        .await;
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
    fixture.wait_transactions(0).await;
    assert_eq!(
        fixture.remote.authorization_slots.available_permits(),
        MAX_CLIENTS
    );
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
    fixture
        .cycle_hellos_behind_paused_pairing(&peer, invitation["secret"].as_str())
        .await;
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
    assert!(fixture.remote.transactions.is_empty());
    assert_eq!(
        fixture.remote.authorization_slots.available_permits(),
        MAX_CLIENTS
    );
    assert_eq!(
        fixture.remote.status().await["connectionStatus"],
        "disconnected"
    );
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
    let (frames, mut incoming) = mpsc::channel(2);
    let bad = ClientOutput::new("bad".into(), frames.clone());
    assert!(send(&bad, json!("x".repeat(MAX_FRAME))).await.is_err());
    assert!(
        send(&bad, json!("\u{0001}".repeat(MAX_FRAME / 6)))
            .await
            .is_err()
    );
    assert!(incoming.try_recv().is_err());
    let good = ClientOutput::new("good".into(), frames);
    send(&good, json!({"ok":true})).await.unwrap();
    assert_eq!(incoming.recv().await.unwrap().envelope.client, "good");
}
