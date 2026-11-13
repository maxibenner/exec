mod support;
use async_trait::async_trait;
use exec_agent::{
    Error, Result, client::AgentClient, core::*, images::ImageStore, native::*, service::*,
};
use futures_util::{
    StreamExt,
    stream::{self, BoxStream},
};
use serde_json::json;
use std::{
    io::Cursor,
    os::unix::fs::{PermissionsExt, symlink},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio_util::sync::CancellationToken;
fn png() -> Vec<u8> {
    let mut out = Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(2, 2)
        .write_to(&mut out, image::ImageFormat::Png)
        .unwrap();
    out.into_inner()
}
#[derive(Default)]
struct Provider {
    requests: Mutex<Vec<ProviderRequest>>,
    generated: AtomicUsize,
}
#[async_trait]
impl ChatProvider for Provider {
    async fn accepts_images(&self, _: &str, _: CancellationToken) -> Result<bool> {
        Ok(true)
    }
    fn supports_image_generation(&self) -> bool {
        true
    }
    fn connections(&self) -> Vec<ProviderConnection> {
        vec![ProviderConnection {
            id: "openai".into(),
            name: "Test".into(),
            connected: true,
            source: "fake".into(),
            manageable: false,
            blocked: false,
        }]
    }
    async fn generate_image(
        &self,
        input: ImageGeneration,
        _: CancellationToken,
    ) -> Result<GeneratedImage> {
        assert_eq!(input.prompt, "a small cat");
        self.generated.fetch_add(1, Ordering::SeqCst);
        Ok(GeneratedImage { bytes: png() })
    }
    fn stream(&self, r: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        self.requests.lock().unwrap().push(r.clone());
        let events = match r.messages.last() {
            Some(ContextMessage::User { text }) if text == "generate" => vec![
                ProviderEvent::ToolCall(ToolCall {
                    id: new_id(),
                    name: "generate_image".into(),
                    arguments: json!({"prompt":"a small cat","transparent_background":false})
                        .as_object()
                        .unwrap()
                        .clone(),
                }),
                ProviderEvent::Done,
            ],
            Some(ContextMessage::User { text }) if text == "capture" => vec![
                ProviderEvent::ToolCall(ToolCall {
                    id: new_id(),
                    name: "take_screenshot".into(),
                    arguments: json!({"target":"desktop","window_id":0})
                        .as_object()
                        .unwrap()
                        .clone(),
                }),
                ProviderEvent::Done,
            ],
            _ => vec![ProviderEvent::Text("Done".into()), ProviderEvent::Done],
        };
        Box::pin(stream::iter(events.into_iter().map(Ok)))
    }
}
async fn terminal(client: &AgentClient, id: &str) -> ConversationSnapshot {
    let mut events = client.events(id, CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(frame) = events.next().await {
            match frame.unwrap() {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } if snapshot
                    .operation
                    .as_ref()
                    .is_some_and(|o| !o.state.active()) =>
                {
                    return snapshot;
                }
                _ => {}
            }
        }
        panic!("no settlement")
    })
    .await
    .unwrap()
}
#[tokio::test]
async fn uploaded_and_generated_images_survive_restart_and_last_fork_owns_deletion() {
    let root = support::directory();
    let workspace = support::directory();
    let p = Arc::new(Provider::default());
    let service = start_persistent_service(root.path(), p.clone(), false)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    let c = client
        .create("test", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    let image = client
        .upload_image(&c.id, "input.png", &png())
        .await
        .unwrap();
    assert_eq!(
        std::fs::metadata(
            root.path()
                .join("images")
                .join(format!("{}.image", image.id))
        )
        .unwrap()
        .permissions()
        .mode()
            & 0o777,
        0o600
    );
    client
        .submit_images(&c.id, "", std::slice::from_ref(&image))
        .await
        .unwrap();
    let snapshot = terminal(&client, &c.id).await;
    assert_eq!(snapshot.operation.unwrap().state, OperationState::Completed);
    assert_eq!(snapshot.metadata.title.as_deref(), Some("Image"));
    assert_eq!(p.requests.lock().unwrap()[0].images[&0].len(), 1);
    client.submit(&c.id, "generate").await.unwrap();
    let snapshot = terminal(&client, &c.id).await;
    assert_eq!(snapshot.operation.unwrap().state, OperationState::Completed);
    let generated = snapshot
        .messages
        .iter()
        .find_map(|m| match m {
            Message::Tool {
                details: Some(ToolDetails::Image { image, origin }),
                ..
            } if origin == "generated" => Some(image.clone()),
            _ => None,
        })
        .unwrap();
    assert_eq!(p.generated.load(Ordering::SeqCst), 1);
    assert!(p.requests.lock().unwrap().last().unwrap().images.len() >= 2);
    let fork = client.fork(&c.id).await.unwrap();
    service.close().await.unwrap();
    let service = start_persistent_service(root.path(), p, false)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    client.delete(&c.id).await.unwrap();
    assert!(client.read_image(&generated.id).await.is_ok());
    assert!(client.read_image(&image.id).await.is_ok());
    client.delete(&fork.id).await.unwrap();
    assert!(client.read_image(&generated.id).await.is_err());
    assert!(
        !root
            .path()
            .join("images")
            .join(format!("{}.image", generated.id))
            .exists()
    );
    assert!(
        !root
            .path()
            .join("images")
            .join(format!("{}.image", image.id))
            .exists()
    );
    service.close().await.unwrap();
}
#[tokio::test]
async fn image_store_rejects_bad_data_tampering_and_symlinks_without_overwrite() {
    let root = support::directory();
    let store = ImageStore::open(root.path().join("images")).await.unwrap();
    let id = new_id();
    assert!(
        store
            .put(id.clone(), "bad".into(), b"not an image".to_vec())
            .await
            .is_err()
    );
    let image = store.put(id.clone(), "valid".into(), png()).await.unwrap();
    assert!(
        store
            .put(id.clone(), "overwrite".into(), png())
            .await
            .is_err()
    );
    let mut changed = image.clone();
    changed.sha256 = "0".repeat(64);
    assert!(store.load(&changed).await.is_err());
    let path = root.path().join("images").join(format!("{id}.image"));
    std::fs::remove_file(&path).unwrap();
    symlink("missing", &path).unwrap();
    assert!(store.read(&id).await.is_err());
    let mut invalid = image;
    invalid.byte_count = usize::MAX;
    assert!(invalid.validate().is_err());
}
#[tokio::test]
async fn native_api_requires_host_nomination_os_permission_session_enablement_and_exact_result() {
    let root = support::directory();
    let workspace = support::directory();
    let p = Arc::new(Provider::default());
    let hub = Arc::new(NativeHub::default());
    let service = start_persistent_service_with_native(root.path(), p.clone(), false, hub.clone())
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    let mut denied = client.native_events(true, CancellationToken::new());
    assert!(matches!(denied.next().await.unwrap(), Err(Error::Api(403))));
    drop(denied);
    hub.allow_local_frontend(std::process::id()).unwrap();
    let cancel = CancellationToken::new();
    let mut native = client.native_events(true, cancel.clone());
    let frontend = match native.next().await.unwrap().unwrap() {
        NativeEvent::Registered { frontend_id } => frontend_id,
        _ => panic!("missing registration"),
    };
    let c = client
        .create("test", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    assert!(!client.desktop_permission(&c.id).await.unwrap().enabled);
    client
        .set_desktop_permission(
            &c.id,
            &DesktopPermission {
                frontend_id: Some(frontend.clone()),
                enabled: true,
            },
        )
        .await
        .unwrap();
    let operation = client.submit(&c.id, "capture").await.unwrap();
    let request = match native.next().await.unwrap().unwrap() {
        NativeEvent::Request { request } => request,
        _ => panic!("missing native request"),
    };
    assert_eq!(request.operation_id, operation);
    assert_eq!(request.frontend_id, frontend);
    let mut wrong = request.clone();
    wrong.call_id = "stale-call".into();
    assert!(
        client
            .native_reply(&NativeReply {
                request: wrong,
                result: NativePayload::Failed
            })
            .await
            .is_err()
    );
    use base64::Engine;
    client
        .native_reply(&NativeReply {
            request: request.clone(),
            result: NativePayload::Image {
                base64: base64::engine::general_purpose::STANDARD.encode(png()),
            },
        })
        .await
        .unwrap();
    assert!(
        client
            .native_reply(&NativeReply {
                request,
                result: NativePayload::Failed
            })
            .await
            .is_err()
    );
    let snapshot = terminal(&client, &c.id).await;
    assert_eq!(snapshot.operation.unwrap().state, OperationState::Completed);
    assert!(snapshot.messages.iter().any(|m|matches!(m,Message::Tool{details:Some(ToolDetails::Image{origin,..}),..}if origin=="screenshot")));
    let fork = client.fork(&c.id).await.unwrap();
    assert!(!client.desktop_permission(&fork.id).await.unwrap().enabled);
    client.native_os_permission(&frontend, false).await.unwrap();
    assert!(!client.desktop_permission(&c.id).await.unwrap().enabled);
    client.native_os_permission(&frontend, true).await.unwrap();
    assert!(!client.desktop_permission(&c.id).await.unwrap().enabled);
    client
        .set_desktop_permission(
            &c.id,
            &DesktopPermission {
                frontend_id: Some(frontend),
                enabled: true,
            },
        )
        .await
        .unwrap();
    drop(native);
    cancel.cancel();
    tokio::time::timeout(Duration::from_secs(3), async {
        while client.desktop_permission(&c.id).await.unwrap().enabled {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    service.close().await.unwrap();
}
#[tokio::test]
async fn denial_never_consumes_generation_quota_or_creates_image_references() {
    let root = support::directory();
    let workspace = support::directory();
    let p = Arc::new(Provider::default());
    let service = start_persistent_service(root.path(), p.clone(), false)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    let c = client
        .create_with_settings(
            "test",
            workspace.path().to_str().unwrap(),
            SessionSettings {
                auto_approve: false,
                ..SessionSettings::default()
            },
        )
        .await
        .unwrap();
    let operation = client.submit(&c.id, "generate").await.unwrap();
    let mut events = client.events(&c.id, CancellationToken::new());
    let approval = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let frame = events.next().await.unwrap().unwrap();
            let snapshot = match frame {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } => snapshot,
                _ => continue,
            };
            if let Some(approval) = snapshot.approval {
                break approval;
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(p.generated.load(Ordering::SeqCst), 0);
    assert!(client.get(&c.id).await.unwrap().resources.is_empty());
    client
        .approve(&c.id, &operation, &approval.id, false)
        .await
        .unwrap();
    let settled = terminal(&client, &c.id).await;
    assert!(settled.resources.is_empty());
    assert_eq!(p.generated.load(Ordering::SeqCst), 0);
    assert!(settled.messages.iter().any(|m| matches!(
        m,
        Message::Tool {
            outcome: ToolOutcome::Denied,
            ..
        }
    )));
    drop(events);
    service.close().await.unwrap();
}
#[tokio::test]
async fn releasing_unused_uploads_is_durable_and_preserves_other_fork_references() {
    let root = support::directory();
    let workspace = support::directory();
    let p = Arc::new(Provider::default());
    let service = start_persistent_service(root.path(), p, false)
        .await
        .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    let c = client
        .create("test", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    let image = client
        .upload_image(&c.id, "draft.png", &png())
        .await
        .unwrap();
    let fork = client.fork(&c.id).await.unwrap();
    client.release_image(&c.id, &image.id).await.unwrap();
    assert!(client.get(&c.id).await.unwrap().resources.is_empty());
    assert!(client.read_image(&image.id).await.is_ok());
    client.release_image(&fork.id, &image.id).await.unwrap();
    assert!(client.read_image(&image.id).await.is_err());
    assert!(
        !root
            .path()
            .join("images")
            .join(format!("{}.image", image.id))
            .exists()
    );
    service.close().await.unwrap();
}
