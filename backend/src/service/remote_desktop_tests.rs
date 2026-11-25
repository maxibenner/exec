use super::*;
use crate::{images::ImageStore, native::*};
use futures_util::stream::{self, BoxStream};
use std::sync::Mutex;

#[derive(Default)]
struct ScreenshotProvider {
    requests: Mutex<Vec<ProviderRequest>>,
}

#[async_trait::async_trait]
impl ChatProvider for ScreenshotProvider {
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        let mut requests = self.requests.lock().unwrap();
        requests.push(request);
        // Also request the tool when unavailable, to prove the executor enforces policy.
        let events = if requests.len() == 1 {
            vec![
                ProviderEvent::ToolCall(ToolCall {
                    id: "capture".into(),
                    name: "take_screenshot".into(),
                    arguments: json!({"target":"desktop","window_id":0})
                        .as_object()
                        .unwrap()
                        .clone(),
                }),
                ProviderEvent::Done,
            ]
        } else {
            vec![ProviderEvent::Text("Done".into()), ProviderEvent::Done]
        };
        Box::pin(stream::iter(events.into_iter().map(Ok)))
    }
}

struct Fixture {
    root: tempfile::TempDir,
    host: Arc<Host>,
    provider: Arc<ScreenshotProvider>,
    native: Arc<NativeHub>,
}

impl Fixture {
    async fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let images = ImageStore::open(root.path().join("images")).await.unwrap();
        let native = Arc::new(NativeHub::default());
        let provider = Arc::new(ScreenshotProvider::default());
        let manager = Arc::new(AgentManager::default());
        manager.attach_images(images.clone());
        manager.attach_native(native.clone());
        manager
            .update_library(LibraryConfiguration {
                automatic_titles: false,
                ..Default::default()
            })
            .await
            .unwrap();
        let host = Arc::new(Host {
            options: ServiceOptions {
                manager,
                provider: provider.clone(),
                tools: vec![crate::tools::create_screenshot_tool(native.clone(), images)],
                address: "127.0.0.1:0".parse().unwrap(),
                access: HttpAccess::externally_secured(None).unwrap(),
            },
            remote: None,
            stop: CancellationToken::new(),
            handlers: tokio_util::task::TaskTracker::new(),
            mutations: Arc::new(tokio::sync::Semaphore::new(64)),
        });
        Self {
            root,
            host,
            provider,
            native,
        }
    }

    async fn call(
        &self,
        method: &str,
        path: &str,
        body: serde_json::Value,
        expected: u16,
    ) -> serde_json::Value {
        let request = Request::builder()
            .method(method)
            .uri(path)
            .header("Content-Type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let response = tokio::time::timeout(
            Duration::from_secs(3),
            remote_request(self.host.clone(), request),
        )
        .await
        .expect("remote request did not finish");
        let status = response.status();
        let body: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 1024 * 1024).await.unwrap())
                .unwrap();
        assert_eq!(status, expected, "{method} {path}: {body}");
        body
    }

    async fn create(&self, disabled: bool, auto_approve: bool) -> String {
        self.call(
            "POST",
            "/v1/conversations",
            json!({
                "model":"test",
                "workspace":self.root.path(),
                "settings":SessionSettings { auto_approve, ..Default::default() },
                "disabledTools":if disabled { vec!["take_screenshot"] } else { vec![] },
            }),
            201,
        )
        .await["id"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    async fn wait_for(
        &self,
        id: &str,
        ready: impl Fn(&ConversationSnapshot) -> bool,
    ) -> ConversationSnapshot {
        let manager = &self.host.options.manager;
        let (mut snapshot, mut events) = manager.observe(id).unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if ready(&snapshot) {
                    return snapshot;
                }
                events.recv().await.unwrap();
                snapshot = manager.snapshot(id).unwrap();
            }
        })
        .await
        .expect("conversation did not reach the expected state")
    }

    fn assert_first_availability(&self, expected: bool) {
        let requests = self.provider.requests.lock().unwrap();
        let first = requests.first().expect("first inference was not recorded");
        assert_eq!(
            first
                .tools
                .iter()
                .any(|tool| tool.name == "take_screenshot"),
            expected,
        );
        let enabled = first
            .messages
            .iter()
            .rev()
            .find_map(|message| match message {
                ContextMessage::ToolAvailability { enabled } => Some(enabled),
                _ => None,
            })
            .expect("first inference must carry runtime tool availability");
        assert_eq!(
            enabled.iter().any(|name| name == "take_screenshot"),
            expected
        );
    }

    async fn close(&self) {
        self.host.stop.cancel();
        self.host.handlers.close();
        self.host.handlers.wait().await;
        self.host.options.manager.close().await.unwrap();
    }
}

