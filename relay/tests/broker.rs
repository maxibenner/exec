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
        axum::serve(listener, exec_relay::router()).await.unwrap();
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
