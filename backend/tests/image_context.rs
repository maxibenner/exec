//! Effective image-context regressions with a fake reader and OpenAI transport.
mod support;

use async_trait::async_trait;
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use exec_agent::{
    Error, Result,
    core::*,
    providers::{
        HttpResponse, ProviderRegistry,
        openai::{
            OpenAIProvider,
            auth::{Authentication, Session},
            transport::{Endpoint, Request, Transport},
        },
    },
    storage::{ConversationStore, JsonConversationStore},
};
use futures_util::stream;
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    path::Path,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
use support::*;
use tokio_util::sync::CancellationToken;

#[derive(Default)]
struct ImageTransport {
    responses: Mutex<Vec<Value>>,
}
#[async_trait]
impl Transport for ImageTransport {
    async fn send(&self, request: Request, _: CancellationToken) -> Result<HttpResponse> {
        let (content_type, body) = match request.endpoint {
            Endpoint::Models => (
                "application/json",
                json!({"models":[{
                    "slug":"test", "context_window":100, "input_modalities":["text", "image"]
                }]})
                .to_string(),
            ),
            Endpoint::Responses => {
                let body: Value = serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
                assert_eq!(body["model"], "test");
                let compact = body["input"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|item| item["type"] == "compaction_trigger");
                self.responses.lock().unwrap().push(body);
                let output = if compact {
                    json!([{"type":"compaction", "encrypted_content":"opaque summary"}])
                } else {
                    json!([{"type":"message", "content":[{"type":"output_text", "text":"answer"}]}])
                };
                let event = json!({"type":"response.completed", "response":{
                    "status":"completed", "output":output,
                    "usage":{"input_tokens":90, "output_tokens":6, "total_tokens":96}
                }});
                ("text/event-stream", format!("data: {event}\n\n"))
            }
            _ => panic!("Unexpected authentication or service request"),
        };
        Ok(HttpResponse {
            status: 200,
            content_type: Some(content_type.into()),
            body: Box::pin(stream::iter([Ok(bytes::Bytes::from(body))])),
        })
    }
}
#[derive(Default)]
struct Reader {
    loaded: Mutex<Vec<String>>,
    unavailable: Mutex<HashSet<String>>,
}
#[async_trait]
impl ImageReader for Reader {
    async fn load(&self, image: &ImageRef) -> Result<ImageInput> {
        self.loaded.lock().unwrap().push(image.id.clone());
        if self.unavailable.lock().unwrap().contains(&image.id) {
            return Err(Error::Invalid("Covered images must not be loaded."));
        }
        Ok(ImageInput {
            media_type: image.media_type.clone(),
            base64: STANDARD.encode(&image.id),
        })
    }
}
fn images() -> [ImageRef; 4] {
    // Descriptor sizes exercise accounting without allocating multi-MiB fake payloads.
    std::array::from_fn(|_| ImageRef {
        id: new_id(),
        name: "test.png".into(),
        media_type: "image/png".into(),
        width: 1,
        height: 1,
        byte_count: 6 * 1024 * 1024,
        sha256: "a".repeat(64),
    })
}
fn history(images: &[ImageRef; 4]) -> ConversationRecord {
    let mut record = conversation(FakeProvider::new(vec![]), vec![]).record();
    record.model = "openai/test".into();
    record.configuration.as_mut().unwrap().instructions_frozen = true;
    record.operation = Some(Operation {
        id: new_id(),
        state: OperationState::Completed,
        error: None,
    });
    record.resources = images
        .iter()
        .enumerate()
        .map(|(index, image)| ResourceRef {
            id: image.id.clone(),
            kind: ResourceKind::Image,
            call_id: if index == 1 {
                "image-call".into()
            } else {
                String::new()
            },
        })
        .collect();
    record.messages = vec![
        Message::User {
            id: new_id(),
            text: "old upload".into(),
            images: vec![images[0].clone()],
            files: vec![],
        },
        Message::Assistant {
            id: new_id(),
            text: String::new(),
            calls: vec![ToolCall {
                id: "image-call".into(),
                name: "generate_image".into(),
                arguments: Arguments::new(),
            }],
            status: MessageStatus::Completed,
        },
        Message::Tool {
            id: new_id(),
            call_id: "image-call".into(),
            text: "old generated image".into(),
            outcome: ToolOutcome::Completed,
            details: Some(ToolDetails::Image {
                image: images[1].clone(),
                origin: "generated".into(),
            }),
        },
        Message::Assistant {
            id: new_id(),
            text: "old answer".into(),
            calls: vec![],
            status: MessageStatus::Completed,
        },
    ];
    record.validate().unwrap();
    record
}
async fn provider(root: &Path, transport: Arc<ImageTransport>) -> Arc<dyn ChatProvider> {
    let session = Session {
        access_token: format!(
            "synthetic.{}.signature",
            URL_SAFE_NO_PAD.encode(
                json!({"https://api.openai.com/auth":{"chatgpt_account_id":"synthetic-account"}})
                    .to_string()
            )
        ),
        refresh_token: "synthetic-refresh".into(),
        account_id: "synthetic-account".into(),
        subject: "synthetic-subject".into(),
        requires_reconnect: false,
        expires_at: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3600,
    };
    let auth = Authentication::open(
        root.join("unused-credentials.json"),
        Some(serde_json::to_string(&session).unwrap()),
        transport.clone(),
    )
    .await
    .unwrap();
    Arc::new(
        ProviderRegistry::new(
            "openai",
            vec![(
                "openai".into(),
                Arc::new(OpenAIProvider::new(auth, transport)),
            )],
        )
        .unwrap(),
    )
}
fn config(provider: Arc<dyn ChatProvider>, reader: Arc<Reader>) -> ConversationOptions {
    let mut options = options(provider, vec![]);
    options.model = "openai/test".into();
    options.images = Some(reader);
    options
}
fn sent_images(body: &Value) -> Vec<String> {
    body["input"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|item| item["content"].as_array())
        .flatten()
        .filter(|part| part["type"] == "input_image")
        .map(|part| part["image_url"].as_str().unwrap().to_owned())
        .collect()
}
fn image_url(image: &ImageRef) -> String {
    format!("data:image/png;base64,{}", STANDARD.encode(&image.id))
}