async fn next_native(frontend: &mut NativeConnection) -> NativeEvent {
    tokio::time::timeout(Duration::from_secs(3), frontend.requests.recv())
        .await
        .expect("native event was not delivered")
        .expect("native frontend disconnected")
}

#[tokio::test]
async fn remote_availability_previews_only_opted_in_capture_without_binding() {
    let fixture = Fixture::new().await;
    let query = json!({"names":["take_screenshot"],"model":"test"});
    let status = fixture
        .call("POST", "/v1/tools/availability", query.clone(), 200)
        .await;
    assert_eq!(status["take_screenshot"]["available"], false);
    let mut local = fixture.native.register(true, false).unwrap();
    let status = fixture
        .call("POST", "/v1/tools/availability", query.clone(), 200)
        .await;
    assert_eq!(status["take_screenshot"]["available"], false);
    let mut remote = fixture.native.register(false, true).unwrap();
    let id = fixture.create(false, false).await;
    for conversation in [None, Some(id.as_str())] {
        let mut body = query.clone();
        if let Some(id) = conversation {
            body["conversationID"] = json!(id);
        }
        let status = fixture
            .call("POST", "/v1/tools/availability", body, 200)
            .await;
        assert_eq!(status["take_screenshot"]["available"], true);
        assert!(!fixture.native.permission(&id).enabled);
        assert!(!fixture.native.approved(&id));
    }
    let extra = fixture.native.register(true, true).unwrap();
    let status = fixture
        .call("POST", "/v1/tools/availability", query.clone(), 200)
        .await;
    assert_eq!(status["take_screenshot"]["available"], false);
    drop(extra);
    let mut spoofed = query;
    spoofed["captureFrontendID"] = json!(local.id);
    fixture
        .call("POST", "/v1/tools/availability", spoofed, 400)
        .await;
    fixture
        .call(
            "POST",
            "/v1/native/events",
            json!({"osScreenPermission":true}),
            403,
        )
        .await;
    assert!(local.requests.try_recv().is_err() && remote.requests.try_recv().is_err());
    assert!(fixture.provider.requests.lock().unwrap().is_empty());
    fixture.close().await;
}

