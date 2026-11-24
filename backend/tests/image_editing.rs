mod support;

use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use exec_agent::{Error, Result, core::*, service::*};
use futures_util::{StreamExt, stream::BoxStream};
use serde_json::{Value, json};
use std::{
    io::Cursor,
    sync::{Arc, Mutex},
    time::Duration,
};
use support::client::AgentClient;
use tokio_util::sync::CancellationToken;

fn png(color: u8) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(2, 2, image::Rgb([color, 0, 0])))
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    bytes.into_inner()
}

#[derive(Clone, Copy, Default)]
enum Generation {
    #[default]
    Success,
    Fail,
    WaitForCancellation,
}

#[derive(Default)]
struct Provider {
    requests: Mutex<Vec<ProviderRequest>>,
    generations: Mutex<Vec<ImageGeneration>>,
    next_call: Mutex<Option<Arguments>>,
    generation: Generation,
    stream_entered: CancellationToken,
    stream_release: CancellationToken,
    generation_entered: CancellationToken,
}
impl Provider {
    fn plan(&self, ids: Option<Value>) {
        let mut arguments = json!({
            "prompt": "make a small change",
            "transparent_background": false
        })
        .as_object()
        .unwrap()
        .clone();
        if let Some(ids) = ids {
            arguments.insert("input_image_ids".into(), ids);
        }
        assert!(self.next_call.lock().unwrap().replace(arguments).is_none());
    }
    fn generation_count(&self) -> usize {
        self.generations.lock().unwrap().len()
    }
    fn assert_inputs(&self, index: usize, expected: &[Vec<u8>]) {
        let requests = self.generations.lock().unwrap();
        let request = &requests[index];
        assert_eq!(request.prompt, "make a small change");
        assert!(!request.transparent_background);
        assert_eq!(request.input_images.len(), expected.len());
        for (input, bytes) in request.input_images.iter().zip(expected) {
            assert_eq!(input.media_type, "image/png");
            assert_eq!(B64.decode(&input.base64).unwrap(), *bytes);
        }
    }
}
#[async_trait]
impl ChatProvider for Provider {
    async fn accepts_images(&self, _: &str, _: CancellationToken) -> Result<bool> {
        Ok(true)
    }
    fn supports_image_generation(&self) -> bool {
        true
    }
    fn max_image_generation_inputs(&self) -> usize {
        4
    }
    fn connections(&self) -> Vec<ProviderConnection> {
        vec![ProviderConnection {
            id: "openai".into(),
            name: "OpenAI".into(),
            connected: true,
            email: None,
            source: "fake".into(),
            manageable: false,
            blocked: false,
        }]
    }
    async fn generate_image(
        &self,
        input: ImageGeneration,
        cancel: CancellationToken,
    ) -> Result<GeneratedImage> {
        let index = {
            let mut requests = self.generations.lock().unwrap();
            requests.push(input);
            requests.len() as u8
        };
        match self.generation {
            Generation::Success => Ok(GeneratedImage { bytes: png(index) }),
            Generation::Fail => Err(Error::Api(503)),
            Generation::WaitForCancellation => {
                self.generation_entered.cancel();
                cancel.cancelled().await;
                Err(Error::Cancelled)
            }
        }
    }
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        self.requests.lock().unwrap().push(request.clone());
        let last = request
            .messages
            .iter()
            .rev()
            .find(|message| !matches!(message, ContextMessage::ToolAvailability { .. }));
        // Attachment IDs are appended as metadata to the original user text.
        let generate =
            matches!(last, Some(ContextMessage::User { text }) if text.starts_with("generate"));
        let hold = matches!(last, Some(ContextMessage::User { text }) if text.starts_with("generate after queue"));
        let call = generate.then(|| ToolCall {
            id: new_id(),
            name: "generate_image".into(),
            arguments: self
                .next_call
                .lock()
                .unwrap()
                .take()
                .expect("unplanned call"),
        });
        let entered = self.stream_entered.clone();
        let release = self.stream_release.clone();
        Box::pin(async_stream::try_stream! {
            if hold {
                entered.cancel();
                tokio::select! {
                    _ = release.cancelled() => Ok(()),
                    _ = request.cancel.cancelled() => Err(Error::Cancelled),
                }?;
            }
            if let Some(call) = call {
                yield ProviderEvent::ToolCall(call);
            } else {
                yield ProviderEvent::Text("Done".into());
            }
            yield ProviderEvent::Done;
        })
    }
}