#[tokio::test]
async fn opaque_compaction_excludes_covered_uploads_and_tool_images_from_turns_and_compactions() {
    let root = directory();
    let store = JsonConversationStore::open(root.path().join("profile"))
        .await
        .unwrap();
    let transport = Arc::new(ImageTransport::default());
    let provider = provider(root.path(), transport.clone()).await;
    let reader = Arc::new(Reader::default());
    let images = images();
    let initial = history(&images);
    let mut options = config(provider.clone(), reader.clone());
    options.checkpoint = Some(store.clone());
    let c = Conversation::new(options, Some(initial.clone())).unwrap();
    assert_eq!(
        complete(c.compact().unwrap()).await.state,
        OperationState::Completed
    );
    reader
        .unavailable
        .lock()
        .unwrap()
        .extend([images[0].id.clone(), images[1].id.clone()]);

    // Historical images now total 18, then 24 MiB. Only the live suffix counts.
    for image in &images[2..] {
        assert_eq!(
            complete(
                c.submit_images("new upload".into(), vec![image.clone()], None)
                    .unwrap()
            )
            .await
            .state,
            OperationState::Completed
        );
    }
    // The second turn also triggered automatic compaction at 96% of the window.
    assert_eq!(
        complete(c.compact().unwrap()).await.state,
        OperationState::Completed
    );
    assert_eq!(
        c.snapshot().messages[..initial.messages.len()],
        initial.messages
    );
    assert!(c.snapshot().storage_error.is_none());
    assert_eq!(store.load().await.unwrap(), vec![c.record()]);
    assert_eq!(
        *reader.loaded.lock().unwrap(),
        vec![
            images[0].id.clone(),
            images[1].id.clone(),
            images[2].id.clone(),
            images[2].id.clone(),
            images[3].id.clone(),
            images[3].id.clone(),
        ]
    );
    {
        let bodies = transport.responses.lock().unwrap();
        assert_eq!(bodies.len(), 5);
        for (index, body) in bodies.iter().enumerate() {
            let expected = match index {
                0 => vec![image_url(&images[0]), image_url(&images[1])],
                1 | 2 => vec![image_url(&images[2])],
                _ => vec![image_url(&images[3])],
            };
            assert_eq!(sent_images(body), expected);
            if index > 0 {
                assert_eq!(body["input"][0]["type"], "compaction");
                assert!(!body["input"].to_string().contains("old upload"));
                assert!(!body["input"].to_string().contains("old generated image"));
            }
        }
    }
    reader
        .unavailable
        .lock()
        .unwrap()
        .extend(images.iter().map(|image| image.id.clone()));
    let mut options = config(provider, reader.clone());
    options.checkpoint = Some(store.clone());
    let restored = Conversation::new(options, Some(store.load().await.unwrap().remove(0))).unwrap();
    assert_eq!(
        complete(restored.submit("text only".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert_eq!(
        reader.loaded.lock().unwrap().len(),
        6,
        "no covered assets loaded after restore"
    );
    assert!(sent_images(transport.responses.lock().unwrap().last().unwrap()).is_empty());
    store.close().await.unwrap();
}

#[tokio::test]
async fn uncompacted_images_still_enforce_the_active_context_limit_without_sending_requests() {
    let root = directory();
    let transport = Arc::new(ImageTransport::default());
    let provider = provider(root.path(), transport.clone()).await;
    let reader = Arc::new(Reader::default());
    let images = images();
    let mut initial = history(&images);
    initial.messages.push(Message::User {
        id: new_id(),
        text: "another upload".into(),
        images: vec![images[2].clone()],
        files: vec![],
    });
    let c = Conversation::new(config(provider, reader.clone()), Some(initial)).unwrap();
    assert_eq!(
        complete(c.submit("continue".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(
        complete(c.compact().unwrap()).await.state,
        OperationState::Failed
    );
    assert!(transport.responses.lock().unwrap().is_empty());
    assert_eq!(
        *reader.loaded.lock().unwrap(),
        vec![
            images[0].id.clone(),
            images[1].id.clone(),
            images[0].id.clone(),
            images[1].id.clone()
        ]
    );
    assert!(c.snapshot().storage_error.is_none());
}
