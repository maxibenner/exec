use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::time::Duration;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{Message, client::IntoClientRequest},
};

#[tokio::test]
async fn idle_host_has_no_updates_and_disconnect_closes_clients() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let admission = exec_relay::HostAdmission::from_config(address.ip(), None, true).unwrap();
        axum::serve(listener, exec_relay::router(admission))
            .await
            .unwrap();
    });
    assert!(
        connect_async(format!("ws://{address}/v1/host"))
            .await
            .is_err()
    );
    let credential = "a".repeat(64); // Synthetic fixture, never a deployed credential.
    let route = format!("{:x}", Sha256::digest(credential.as_bytes()));
    let mut request = format!("ws://{address}/v1/host")
        .into_client_request()
        .unwrap();
    request.headers_mut().insert(
        "authorization",
        format!("Bearer {credential}").parse().unwrap(),
    );
    let (mut host, _) = connect_async(request).await.unwrap();
    // A host without clients receives only keepalives, never update requests.
    let idle = tokio::time::timeout(Duration::from_millis(100), async {
        while let Some(Ok(frame)) = host.next().await {
            if matches!(frame, Message::Text(_)) {
                return;
            }
        }
    })
    .await;
    assert!(idle.is_err());
    let (mut client, _) = connect_async(format!("ws://{address}/v1/client/{route}"))
        .await
        .unwrap();
    async fn text<S>(socket: &mut S) -> String
    where
        S: futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
            + Unpin,
    {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if let Message::Text(text) = socket.next().await.unwrap().unwrap() {
                    return text.to_string();
                }
            }
        })
        .await
        .unwrap()
    }
    let opened: Value = serde_json::from_str(&text(&mut host).await).unwrap();
    assert_eq!(opened["kind"], "open");
    client
        .send(Message::Text("opaque client ciphertext".into()))
        .await
        .unwrap();
    let forwarded: Value = serde_json::from_str(&text(&mut host).await).unwrap();
    assert_eq!(forwarded["data"], "opaque client ciphertext");
    assert_eq!(forwarded["client"], opened["client"]);
    host.send(Message::Text(
        json!({"kind":"data","client":opened["client"],"data":"opaque host ciphertext"})
            .to_string()
            .into(),
    ))
    .await
    .unwrap();
    assert_eq!(text(&mut client).await, "opaque host ciphertext");
    host.close(None).await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(Ok(frame)) = client.next().await {
            if matches!(frame, Message::Close(_)) {
                break;
            }
        }
    })
    .await
    .unwrap();
    assert!(
        connect_async(format!("ws://{address}/v1/client/{route}"))
            .await
            .is_err()
    );
    server.abort();
}

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn text(socket: &mut Socket) -> Value {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            match socket.next().await.unwrap().unwrap() {
                Message::Text(text) => {
                    assert!(
                        text.len() <= 1024 * 1024,
                        "serialized envelope exceeded host limit"
                    );
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

fn host_request(
    address: std::net::SocketAddr,
    token: &str,
) -> tokio_tungstenite::tungstenite::http::Request<()> {
    let mut request = format!("ws://{address}/v1/host")
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("authorization", format!("Bearer {token}").parse().unwrap());
    request
}

#[tokio::test]
async fn oversized_serialized_client_envelopes_close_only_the_offender() {
    const LIMIT: usize = 1024 * 1024;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let admission = exec_relay::HostAdmission::from_config(address.ip(), None, true).unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, exec_relay::router(admission))
            .await
            .unwrap();
    });
    let token = "a".repeat(64);
    let route = format!("{:x}", Sha256::digest(token.as_bytes()));
    let limits = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(LIMIT))
        .max_frame_size(Some(LIMIT));
    let (mut host, _) = tokio_tungstenite::connect_async_with_config(
        host_request(address, &token),
        Some(limits),
        false,
    )
    .await
    .unwrap();
    // Reading a ping ensures the host handler installed its sender.
    assert!(matches!(
        host.next().await.unwrap().unwrap(),
        Message::Ping(_)
    ));
    let (mut good, _) = connect_async(format!("ws://{address}/v1/client/{route}"))
        .await
        .unwrap();
    let good_open = text(&mut host).await;
    assert_eq!(good_open["kind"], "open");
    for payload in [
        "a".repeat(LIMIT),
        "\"".repeat(LIMIT / 2),
        "\u{0001}".repeat(LIMIT / 6),
    ] {
        let (mut bad, _) = connect_async(format!("ws://{address}/v1/client/{route}"))
            .await
            .unwrap();
        let bad_open = text(&mut host).await;
        assert_eq!(bad_open["kind"], "open");
        // The raw payload is legal. Only wrapping/escaping takes it over 1 MiB.
        assert!(payload.len() <= LIMIT);
        bad.send(Message::Text(payload.into())).await.unwrap();
        let closed = text(&mut host).await;
        assert_eq!(
            closed,
            json!({"kind":"close", "client":bad_open["client"], "data":""})
        );
        tokio::time::timeout(Duration::from_secs(3), async {
            while let Some(Ok(frame)) = bad.next().await {
                if matches!(frame, Message::Close(_)) {
                    break;
                }
            }
        })
        .await
        .unwrap();
        good.send(Message::Text("still connected".into()))
            .await
            .unwrap();
        let forwarded = text(&mut host).await;
        assert_eq!(
            forwarded,
            json!({"kind":"data", "client":good_open["client"], "data":"still connected"})
        );
        host.send(Message::Text(
            json!({"kind":"data", "client":good_open["client"], "data":"ack"})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if let Message::Text(reply) = good.next().await.unwrap().unwrap() {
                    assert_eq!(reply, "ack");
                    break;
                }
            }
        })
        .await
        .unwrap();
    }
    // The exact serialized boundary remains usable (not a blanket payload ban).
    let overhead = json!({"kind":"data", "client":good_open["client"], "data":""})
        .to_string()
        .len();
    let payload = "x".repeat(LIMIT - overhead);
    good.send(Message::Text(payload.clone().into()))
        .await
        .unwrap();
    assert_eq!(text(&mut host).await["data"], payload);
    host.close(None).await.unwrap();
    server.abort();
}