#[tokio::test]
async fn first_remote_turn_offers_screenshot_and_binds_before_native_request() {
    for auto_approve in [true, false] {
        let fixture = Fixture::new().await;
        // OS consent is requested on use, not required to offer the tool.
        let mut frontend = fixture.native.register(false, true).unwrap();
        let id = fixture.create(false, auto_approve).await;
        assert!(!fixture.native.permission(&id).enabled);
        assert!(frontend.requests.try_recv().is_err());
        let receipt = fixture
            .call(
                "POST",
                &format!("/v1/conversations/{id}/turns"),
                json!({"text":"capture"}),
                202,
            )
            .await;

        match next_native(&mut frontend).await {
            NativeEvent::ConversationBound {
                frontend_id,
                conversation_id,
            } => {
                assert_eq!(frontend_id, frontend.id);
                assert_eq!(conversation_id, id);
            }
            event => panic!("binding must precede any native request: {event:?}"),
        }
        assert_eq!(fixture.native.bound_frontend(&id).unwrap(), frontend.id);
        assert!(!fixture.native.approved(&id));
        if !auto_approve {
            let waiting = fixture.wait_for(&id, |s| s.approval.is_some()).await;
            fixture.assert_first_availability(true);
            assert!(matches!(
                frontend.requests.try_recv(),
                Err(tokio::sync::mpsc::error::TryRecvError::Empty)
            ));
            fixture
                .call(
                    "POST",
                    &format!("/v1/conversations/{id}/approvals"),
                    json!({
                        "operationID":receipt["operationID"],
                        "approvalID":waiting.approval.unwrap().id,
                        "approved":true,
                    }),
                    200,
                )
                .await;
        }
        let request = match next_native(&mut frontend).await {
            NativeEvent::Request { request } => request,
            event => panic!("expected a native capture request: {event:?}"),
        };
        fixture.assert_first_availability(true);
        assert_eq!(request.frontend_id, frontend.id);
        assert_eq!(request.conversation_id, id);
        assert_eq!(
            request.operation_id,
            receipt["operationID"].as_str().unwrap()
        );
        assert_eq!(request.action.target, CaptureTarget::Desktop);
        // Complete the broker exchange without credentials, screen access or image data.
        fixture
            .native
            .reply(NativeReply {
                request,
                result: NativePayload::Failed,
            })
            .unwrap();
        let settled = fixture
            .wait_for(&id, |s| {
                s.operation.as_ref().is_some_and(|op| !op.state.active())
            })
            .await;
        assert_eq!(settled.operation.unwrap().state, OperationState::Completed);
        assert_eq!(fixture.native.approved(&id), !auto_approve);
        assert!(frontend.requests.try_recv().is_err());
        fixture.close().await;
    }
}

#[tokio::test]
async fn disabled_screenshot_or_missing_opt_in_never_binds_or_executes() {
    for (disabled, opted_in) in [(true, true), (false, false)] {
        let fixture = Fixture::new().await;
        let mut frontend = fixture.native.register(true, opted_in).unwrap();
        let id = fixture.create(disabled, true).await;
        fixture
            .call(
                "POST",
                &format!("/v1/conversations/{id}/turns"),
                json!({"text":"capture"}),
                202,
            )
            .await;
        let settled = fixture
            .wait_for(&id, |s| {
                s.operation.as_ref().is_some_and(|op| !op.state.active())
            })
            .await;
        assert_eq!(settled.operation.unwrap().state, OperationState::Completed);
        fixture.assert_first_availability(false);
        assert!(!fixture.native.permission(&id).enabled);
        assert!(!fixture.native.approved(&id));
        assert!(matches!(
            frontend.requests.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
        assert!(settled.messages.iter().any(|message| matches!(
            message,
            Message::Tool { call_id, outcome: ToolOutcome::NotExecuted, .. } if call_id == "capture"
        )));
        fixture.close().await;
    }
}

#[tokio::test]
async fn remote_devices_cannot_register_native_frontends_or_grant_desktop_access() {
    let fixture = Fixture::new().await;
    let mut frontend = fixture.native.register(false, true).unwrap();
    let id = fixture.create(false, true).await;
    for (method, path, body) in [
        (
            "POST",
            "/v1/native/events".to_owned(),
            json!({"osScreenPermission":true,"acceptsRemoteConversations":true}),
        ),
        (
            "PUT",
            "/v1/native/permission".to_owned(),
            json!({"frontendID":frontend.id,"granted":true}),
        ),
        ("POST", "/v1/native/results".to_owned(), json!({})),
        (
            "PUT",
            format!("/v1/conversations/{id}/desktop"),
            json!({"frontendID":frontend.id,"enabled":true}),
        ),
    ] {
        let error = fixture.call(method, &path, body, 403).await;
        assert_eq!(error["delivery"], "rejected");
    }
    assert!(!fixture.native.permission(&id).enabled);
    assert!(fixture.provider.requests.lock().unwrap().is_empty());
    assert!(frontend.requests.try_recv().is_err());
    fixture.close().await;
}
