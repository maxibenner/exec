//! Isolated runner regressions; no live inference, account credentials, or user stores.
mod support;

use async_trait::async_trait;
use exec_agent::{
    Result,
    core::*,
    storage::{ConversationStore, JsonConversationStore},
};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use support::*;

#[tokio::test]
async fn fallback_titles_sanitize_controls_without_changing_accepted_messages() {
    for (text, title) in [
        (
            "\u{1b}Hello\u{7f}\u{85} world\u{7}\n from\t test",
            "Hello world from test",
        ),
        ("\u{1b}\u{7}\u{9f}", "Untitled"),
    ] {
        let root = directory();
        let store = JsonConversationStore::open(root.path()).await.unwrap();
        let provider = FakeProvider::new(vec![answer(), answer()]);
        let mut config = options(provider.clone(), vec![]);
        config.checkpoint = Some(store.clone());
        let c = Conversation::new(config, None).unwrap();
        assert_eq!(
            complete(c.submit(text.into()).unwrap()).await.state,
            OperationState::Completed
        );
        assert_eq!(c.snapshot().metadata.title.as_deref(), Some(title));
        assert!(c.snapshot().storage_error.is_none());
        assert_eq!(c.snapshot().messages[0].text(), text);
        assert!(matches!(
            &provider.requests.lock().unwrap()[0].messages[0],
            ContextMessage::User { text: sent } if sent == text
        ));
        assert_eq!(store.load().await.unwrap(), vec![c.record()]);
        store.close().await.unwrap();

        let store = JsonConversationStore::open(root.path()).await.unwrap();
        let saved = store.load().await.unwrap().remove(0);
        let mut config = options(provider.clone(), vec![]);
        config.checkpoint = Some(store.clone());
        let restored = Conversation::new(config, Some(saved)).unwrap();
        assert_eq!(
            complete(restored.submit("Continue".into()).unwrap())
                .await
                .state,
            OperationState::Completed
        );
        assert_eq!(provider.count(), 2);
        assert_eq!(restored.snapshot().messages[0].text(), text);
        assert_eq!(restored.snapshot().metadata.title.as_deref(), Some(title));
        store.close().await.unwrap();
    }
}

fn image_ref() -> ImageRef {
    ImageRef {
        id: new_id(),
        name: "result.png".into(),
        media_type: "image/png".into(),
        width: 1,
        height: 1,
        byte_count: 1,
        sha256: "a".repeat(64),
    }
}

struct SuccessfulTool {
    image: ImageRef,
    yield_before_return: bool,
    prepared: AtomicUsize,
    saved: AtomicUsize,
}
struct SuccessfulAction {
    image: ImageRef,
    context: ToolContext,
    yield_before_return: bool,
}
#[async_trait]
impl Tool for SuccessfulTool {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: "change".into(),
            description: "Test successful effect".into(),
            parameters: Arguments::new(),
        }
    }
    async fn prepare(&self, _: Arguments, context: ToolContext) -> Result<Box<dyn PreparedTool>> {
        self.prepared.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(SuccessfulAction {
            image: self.image.clone(),
            context,
            yield_before_return: self.yield_before_return,
        }))
    }
    async fn result_saved(&self, _: &str, _: &str) -> Result<()> {
        self.saved.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}
#[async_trait]
impl PreparedTool for SuccessfulAction {
    fn approval(&self) -> Option<&str> {
        None
    }
    fn resources(&self) -> Vec<ResourceRef> {
        vec![ResourceRef {
            id: self.image.id.clone(),
            call_id: self.context.call_id.clone(),
            kind: ResourceKind::Image,
        }]
    }
    async fn execute_output(self: Box<Self>) -> Result<ToolOutput> {
        if self.yield_before_return {
            tokio::task::yield_now().await;
        }
        // The effect succeeded, but cancellation wins just before its result returns.
        self.context.cancel.cancel();
        Ok(ToolOutput {
            text: "Image saved successfully.".into(),
            details: Some(ToolDetails::Image {
                image: self.image,
                origin: "generated".into(),
            }),
        })
    }
    async fn execute(self: Box<Self>) -> Result<String> {
        Ok(self.execute_output().await?.text)
    }
}

#[tokio::test]
async fn successful_tool_payload_survives_cancellation_without_continuation() {
    // Exercise both the executor's first-poll and in-flight completion paths.
    for yield_before_return in [false, true] {
        let root = directory();
        let store = JsonConversationStore::open(root.path()).await.unwrap();
        let provider = FakeProvider::new(vec![response(vec![
            call("first"),
            call("second"),
            ProviderEvent::Done,
        ])]);
        let tool = Arc::new(SuccessfulTool {
            image: image_ref(),
            yield_before_return,
            prepared: AtomicUsize::new(0),
            saved: AtomicUsize::new(0),
        });
        let mut config = options(provider.clone(), vec![tool.clone()]);
        config.checkpoint = Some(store.clone());
        let c = Conversation::new(config, None).unwrap();
        assert_eq!(
            complete(c.submit("Generate an image".into()).unwrap())
                .await
                .state,
            OperationState::Interrupted
        );
        assert_eq!(provider.count(), 1, "no continuation or retry");
        assert_eq!(tool.prepared.load(Ordering::SeqCst), 1);
        assert_eq!(tool.saved.load(Ordering::SeqCst), 1);
        assert_eq!(
            outcomes(&c),
            [ToolOutcome::Completed, ToolOutcome::NotExecuted]
        );
        let snapshot = c.snapshot();
        assert!(snapshot.storage_error.is_none());
        assert!(snapshot.active_tool_call_id.is_none());
        assert!(matches!(
            &snapshot.messages[2],
            Message::Tool { call_id, text, outcome: ToolOutcome::Completed,
                details: Some(ToolDetails::Image { image, origin }), .. }
            if call_id == "first" && text == "Image saved successfully."
                && image == &tool.image && origin == "generated"
        ));
        assert_eq!(
            snapshot.resources,
            vec![ResourceRef {
                id: tool.image.id.clone(),
                call_id: "first".into(),
                kind: ResourceKind::Image,
            }]
        );
        assert_eq!(store.load().await.unwrap(), vec![c.record()]);
        let restored = Conversation::new(
            options(provider.clone(), vec![tool]),
            Some(store.load().await.unwrap().remove(0)),
        )
        .unwrap();
        assert_eq!(restored.snapshot(), snapshot);
        assert_eq!(provider.count(), 1, "restoring must not replay the effect");
        store.close().await.unwrap();
    }
}
