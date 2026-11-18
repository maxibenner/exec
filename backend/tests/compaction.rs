use support::client::AgentClient;
mod support;
use async_trait::async_trait;
use exec_agent::{Error, Result, core::*};
use futures_util::stream::{self, BoxStream};
use serde_json::{Value, json};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use tokio_util::sync::CancellationToken;
#[derive(Default)]
struct Provider {
    requests: Mutex<Vec<ProviderRequest>>,
    compactions: Mutex<Vec<ProviderRequest>>,
    hold: AtomicBool,
    fail: AtomicBool,
    entered: CancellationToken,
    release: CancellationToken,
}
#[async_trait]
impl ChatProvider for Provider {
    fn supports_compaction(&self, _: &str) -> bool {
        true
    }
    fn context_window(&self, _: &str) -> Option<u64> {
        Some(100)
    }
    fn stream(&self, r: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        self.requests.lock().unwrap().push(r.clone());
        Box::pin(stream::iter([
            Ok(ProviderEvent::Text("answer".into())),
            Ok(ProviderEvent::Metadata {
                state: r.provider_state.or(Some(json!({"original":true}))),
                usage: Some(TokenUsage {
                    input_tokens: Some(90),
                    output_tokens: Some(6),
                    total_tokens: Some(96),
                }),
            }),
            Ok(ProviderEvent::Done),
        ]))
    }
    async fn compact(&self, r: ProviderRequest) -> Result<Value> {
        self.compactions.lock().unwrap().push(r.clone());
        self.entered.cancel();
        if self.hold.load(Ordering::SeqCst) {
            tokio::select! {
                _ = r.cancel.cancelled() => return Err(Error::Cancelled),
                _ = self.release.cancelled() => {},
            }
        }
        if self.fail.load(Ordering::SeqCst) {
            return Err(Error::Internal);
        }
        Ok(json!({"compacted":r.message_ids.last()}))
    }
}
#[tokio::test]
async fn sync_proofs_remain_compatible_across_compaction() {
    use sha2::{Digest, Sha256};
    let p = Arc::new(Provider::default());
    let c = support::conversation(p.clone(), vec![]);
    support::complete(c.submit("first".into()).unwrap()).await;
    let original = c.sync(SyncCursor::Latest).unwrap();
    p.hold.store(true, Ordering::SeqCst);
    let run = c.compact().unwrap();
    p.entered.cancelled().await;
    let streaming = c.sync(SyncCursor::Latest).unwrap();
    let anchor = streaming.snapshot.messages.last().unwrap().id().to_owned();
    p.release.cancel();
    support::complete(run).await;
    let page = c
        .sync(SyncCursor::After {
            anchor: &anchor,
            prefix: streaming.prefix.as_deref().unwrap(),
        })
        .unwrap();
    assert!(!page.reset);
    assert_eq!(page.snapshot.messages.len(), 2);
    let snapshot = c.snapshot();
    assert_eq!(
        page.prefix.unwrap(),
        format!(
            "{:x}",
            Sha256::digest(
                serde_json::to_vec(&snapshot.messages[..snapshot.messages.len() - 1]).unwrap()
            )
        )
    );
    assert_eq!(
        original.snapshot.messages,
        snapshot.messages[..original.total]
    );
}