struct Fixture {
    service: Service,
    client: AgentClient,
    provider: Arc<Provider>,
    id: String,
    root: tempfile::TempDir,
    workspace: tempfile::TempDir,
}
impl Fixture {
    async fn new(auto_approve: bool, generation: Generation) -> Self {
        let root = support::directory();
        let workspace = support::directory();
        let provider = Arc::new(Provider {
            generation,
            ..Default::default()
        });
        let service = start_persistent_service(
            root.path(),
            provider.clone(),
            false,
            "127.0.0.1:0".parse().unwrap(),
            support::http_access(),
        )
        .await
        .unwrap();
        let client = AgentClient::new(service.address).unwrap();
        let mut library = client.library().await.unwrap();
        library.automatic_titles = false;
        client.update_library(library).await.unwrap();
        let conversation = client
            .create_with_settings(
                "test",
                workspace.path().to_str().unwrap(),
                SessionSettings {
                    auto_approve,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        Self {
            service,
            client,
            provider,
            id: conversation.id,
            root,
            workspace,
        }
    }
    async fn upload(&self, name: &str, color: u8) -> ImageRef {
        self.client
            .upload_image(&self.id, name, &png(color))
            .await
            .unwrap()
    }
    async fn generate(&self, ids: Option<Value>, images: &[ImageRef]) -> ConversationSnapshot {
        self.provider.plan(ids);
        self.client
            .submit_images(&self.id, "generate", images)
            .await
            .unwrap();
        terminal(&self.client, &self.id).await
    }
    async fn close(self) {
        self.service.close().await.unwrap();
    }
}

async fn until(
    client: &AgentClient,
    id: &str,
    predicate: impl Fn(&ConversationSnapshot) -> bool,
) -> ConversationSnapshot {
    let mut events = client.events(id, CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(frame) = events.next().await {
            let snapshot = match frame.unwrap() {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } => snapshot,
                _ => continue,
            };
            if predicate(&snapshot) {
                return snapshot;
            }
        }
        panic!("missing snapshot")
    })
    .await
    .expect("state transition timed out")
}
async fn terminal(client: &AgentClient, id: &str) -> ConversationSnapshot {
    until(client, id, |snapshot| {
        snapshot
            .operation
            .as_ref()
            .is_some_and(|op| !op.state.active())
    })
    .await
}
fn generated(snapshot: &ConversationSnapshot) -> ImageRef {
    assert_eq!(
        snapshot.operation.as_ref().unwrap().state,
        OperationState::Completed
    );
    snapshot
        .messages
        .iter()
        .rev()
        .find_map(|message| match message {
            Message::Tool {
                outcome: ToolOutcome::Completed,
                details: Some(ToolDetails::Image { image, origin }),
                ..
            } if origin == "generated" => Some(image.clone()),
            _ => None,
        })
        .expect("missing generated image")
}
fn assert_last_outcome(snapshot: &ConversationSnapshot, expected: ToolOutcome) {
    let message = snapshot
        .messages
        .iter()
        .rev()
        .find(|m| matches!(m, Message::Tool { .. }))
        .unwrap();
    assert!(
        matches!(message, Message::Tool { outcome, details: None, .. } if *outcome == expected),
        "{message:?}"
    );
}

