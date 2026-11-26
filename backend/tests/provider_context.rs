#[path = "support/http.rs"]
mod http;
mod support;
use async_trait::async_trait;
use exec_agent::{
    Error,
    core::*,
    manager::AgentManager,
    storage::{ConversationStore, JsonConversationStore},
};
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
async fn long_thinking_continuation_remains_restorable_after_crossing_256_tool_steps() {
    let root = directory();
    let workspace = directory();
    let turns = Arc::new(AtomicUsize::new(0));
    let count = turns.clone();
    let transport = Transport::new(move |request| {
        let turn = count.fetch_add(1, Ordering::SeqCst);
        async move {
            let body: serde_json::Value =
                serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
            let assistants: Vec<_> = body["messages"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|message| message.get("tool_calls").is_some())
                .collect();
            assert_eq!(assistants.len(), if turn == 0 { 256 } else { 257 });
            for message in assistants {
                let id = message["tool_calls"][0]["id"].as_str().unwrap();
                assert_eq!(message["reasoning_content"], format!("opaque-{id}"));
            }
            if turn == 0 {
                Ok(wire(
                    event(delta(
                        json!({"reasoning_content":"opaque-call-256","tool_calls":[{"index":0,"id":"call-256","type":"function","function":{"name":"change","arguments":"{}"}}]}),
                        Some("tool_calls"),
                    )) + &event(json!("[DONE]")),
                ))
            } else {
                Ok(wire(complete("Done")))
            }
        }
    });
    let p = Arc::new(provider(transport));
    let tools = vec![support::tool(None, |_| async { Ok("result".into()) })];
    let mut options = ConversationOptions::new(
        p.clone(),
        "deepseek-chat",
        workspace.path().to_str().unwrap(),
    );
    options.tools = tools.clone();
    options.settings.effort = Some("high".into());
    let mut record = Conversation::new(options, None).unwrap().record();
    record.configuration.as_mut().unwrap().instructions_frozen = true;
    record.operation = Some(Operation {
        id: new_id(),
        state: OperationState::Completed,
        kind: None,
        error: None,
    });
    record.messages.push(Message::User {
        id: new_id(),
        text: "Long synthetic conversation".into(),
        images: vec![],
        files: vec![],
    });
    let mut reasoning = serde_json::Map::new();
    for i in 0..256 {
        let id = format!("call-{i}");
        record.messages.push(Message::Assistant {
            id: new_id(),
            text: String::new(),
            calls: vec![ToolCall {
                id: id.clone(),
                name: "change".into(),
                arguments: Default::default(),
            }],
            status: MessageStatus::Completed,
        });
        record.messages.push(Message::Tool {
            id: new_id(),
            call_id: id.clone(),
            text: "result".into(),
            outcome: ToolOutcome::Completed,
            details: None,
        });
        reasoning.insert(id.clone(), json!(format!("opaque-{id}")));
    }
    record.provider_state = Some(json!({"provider":"deepseek","version":1,"reasoning":reasoning}));
    let id = record.id.clone();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    store.save(record).await.unwrap();
    store.close().await.unwrap();
    for input in ["cross the boundary", "continue after restart"] {
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
            settle(manager.submit(&id, input.into()).await.unwrap())
                .await
                .state,
            OperationState::Completed
        );
        let conversation = manager.get(&id).unwrap();
        assert_eq!(
            conversation.record().provider_state.unwrap()["reasoning"]
                .as_object()
                .unwrap()
                .len(),
            257
        );
        assert!(
            !serde_json::to_string(&conversation.snapshot())
                .unwrap()
                .contains("opaque-call-")
        );
        manager.close().await.unwrap();
    }
    assert_eq!(turns.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn thinking_checkpoints_prune_only_unreferenced_reasoning_and_reject_oversized_state() {
    let transport = Transport::new(|request| async move {
        let body: serde_json::Value = serde_json::from_str(request.body.as_ref().unwrap()).unwrap();
        assert_eq!(
            body["messages"][1],
            json!({"role":"assistant","content":"","reasoning_content":"retain","tool_calls":[{
                "id":"needed","type":"function","function":{"name":"change","arguments":"{}"}
            }]})
        );
        assert_eq!(
            body["messages"][2],
            json!({"role":"tool","tool_call_id":"needed","content":"result"})
        );
        Ok(wire(
            event(delta(
                json!({"reasoning_content":"new reasoning","tool_calls":[{"index":0,"id":"new","type":"function","function":{"name":"change","arguments":"{}"}}]}),
                Some("tool_calls"),
            )) + &event(json!("[DONE]")),
        ))
    });
    let p = provider(transport.clone());
    let mut request = request();
    request.effort = Some("high".into());
    request.messages.extend([
        ContextMessage::Assistant {
            text: String::new(),
            calls: vec![ToolCall {
                id: "needed".into(),
                name: "change".into(),
                arguments: Default::default(),
            }],
        },
        ContextMessage::Tool {
            call_id: "needed".into(),
            text: "result".into(),
            outcome: ToolOutcome::Completed,
        },
    ]);
    request.provider_state = Some(
        json!({"provider":"deepseek","version":1,"reasoning":{"stale":"discard","needed":"retain"}}),
    );
    let mut other = support::tool(None, |_| async { Ok(String::new()) }).definition();
    other.name = "other".into();
    // Neither catalog contains the historical call's definition; keep its reasoning.
    for tools in [vec![other], vec![]] {
        request.tools = tools;
        let events = collect(&p, request.clone()).await.unwrap();
        let state = events
            .iter()
            .find_map(|event| match event {
                ProviderEvent::Metadata { state, .. } => state.as_ref(),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            state["reasoning"],
            json!({"needed":"retain","new":"new reasoning"})
        );
        let requests = transport.requests.lock().unwrap();
        let body: serde_json::Value =
            serde_json::from_str(requests.last().unwrap().body.as_ref().unwrap()).unwrap();
        if request.tools.is_empty() {
            assert!(body.get("tools").is_none());
        } else {
            assert_eq!(
                body["tools"],
                json!([{"type":"function","function":request.tools[0]}])
            );
        }
    }
    request.provider_state = Some(
        json!({"provider":"deepseek","version":1,"reasoning":{"a":"x".repeat(3*1024*1024),"b":"x".repeat(3*1024*1024),"c":"x".repeat(3*1024*1024)}}),
    );
    assert_eq!(
        collect(&p, request).await.unwrap_err(),
        Error::Provider(exec_agent::ProviderFailure::Request)
    );
    assert_eq!(transport.count(), 2);
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