#[tokio::test]
async fn automatic_compaction_uses_completed_prefix_keeps_new_input_and_visible_history() {
    let p = Arc::new(Provider::default());
    let c = support::conversation(p.clone(), vec![]);
    support::complete(c.submit("first".into()).unwrap()).await;
    let original = c.snapshot().messages;
    assert_eq!(c.snapshot().context_usage.unwrap().tokens, 96);
    support::complete(c.submit("second".into()).unwrap()).await;
    let compactions = p.compactions.lock().unwrap();
    assert_eq!(compactions.len(), 1);
    assert_eq!(compactions[0].messages, context(&original));
    assert_eq!(
        compactions[0].message_ids,
        original
            .iter()
            .map(|m| m.id().to_owned())
            .collect::<Vec<_>>()
    );
    assert_eq!(&c.snapshot().messages[..original.len()], &original);
    assert!(matches!(
        &c.snapshot().messages[original.len() + 1],
        Message::Assistant { status: MessageStatus::Completed, calls, .. } if calls[0].name == "compact"
    ));
    let requests = p.requests.lock().unwrap();
    let request = &requests[1];
    let history = c.snapshot().messages;
    assert_eq!(request.message_ids.len(), request.messages.len());
    assert_eq!(
        request.message_ids,
        history[..history.len() - 1]
            .iter()
            .filter(|m| m.in_context())
            .map(|m| m.id().to_owned())
            .collect::<Vec<_>>()
    );
    drop(requests);
    assert!(
        matches!(p.requests.lock().unwrap()[1].messages.last(),Some(ContextMessage::User{text}) if text=="second")
    );
    assert!(
        p.requests.lock().unwrap()[1]
            .provider_state
            .as_ref()
            .unwrap()
            .get("compacted")
            .is_some()
    );
}
#[tokio::test]
async fn compaction_preserves_failed_attempts_with_aligned_context_ids() {
    let failed = support::conversation(
        support::FakeProvider::new(vec![support::response(vec![ProviderEvent::Text(
            "Partial attempt".into(),
        )])]),
        vec![],
    );
    assert_eq!(
        support::complete(failed.submit("first".into()).unwrap())
            .await
            .state,
        OperationState::Failed
    );
    let p = Arc::new(Provider::default());
    let c = Conversation::new(support::options(p.clone(), vec![]), Some(failed.record())).unwrap();
    assert_eq!(
        support::complete(c.compact().unwrap()).await.state,
        OperationState::Completed
    );
    let compactions = p.compactions.lock().unwrap();
    let request = &compactions[0];
    assert_eq!(request.messages, context(&failed.snapshot().messages));
    assert_eq!(request.message_ids.len(), request.messages.len());
    assert_eq!(request.message_ids[1], failed.snapshot().messages[1].id());
    assert!(matches!(
        &request.messages[1],
        ContextMessage::Assistant { text, calls }
        if text.contains("failed before completion") && text.ends_with("Partial attempt")
            && calls.is_empty()
    ));
    assert_eq!(context(&c.snapshot().messages), request.messages);
    assert!(p.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn manual_compaction_is_exclusive_cancellable_and_keeps_original_on_failure() {
    let p = Arc::new(Provider::default());
    let c = support::conversation(p.clone(), vec![]);
    support::complete(c.submit("first".into()).unwrap()).await;
    let original = c.record().provider_state;
    let history = c.snapshot().messages;
    p.hold.store(true, Ordering::SeqCst);
    let run = c.compact().unwrap();
    p.entered.cancelled().await;
    assert!(c.submit("overlap".into()).is_err());
    assert!(matches!(
        c.snapshot().messages.last(),
        Some(Message::Assistant { status: MessageStatus::Streaming, calls, .. }) if calls[0].name == "compact"
    ));
    let pending = c.snapshot();
    let Message::Assistant { calls, .. } = pending.messages.last().unwrap() else {
        panic!("missing call")
    };
    assert_eq!(
        pending.active_tool_call_id.as_deref(),
        Some(calls[0].id.as_str())
    );
    let wire = serde_json::to_value(&pending).unwrap();
    assert_eq!(
        wire["messages"].as_array().unwrap().last().unwrap()["role"],
        "assistant"
    );
    assert_eq!(
        wire["activeToolCallID"],
        wire["messages"].as_array().unwrap().last().unwrap()["calls"][0]["id"]
    );
    let pending_call = pending.messages.last().unwrap().clone();
    let recovered = c.record().recover().unwrap();
    recovered.validate().unwrap();
    assert!(matches!(
        recovered.messages.last(),
        Some(Message::Tool {
            outcome: ToolOutcome::Interrupted,
            ..
        })
    ));
    assert_eq!(recovered.provider_state, original);
    assert_eq!(recovered.messages[history.len()].id(), pending_call.id());
    assert!(
        c.steer(
            &run.operation_id,
            "cannot steer a maintenance operation".into()
        )
        .is_err()
    );
    assert!(c.cancel(&run.operation_id));
    assert_eq!(
        support::complete(run).await.state,
        OperationState::Interrupted
    );
    assert_eq!(c.record().provider_state, original);
    assert_eq!(&c.snapshot().messages[..history.len()], &history);
    assert!(matches!(
        c.snapshot().messages.last(),
        Some(Message::Tool {
            outcome: ToolOutcome::Interrupted,
            ..
        })
    ));
    p.hold.store(false, Ordering::SeqCst);
    p.fail.store(true, Ordering::SeqCst);
    assert_eq!(
        support::complete(c.compact().unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(c.record().provider_state, original);
    assert!(matches!(
        c.snapshot().messages.last(),
        Some(Message::Tool {
            outcome: ToolOutcome::Failed,
            ..
        })
    ));
    assert_eq!(p.requests.lock().unwrap().len(), 1);
}
#[tokio::test]
async fn compaction_checkpoint_failure_blocks_inference_and_success_publication() {
    let p = Arc::new(Provider::default());
    let fail = Arc::new(AtomicBool::new(false));
    let f = fail.clone();
    let mut options = support::options(p.clone(), vec![]);
    options.checkpoint = Some(support::checkpoint(move |r| {
        let fail = f.clone();
        async move {
            if fail.load(Ordering::SeqCst)
                && r.provider_state
                    .as_ref()
                    .is_some_and(|s| s.get("compacted").is_some())
            {
                Err(Error::Storage)
            } else {
                Ok(())
            }
        }
    }));
    let c = Conversation::new(options, None).unwrap();
    support::complete(c.submit("first".into()).unwrap()).await;
    fail.store(true, Ordering::SeqCst);
    assert_eq!(
        support::complete(c.submit("second".into()).unwrap())
            .await
            .state,
        OperationState::Failed
    );
    assert_eq!(p.requests.lock().unwrap().len(), 1);
    assert!(c.snapshot().storage_error.is_some());
    assert!(c.submit("unsafe".into()).is_err());
}
#[tokio::test]
async fn accepted_steering_is_checkpointed_while_automatic_compaction_waits() {
    let p = Arc::new(Provider::default());
    let saved = Arc::new(Mutex::new(Vec::new()));
    let capture = saved.clone();
    let mut options = support::options(p.clone(), vec![]);
    options.checkpoint = Some(support::checkpoint(move |record| {
        let capture = capture.clone();
        async move {
            capture.lock().unwrap().push(record);
            Ok(())
        }
    }));
    let c = Conversation::new(options, None).unwrap();
    support::complete(c.submit("first".into()).unwrap()).await;
    p.hold.store(true, Ordering::SeqCst);
    let run = c.submit("second".into()).unwrap();
    p.entered.cancelled().await;
    let id = c.steer(&run.operation_id, "adjust".into()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            if saved
                .lock()
                .unwrap()
                .iter()
                .any(|r| r.pending_input.iter().any(|m| m.id() == id))
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(c.cancel(&run.operation_id));
    assert_eq!(
        support::complete(run).await.state,
        OperationState::Interrupted
    );
    assert_eq!(p.requests.lock().unwrap().len(), 1);
    assert_eq!(c.snapshot().pending_input[0].id(), id);
}
#[tokio::test]
async fn steering_during_compaction_reaches_the_immediately_following_response() {
    let p = Arc::new(Provider::default());
    let c = support::conversation(p.clone(), vec![]);
    support::complete(c.submit("first".into()).unwrap()).await;
    p.hold.store(true, Ordering::SeqCst);
    let run = c.submit("second".into()).unwrap();
    p.entered.cancelled().await;
    c.steer(&run.operation_id, "adjust before responding".into())
        .unwrap();
    p.release.cancel();
    assert_eq!(
        support::complete(run).await.state,
        OperationState::Completed
    );
    assert!(c.snapshot().pending_input.is_empty());
    let requests = p.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert!(matches!(
        requests[1].messages.last(),
        Some(ContextMessage::User { text }) if text == "adjust before responding"
    ));
}

#[tokio::test]
async fn manual_compaction_api_receipt_and_opaque_checkpoint_survive_restart() {
    use exec_agent::service::*;
    use futures_util::StreamExt;
    let root = support::directory();
    let workspace = support::directory();
    let p = Arc::new(Provider::default());
    let service = start_persistent_service(
        root.path(),
        p.clone(),
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let c = client
        .create("model", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    client.submit(&c.id, "first").await.unwrap();
    let wait = |operation: Option<String>| {
        let client = client.clone();
        let id = c.id.clone();
        async move {
            let mut events = client.events(&id, CancellationToken::new());
            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                while let Some(frame) = events.next().await {
                    let snapshot = match frame.unwrap() {
                        ServiceEvent::Snapshot { snapshot }
                        | ServiceEvent::Runtime {
                            snapshot: Some(snapshot),
                            ..
                        } => snapshot,
                        _ => continue,
                    };
                    if snapshot.operation.as_ref().is_some_and(|o| {
                        !o.state.active() && operation.as_ref().is_none_or(|id| o.id == *id)
                    }) {
                        return snapshot;
                    }
                }
                panic!("missing operation settlement")
            })
            .await
            .unwrap()
        }
    };
    let history = wait(None).await.messages;
    let operation = client.compact(&c.id).await.unwrap();
    let compacted = wait(Some(operation.clone())).await;
    assert_eq!(
        compacted.operation.unwrap().state,
        OperationState::Completed
    );
    assert_eq!(&compacted.messages[..history.len()], &history);
    assert!(matches!(
        compacted.messages.last(),
        Some(Message::Tool {
            outcome: ToolOutcome::Completed,
            ..
        })
    ));
    let history = compacted.messages;
    assert!(compacted.context_usage.is_none());
    service.close().await.unwrap();
    let service = start_persistent_service(
        root.path(),
        p,
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let snapshot = client.get(&c.id).await.unwrap();
    assert_eq!(snapshot.operation.unwrap().id, operation);
    assert_eq!(snapshot.messages, history);
    let disk: serde_json::Value = serde_json::from_slice(
        &std::fs::read(
            root.path()
                .join("conversations")
                .join(format!("{}.json", c.id)),
        )
        .unwrap(),
    )
    .unwrap();
    assert!(disk["providerState"].get("compacted").is_some());
    service.close().await.unwrap();
}

#[tokio::test]
async fn repeated_compaction_excludes_activity_and_serializes_its_schema() {
    let p = Arc::new(Provider::default());
    let c = support::conversation(p.clone(), vec![]);
    support::complete(c.submit("first".into()).unwrap()).await;
    support::complete(c.compact().unwrap()).await;
    let snapshot = c.snapshot();
    let call = &snapshot.messages[snapshot.messages.len() - 2];
    let row = snapshot.messages.last().unwrap().clone();
    let json = serde_json::to_value(&row).unwrap();
    let call_json = serde_json::to_value(call).unwrap();
    assert_eq!(call_json["role"], "assistant");
    assert_eq!(call_json["calls"][0]["name"], "compact");
    assert_eq!(call_json["calls"][0]["arguments"], json!({}));
    assert_eq!(json["role"], "tool");
    assert_eq!(json["callID"], call_json["calls"][0]["id"]);
    assert_eq!(json["outcome"], "completed");
    assert_eq!(serde_json::from_value::<Message>(json).unwrap(), row);
    support::complete(c.compact().unwrap()).await;
    support::complete(c.submit("next".into()).unwrap()).await;
    let compactions = p.compactions.lock().unwrap();
    assert_eq!(compactions[0].message_ids, compactions[1].message_ids);
    assert_eq!(compactions[0].messages, compactions[1].messages);
    for request in p.requests.lock().unwrap().iter().chain(compactions.iter()) {
        assert_eq!(request.messages.len(), request.message_ids.len());
        assert!(!request.message_ids.contains(&row.id().to_owned()));
    }
}

#[tokio::test]
async fn automatic_failure_and_cancellation_publish_terminal_activity() {
    for interrupted in [false, true] {
        let p = Arc::new(Provider::default());
        let c = support::conversation(p.clone(), vec![]);
        support::complete(c.submit("first".into()).unwrap()).await;
        let original = c.record().provider_state;
        p.hold.store(interrupted, Ordering::SeqCst);
        p.fail.store(!interrupted, Ordering::SeqCst);
        let run = c.submit("next".into()).unwrap();
        if interrupted {
            p.entered.cancelled().await;
            assert!(matches!(
                c.snapshot().messages.last(),
                Some(Message::Assistant { status: MessageStatus::Streaming, calls, .. }) if calls[0].name == "compact"
            ));
            assert!(c.cancel(&run.operation_id));
        }
        support::complete(run).await;
        let expected = if interrupted {
            ToolOutcome::Interrupted
        } else {
            ToolOutcome::Failed
        };
        assert!(
            matches!(c.snapshot().messages.last(), Some(Message::Tool { outcome, .. }) if *outcome == expected)
        );
        assert_eq!(c.record().provider_state, original);
        c.record().validate().unwrap();
        assert_eq!(p.requests.lock().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn compaction_keeps_catalog_and_availability_at_completed_request_boundaries() {
    let provider = Arc::new(Provider::default());
    let mut options = support::options(
        provider.clone(),
        vec![support::tool(None, |_| async {
            panic!("unexpected tool execution")
        })],
    );
    options.metadata.disabled_tools = vec!["change".into()];
    let c = Conversation::new(options, None).unwrap();
    support::complete(c.submit("first".into()).unwrap()).await;
    assert_eq!(
        support::complete(c.compact().unwrap()).await.state,
        OperationState::Completed
    );
    assert_eq!(c.record().tool_availability.len(), 1);
    c.update_disabled_tools(vec![]).await.unwrap();
    support::complete(c.submit("second".into()).unwrap()).await;
    c.update_disabled_tools(vec!["change".into()])
        .await
        .unwrap();
    // Automatic compaction excludes the new user message, but records the latest
    // policy before its own request. The following inference must not duplicate it.
    support::complete(c.submit("third".into()).unwrap()).await;
    let requests = provider.requests.lock().unwrap();
    let compactions = provider.compactions.lock().unwrap();
    assert_eq!(compactions.len(), 2);
    for request in requests.iter().chain(compactions.iter()) {
        assert_eq!(request.tools, requests[0].tools);
        assert_eq!(request.instructions, requests[0].instructions);
        assert_eq!(request.messages.len(), request.message_ids.len());
    }
    assert_eq!(requests[0].tools[0].name, "change");
    assert!(
        matches!(compactions[1].messages.last(), Some(ContextMessage::ToolAvailability { enabled }) if enabled.is_empty())
    );
    assert!(requests[2].messages.starts_with(&compactions[1].messages));
    assert!(
        matches!(requests[2].messages.last(), Some(ContextMessage::User { text }) if text == "third")
    );
    let record = c.record();
    assert_eq!(record.tool_availability.len(), 3);
    record.validate().unwrap();
    assert_eq!(record.clone().recover().unwrap(), record);
}

#[tokio::test]
async fn failed_compaction_cannot_move_later_availability_before_an_existing_boundary() {
    let provider = Arc::new(Provider::default());
    let c = support::conversation(
        provider.clone(),
        vec![support::tool(None, |_| async {
            panic!("unexpected execution")
        })],
    );
    support::complete(c.submit("first".into()).unwrap()).await;
    let run = c.submit("unanswered".into()).unwrap();
    c.cancel(&run.operation_id);
    assert_eq!(
        support::complete(run).await.state,
        OperationState::Interrupted
    );
    c.update_disabled_tools(vec!["change".into()])
        .await
        .unwrap();
    provider.fail.store(true, Ordering::SeqCst);
    assert_eq!(
        support::complete(c.compact().unwrap()).await.state,
        OperationState::Failed
    );
    let boundary = c.record().tool_availability.last().unwrap().clone();
    c.update_disabled_tools(vec![]).await.unwrap();
    provider.fail.store(false, Ordering::SeqCst);
    assert_eq!(
        support::complete(c.submit("continue explicitly".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    let record = c.record();
    record.validate().unwrap();
    assert_eq!(record.tool_availability.len(), 3);
    assert_eq!(
        record.tool_availability[2].after_message_id,
        boundary.after_message_id
    );
    let compactions = provider.compactions.lock().unwrap();
    assert_eq!(compactions.len(), 2);
    assert!(
        compactions[1]
            .messages
            .starts_with(&compactions[0].messages)
    );
    assert!(
        compactions[1]
            .message_ids
            .starts_with(&compactions[0].message_ids)
    );
}