#[tokio::test]
async fn ordered_uploads_and_generated_sources_produce_reusable_immutable_fork_assets() {
    let f = Fixture::new(true, Generation::Success).await;
    // All three backwards-compatible text-only forms must reach generation with no inputs.
    let mut seed = None;
    for (index, ids) in [None, Some(Value::Null), Some(json!([]))]
        .into_iter()
        .enumerate()
    {
        seed = Some(generated(&f.generate(ids, &[]).await));
        f.provider.assert_inputs(index, &[]);
    }
    let seed = seed.unwrap();
    let first = f.upload("first.png", 200).await;
    let second = f.upload("second.png", 201).await;
    let edited = generated(
        &f.generate(
            Some(json!([second.id, seed.id, first.id])),
            &[first.clone(), second.clone()],
        )
        .await,
    );
    assert_ne!(edited.id, seed.id);
    assert_ne!(edited.id, first.id);
    assert_ne!(edited.id, second.id);
    f.provider.assert_inputs(3, &[png(201), png(3), png(200)]);
    {
        let requests = f.provider.requests.lock().unwrap();
        let text = requests
            .iter()
            .flat_map(|r| &r.messages)
            .find_map(|m| match m {
                ContextMessage::User { text }
                    if text.starts_with("generate") && text.contains(&first.id) =>
                {
                    Some(text)
                }
                _ => None,
            })
            .expect("uploaded image IDs must be visible in user context");
        assert!(text.contains(&second.id));
    }
    let fork = f.client.fork(&f.id).await.unwrap();
    f.client.delete(&f.id).await.unwrap();
    // The fork still owns both sources and the edit; the next edit needs no re-upload.
    f.provider.plan(Some(json!([edited.id])));
    f.client.submit(&fork.id, "generate").await.unwrap();
    let next = generated(&terminal(&f.client, &fork.id).await);
    assert_ne!(next.id, edited.id);
    f.provider.assert_inputs(4, &[png(4)]);
    assert_eq!(f.provider.generation_count(), 5);
    for (image, bytes) in [
        (&first, png(200)),
        (&second, png(201)),
        (&seed, png(3)),
        (&edited, png(4)),
        (&next, png(5)),
    ] {
        let data = f.client.read_image(&image.id).await.unwrap();
        assert_eq!(data.image.sha256, image.sha256);
        assert_eq!(B64.decode(data.base64).unwrap(), bytes);
    }
    f.client.delete(&fork.id).await.unwrap();
    for image in [&first, &second, &seed, &edited, &next] {
        assert!(f.client.read_image(&image.id).await.is_err());
    }
    f.close().await;
}

#[tokio::test]
async fn foreign_unused_and_cleared_images_are_rejected_even_while_assets_exist() {
    let f = Fixture::new(true, Generation::Success).await;
    let cleared = f.upload("cleared.png", 200).await;
    f.client
        .submit_images(&f.id, "remember", std::slice::from_ref(&cleared))
        .await
        .unwrap();
    terminal(&f.client, &f.id).await;
    let fork = f.client.fork(&f.id).await.unwrap();
    let cleared_snapshot = f
        .client
        .call(
            "POST",
            &format!("/v1/conversations/{}/clear", f.id),
            Some(json!({})),
        )
        .await
        .unwrap();
    assert_eq!(cleared_snapshot["resources"], json!([]));
    let unused = f.upload("unused.png", 201).await;
    let other = f
        .client
        .create("test", f.workspace.path().to_str().unwrap())
        .await
        .unwrap();
    let foreign = f
        .client
        .upload_image(&other.id, "foreign.png", &png(202))
        .await
        .unwrap();
    f.client
        .submit_images(&other.id, "remember", std::slice::from_ref(&foreign))
        .await
        .unwrap();
    terminal(&f.client, &other.id).await;
    let owned = f.client.get(&f.id).await.unwrap().resources;
    for image in [&foreign, &unused, &cleared] {
        assert!(f.client.read_image(&image.id).await.is_ok());
        let snapshot = f.generate(Some(json!([image.id])), &[]).await;
        assert_last_outcome(&snapshot, ToolOutcome::Failed);
        assert_eq!(snapshot.resources, owned);
        assert_eq!(
            f.provider.generation_count(),
            0,
            "{} escaped scope",
            image.name
        );
    }
    f.client.delete(&fork.id).await.unwrap();
    f.close().await;
}

#[tokio::test]
async fn queued_image_is_unavailable_until_its_user_message_is_consumed() {
    let f = Fixture::new(true, Generation::Success).await;
    let image = f.upload("queued.png", 200).await;
    f.provider.plan(Some(json!([image.id])));
    let operation = f
        .client
        .submit(&f.id, "generate after queue")
        .await
        .unwrap();
    tokio::time::timeout(
        Duration::from_secs(5),
        f.provider.stream_entered.cancelled(),
    )
    .await
    .unwrap();
    f.client.call(
        "POST",
        &format!("/v1/conversations/{}/steer", f.id),
        Some(json!({"operationID": operation, "text": "remember queued image", "images": [image]})),
    ).await.unwrap();
    let queued = f.client.get(&f.id).await.unwrap();
    assert!(
        matches!(&queued.pending_input[..], [Message::User { images, .. }] if images == std::slice::from_ref(&image))
    );
    f.provider.stream_release.cancel();
    let snapshot = terminal(&f.client, &f.id).await;
    assert_last_outcome(&snapshot, ToolOutcome::Failed);
    assert_eq!(f.provider.generation_count(), 0);
    assert!(snapshot.pending_input.is_empty());
    assert!(
        snapshot
            .messages
            .iter()
            .any(|m| matches!(m, Message::User { images, .. } if images.contains(&image)))
    );
    // The same ID becomes usable only after the queued input joins consumed history.
    generated(&f.generate(Some(json!([image.id])), &[]).await);
    f.provider.assert_inputs(0, &[png(200)]);
    assert_eq!(f.provider.generation_count(), 1);
    f.close().await;
}

