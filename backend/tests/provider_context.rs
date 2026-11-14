#[path = "support/http.rs"]
mod http;
mod support;
use async_trait::async_trait;
use exec_agent::{Error, core::*, manager::AgentManager, storage::JsonConversationStore};
use futures_util::stream::BoxStream;
use http::*;
use serde_json::json;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use support::{complete as settle, directory};
use tokio_util::sync::CancellationToken;

struct Windowed(Arc<support::FakeProvider>);
#[async_trait]
impl ChatProvider for Windowed {
    fn context_window(&self, _: &str) -> Option<u64> {
        Some(1000)
    }
    fn stream(
        &self,
        request: ProviderRequest,
    ) -> BoxStream<'static, exec_agent::Result<ProviderEvent>> {
        self.0.stream(request)
    }
}

#[tokio::test]
async fn thinking_state_continues_tools_and_survives_restart_without_entering_snapshots() {
    let root = directory();
    let workspace = directory();
    let turns = Arc::new(AtomicUsize::new(0));
    let count = turns.clone();
    let transport = Transport::new(move |request| {
        let index = count.fetch_add(1, Ordering::SeqCst);
        async move {
            let body: serde_json::Value =
                serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
            assert_eq!(body["thinking"]["type"], "enabled");
            assert_eq!(body["reasoning_effort"], "high");
            if index == 0 {
                Ok(wire(
                    event(delta(
                        json!({"reasoning_content":"opaque continuation", "tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"change","arguments":"{}"}}]}),
                        Some("tool_calls"),
                    )) + &event(json!("[DONE]")),
                ))
            } else {
                assert!(
                    body["messages"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|m| m["role"] == "assistant"
                            && m["reasoning_content"] == "opaque continuation")
                );
                Ok(wire(
                    event(delta(json!({"content":"Done"}), Some("stop")))
                        + &event(
                            json!({"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}),
                        )
                        + &event(json!("[DONE]")),
                ))
            }
        }
    });
    let p = Arc::new(provider(transport));
    let tools = vec![support::tool(None, |_| async { Ok("result".into()) })];
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (p.clone(), tools.clone()),
    )
    .await
    .unwrap();
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    let mut options = ConversationOptions::new(
        p.clone(),
        "deepseek-chat",
        workspace.path().to_str().unwrap(),
    );
    options.tools = tools.clone();
    options.settings.effort = Some("high".into());
    let c = manager.create(options).await.unwrap();
    assert_eq!(
        settle(manager.submit(&c.id, "first".into()).await.unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert_eq!(c.snapshot().usage.unwrap().total_tokens, Some(15));
    assert!(
        !serde_json::to_string(&c.snapshot())
            .unwrap()
            .contains("opaque continuation")
    );
    assert!(
        c.record()
            .provider_state
            .unwrap()
            .to_string()
            .contains("opaque continuation")
    );
    manager.close().await.unwrap();
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (p.clone(), tools.clone()),
    )
    .await
    .unwrap();
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    assert_eq!(
        settle(manager.submit(&c.id, "continue".into()).await.unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert_eq!(turns.load(Ordering::SeqCst), 3);
    manager.close().await.unwrap();
}

#[tokio::test]
async fn failed_stream_does_not_commit_staged_state_or_usage() {
    let p = support::FakeProvider::new(vec![support::script(|_| {
        Box::pin(futures_util::stream::iter(vec![
            Ok(ProviderEvent::Metadata {
                state: Some(json!({"private":"incomplete"})),
                usage: Some(TokenUsage {
                    total_tokens: Some(10),
                    ..TokenUsage::default()
                }),
            }),
            Err(Error::Internal),
        ]))
    })]);
    let c = support::conversation(p, vec![]);
    assert_eq!(
        settle(c.submit("hello".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert!(c.record().provider_state.is_none());
    assert!(c.snapshot().usage.is_none());
}

#[tokio::test]
async fn reported_context_usage_survives_in_flight_and_failed_requests() {
    let entered = CancellationToken::new();
    let release = Arc::new(tokio::sync::Notify::new());
    let p = support::FakeProvider::new(vec![
        support::response(vec![
            ProviderEvent::Metadata {
                state: None,
                usage: Some(TokenUsage {
                    input_tokens: Some(120),
                    output_tokens: Some(8),
                    total_tokens: Some(128),
                }),
            },
            ProviderEvent::Done,
        ]),
        {
            let entered = entered.clone();
            let release = release.clone();
            support::script(move |_| {
                Box::pin(async_stream::try_stream! {
                    entered.cancel();
                    release.notified().await;
                    Err(Error::Internal)?;
                    yield ProviderEvent::Done;
                })
            })
        },
        support::answer(),
    ]);
    let c = support::conversation(Arc::new(Windowed(p.clone())), vec![]);
    assert_eq!(
        settle(c.submit("first".into()).unwrap()).await.state,
        OperationState::Completed
    );
    let reported = c.snapshot().context_usage.unwrap();
    assert_eq!((reported.tokens, reported.limit), (128, 1000));

    let run = c.submit("second".into()).unwrap();
    entered.cancelled().await;
    assert_eq!(c.snapshot().context_usage.unwrap().tokens, 128);
    release.notify_one();
    assert_eq!(settle(run).await.state, OperationState::Failed);
    assert_eq!(c.snapshot().context_usage.unwrap().tokens, 128);

    assert_eq!(
        settle(c.submit("third".into()).unwrap()).await.state,
        OperationState::Completed
    );
    assert_eq!(c.snapshot().context_usage.unwrap().tokens, 128);
}

#[tokio::test]
async fn model_default_thinking_is_supported_but_explicit_none_rejects_it() {
    let transport = Transport::new(|request| async move {
        let body: serde_json::Value = serde_json::from_str(&request.body.unwrap()).unwrap();
        assert!(body.get("thinking").is_none());
        assert!(body.get("reasoning_effort").is_none());
        Ok(wire(
            event(delta(
                json!({"reasoning_content":"not shown", "content":"Answer"}),
                Some("stop"),
            )) + &event(json!("[DONE]")),
        ))
    });
    let p = provider(transport);
    let mut request = request();
    request.effort = None;
    let events = collect(&p, request).await.unwrap();
    assert!(
        events
            .iter()
            .any(|e| matches!(e,ProviderEvent::Text(text) if text=="Answer"))
    );
    assert!(
        !events
            .iter()
            .any(|e| matches!(e,ProviderEvent::Text(text) if text.contains("not shown")))
    );
}