#[test]
fn production_admission_is_explicit_and_development_is_loopback_only() {
    use exec_relay::HostAdmission;
    let loopback = "127.0.0.1".parse().unwrap();
    for bind in [
        loopback,
        "0.0.0.0".parse().unwrap(),
        "192.168.1.2".parse().unwrap(),
    ] {
        assert!(HostAdmission::from_config(bind, None, false).is_err());
    }
    for invalid in [
        "",
        "not-a-hash",
        &"A".repeat(64),
        &format!("{},", "a".repeat(64)),
    ] {
        assert!(HostAdmission::from_config(loopback, Some(invalid), false).is_err());
    }
    assert!(HostAdmission::from_config(loopback, None, true).is_ok());
    assert!(HostAdmission::from_config("::1".parse().unwrap(), None, true).is_ok());
    assert!(HostAdmission::from_config("0.0.0.0".parse().unwrap(), None, true).is_err());
    assert!(HostAdmission::from_config("192.168.1.2".parse().unwrap(), None, true).is_err());
    assert!(HostAdmission::from_config(loopback, Some(&"a".repeat(64)), true).is_err());
}

#[tokio::test]
async fn self_issued_tokens_cannot_reserve_production_host_slots() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let token = "a".repeat(64);
    let route = format!("{:x}", Sha256::digest(token.as_bytes()));
    let admission =
        exec_relay::HostAdmission::from_config(address.ip(), Some(&route), false).unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, exec_relay::router(admission))
            .await
            .unwrap();
    });
    for i in 0..65 {
        let error = connect_async(host_request(address, &format!("{i:064x}")))
            .await
            .unwrap_err();
        let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
            panic!("expected admission rejection")
        };
        assert_eq!(response.status(), 403);
    }
    let (mut host, _) = connect_async(host_request(address, &token)).await.unwrap();
    assert!(matches!(
        host.next().await.unwrap().unwrap(),
        Message::Ping(_)
    ));
    let (mut client, _) = connect_async(format!("ws://{address}/v1/client/{route}"))
        .await
        .unwrap();
    assert_eq!(text(&mut host).await["kind"], "open");
    client.close(None).await.unwrap();
    host.close(None).await.unwrap();
    server.abort();
}