#[tokio::test]
async fn denied_or_cancelled_edit_approval_never_calls_generation() {
    for cancel in [false, true] {
        let f = Fixture::new(false, Generation::Success).await;
        let image = f.upload("source.png", 200).await;
        let owned = f.client.get(&f.id).await.unwrap().resources;
        f.provider.plan(Some(json!([image.id])));
        let operation = f
            .client
            .submit_images(&f.id, "generate", std::slice::from_ref(&image))
            .await
            .unwrap();
        let waiting = until(&f.client, &f.id, |s| s.approval.is_some()).await;
        let approval = waiting.approval.unwrap();
        assert!(approval.description.to_lowercase().contains("openai"));
        assert!(approval.description.contains(&image.id));
        assert_eq!(waiting.resources, owned);
        assert_eq!(f.provider.generation_count(), 0);
        if cancel {
            f.client.cancel(&f.id, &operation).await.unwrap();
        } else {
            f.client
                .approve(&f.id, &operation, &approval.id, false)
                .await
                .unwrap();
        }
        let snapshot = terminal(&f.client, &f.id).await;
        assert_last_outcome(
            &snapshot,
            if cancel {
                ToolOutcome::NotExecuted
            } else {
                ToolOutcome::Denied
            },
        );
        assert_eq!(
            snapshot.operation.unwrap().state,
            if cancel {
                OperationState::Interrupted
            } else {
                OperationState::Completed
            }
        );
        assert!(snapshot.approval.is_none());
        assert_eq!(snapshot.resources, owned);
        assert_eq!(f.provider.generation_count(), 0);
        assert_eq!(
            B64.decode(f.client.read_image(&image.id).await.unwrap().base64)
                .unwrap(),
            png(200)
        );
        f.close().await;
    }
}

#[tokio::test]
async fn failed_or_cancelled_edit_generation_is_not_retried_or_published() {
    for cancel in [false, true] {
        let mode = if cancel {
            Generation::WaitForCancellation
        } else {
            Generation::Fail
        };
        let f = Fixture::new(true, mode).await;
        let image = f.upload("source.png", 200).await;
        f.provider.plan(Some(json!([image.id])));
        let operation = f
            .client
            .submit_images(&f.id, "generate", std::slice::from_ref(&image))
            .await
            .unwrap();
        if cancel {
            tokio::time::timeout(
                Duration::from_secs(5),
                f.provider.generation_entered.cancelled(),
            )
            .await
            .unwrap();
            f.client.cancel(&f.id, &operation).await.unwrap();
        }
        let snapshot = terminal(&f.client, &f.id).await;
        assert_last_outcome(
            &snapshot,
            if cancel {
                ToolOutcome::Interrupted
            } else {
                ToolOutcome::Failed
            },
        );
        assert_eq!(
            snapshot.operation.unwrap().state,
            if cancel {
                OperationState::Interrupted
            } else {
                OperationState::Completed
            }
        );
        f.provider.assert_inputs(0, &[png(200)]);
        assert_eq!(f.provider.generation_count(), 1);
        // A later unrelated user turn must not replay the failed/interrupted edit.
        f.client
            .submit(&f.id, "continue without editing")
            .await
            .unwrap();
        let next = terminal(&f.client, &f.id).await;
        assert!(!next.messages.iter().any(|m| matches!(
            m,
            Message::Tool {
                details: Some(ToolDetails::Image { .. }),
                ..
            }
        )));
        assert_eq!(f.provider.generation_count(), 1);
        assert_eq!(
            std::fs::read_dir(f.root.path().join("images"))
                .unwrap()
                .count(),
            1
        );
        assert_eq!(
            B64.decode(f.client.read_image(&image.id).await.unwrap().base64)
                .unwrap(),
            png(200)
        );
        f.close().await;
    }
}
