mod support;
use exec_agent::{Error, core::*, manager::AgentManager};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use support::*;
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn streams_text_retains_context_and_isolates_snapshots_and_observers() {
    let provider = FakeProvider::new(vec![
        response(vec![
            ProviderEvent::Text("Hello ".into()),
            ProviderEvent::Text("world".into()),
            ProviderEvent::Done,
        ]),
        answer(),
    ]);
    let c = conversation(provider.clone(), vec![]);
    let (_, mut events) = c.subscribe();
    let (_, disconnected) = c.subscribe();
    drop(disconnected);
    let run = c.submit("Hi".into()).unwrap();
    assert!(c.submit("Busy".into()).is_err());
    let id = run.operation_id.clone();
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert!(!c.cancel(&id));
    let deltas: Vec<_> = event_kinds(&mut events)
        .into_iter()
        .filter_map(|e| {
            if let EventKind::Text { delta, .. } = e {
                Some(delta)
            } else {
                None
            }
        })
        .collect();
    assert_eq!(deltas, ["Hello ", "world"]);
    c.snapshot().messages.clear();
    assert_eq!(c.snapshot().messages.len(), 2);
    complete(c.submit("Next prompt".into()).unwrap()).await;
    assert_eq!(
        provider.requests.lock().unwrap()[1].messages,
        vec![
            ContextMessage::User { text: "Hi".into() },
            ContextMessage::Assistant {
                text: "Hello world".into(),
                calls: vec![]
            },
            ContextMessage::User {
                text: "Next prompt".into()
            }
        ]
    );
}
#[tokio::test]
async fn approval_authorizes_only_exact_pending_operation_once() {
    let executions = Arc::new(AtomicUsize::new(0));
    let counter = executions.clone();
    let provider = FakeProvider::new(vec![
        response(vec![call("a"), ProviderEvent::Done]),
        answer(),
    ]);
    let c = conversation(
        provider.clone(),
        vec![tool(Some("Apply exact action"), move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
            async { Ok("changed".into()) }
        })],
    );
    let run = c.submit("Change".into()).unwrap();
    let a = approval(&c).await;
    assert_eq!(executions.load(Ordering::SeqCst), 0);
    assert!(!c.resolve_approval("stale", &a.id, true));
    assert!(!c.resolve_approval(&run.operation_id, "stale", true));
    assert!(c.resolve_approval(&run.operation_id, &a.id, true));
    assert!(!c.resolve_approval(&run.operation_id, &a.id, true));
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(executions.load(Ordering::SeqCst), 1);
    assert_eq!(
        provider.requests.lock().unwrap()[1].messages.last(),
        Some(&ContextMessage::Tool {
            call_id: "a".into(),
            text: "changed".into(),
            outcome: ToolOutcome::Completed
        })
    );
}
#[tokio::test]
async fn denial_produces_tool_result_without_execution() {
    let p = FakeProvider::new(vec![
        response(vec![call("a"), ProviderEvent::Done]),
        answer(),
    ]);
    let c = conversation(
        p,
        vec![tool(Some("approve"), |_| async {
            panic!("denied action executed")
        })],
    );
    let run = c.submit("Change".into()).unwrap();
    let a = approval(&c).await;
    c.resolve_approval(&run.operation_id, &a.id, false);
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(outcomes(&c), [ToolOutcome::Denied]);
}
#[tokio::test]
async fn cancellation_withdraws_approval_pairs_all_calls_and_retains_context() {
    let p = FakeProvider::new(vec![
        response(vec![call("a"), call("b"), ProviderEvent::Done]),
        answer(),
    ]);
    let c = conversation(
        p.clone(),
        vec![tool(Some("approve"), |_| async {
            panic!("cancelled action executed")
        })],
    );
    let run = c.submit("Change".into()).unwrap();
    let a = approval(&c).await;
    let old = run.operation_id.clone();
    assert!(c.cancel(&old));
    assert!(!c.resolve_approval(&old, &a.id, true));
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(p.count(), 1);
    assert!(c.snapshot().approval.is_none());
    assert_eq!(
        outcomes(&c),
        [ToolOutcome::NotExecuted, ToolOutcome::NotExecuted]
    );
    let next = c.submit("Other work".into()).unwrap();
    assert!(!c.cancel(&old));
    complete(next).await;
    assert_eq!(
        p.requests.lock().unwrap()[1]
            .messages
            .iter()
            .filter(|m| matches!(m, ContextMessage::Tool { .. }))
            .count(),
        2
    );
}
#[tokio::test]
async fn cancelled_streaming_remains_in_context_as_an_incomplete_attempt() {
    let entered = CancellationToken::new();
    let signal = entered.clone();
    let p = FakeProvider::new(vec![
        script(move |r| {
            Box::pin(
                async_stream::try_stream! {yield ProviderEvent::Text("Partial".into());signal.cancel();r.cancel.cancelled().await;Err(Error::Cancelled)?;},
            )
        }),
        answer(),
    ]);
    let c = conversation(p.clone(), vec![]);
    let run = c.submit("First".into()).unwrap();
    entered.cancelled().await;
    c.cancel(&run.operation_id);
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert!(
        matches!(&c.snapshot().messages[1],Message::Assistant{text,status:MessageStatus::Interrupted,..} if text=="Partial")
    );
    complete(c.submit("Next".into()).unwrap()).await;
    let requests = p.requests.lock().unwrap();
    assert!(matches!(
        &requests[1].messages[1],
        ContextMessage::Assistant { text, calls }
        if text.contains("was interrupted before completion")
            && text.ends_with("Partial") && calls.is_empty()
    ));
    assert_eq!(requests[1].messages.len(), requests[1].message_ids.len());
    assert_eq!(requests[1].message_ids[1], c.snapshot().messages[1].id());
}
#[tokio::test]
async fn incomplete_output_retains_failed_context_without_executing_or_retrying_calls() {
    let p = FakeProvider::new(vec![
        response(vec![ProviderEvent::Text("Partial".into()), call("a")]),
        answer(),
    ]);
    let c = conversation(
        p.clone(),
        vec![tool(None, |_| async { panic!("incomplete call executed") })],
    );
    assert_eq!(
        complete(c.submit("Change".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(p.count(), 1);
    assert!(
        matches!(&c.snapshot().messages[1],Message::Assistant{calls,status:MessageStatus::Failed,..} if calls.is_empty())
    );
    // Recovery keeps the original status/text; only provider context gets a notice.
    let record = c.record();
    record.validate().unwrap();
    let restored = Conversation::new(options(p.clone(), vec![]), Some(record)).unwrap();
    assert_eq!(p.count(), 1);
    assert_eq!(
        complete(restored.submit("Continue explicitly".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert!(outcomes(&restored).is_empty());
    let requests = p.requests.lock().unwrap();
    assert!(matches!(
        &requests[1].messages[2],
        ContextMessage::Assistant { text, calls }
        if text.contains("failed before completion") && text.ends_with("Partial")
            && text.contains("No tool calls from this response were executed") && calls.is_empty()
    ));
    assert_eq!(requests[1].messages.len(), requests[1].message_ids.len());
    assert_eq!(requests[1].message_ids[2], c.snapshot().messages[1].id());
}
#[tokio::test]
async fn duplicate_call_ids_fail_before_execution() {
    let c = conversation(
        FakeProvider::new(vec![response(vec![
            call("a"),
            call("a"),
            ProviderEvent::Done,
        ])]),
        vec![tool(None, |_| async { panic!("duplicate call executed") })],
    );
    assert_eq!(
        complete(c.submit("Change".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert!(outcomes(&c).is_empty());
}
#[tokio::test]
async fn running_tool_cancellation_waits_for_cleanup_and_records_possible_effects() {
    let release = CancellationToken::new();
    let held = release.clone();
    let p = FakeProvider::new(vec![response(vec![
        call("a"),
        call("b"),
        ProviderEvent::Done,
    ])]);
    let c = conversation(
        p.clone(),
        vec![tool(None, move |_| {
            let held = held.clone();
            async move {
                held.cancelled().await;
                Ok("Possibly changed".into())
            }
        })],
    );
    let run = c.submit("Change".into()).unwrap();
    until(&c, |s| s.active_tool_call_id.is_some()).await;
    c.cancel(&run.operation_id);
    assert!(c.busy());
    assert!(c.submit("Overlap".into()).is_err());
    release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(p.count(), 1);
    assert_eq!(
        outcomes(&c),
        [ToolOutcome::Interrupted, ToolOutcome::NotExecuted]
    );
    assert!(
        c.snapshot().messages[2]
            .text()
            .contains("may have had effects")
    );
}
#[tokio::test]
async fn provider_errors_are_safe_and_not_retried() {
    let p = FakeProvider::new(vec![
        script(|_| {
            Box::pin(futures_util::stream::once(async {
                Err(Error::Tool("secret token raw response".into()))
            }))
        }),
        answer(),
    ]);
    let c = conversation(p.clone(), vec![]);
    assert_eq!(
        complete(c.submit("Hi".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert!(
        !serde_json::to_string(&c.snapshot())
            .unwrap()
            .contains("secret token")
    );
    assert_eq!(p.count(), 1);
    complete(c.submit("Next request".into()).unwrap()).await;
    let requests = p.requests.lock().unwrap();
    assert!(matches!(
        &requests[1].messages[1],
        ContextMessage::Assistant { text, calls }
        if text.contains("failed before completion") && calls.is_empty()
    ));
    assert!(
        !serde_json::to_string(&requests[1].messages)
            .unwrap()
            .contains("secret token")
    );
}
#[tokio::test]
async fn default_step_limit_allows_128_steps_but_not_a_129th_request() {
    for tool_steps in [127, 128] {
        let mut scripts = (0..tool_steps)
            .map(|i| response(vec![call(&format!("call-{i}")), ProviderEvent::Done]))
            .collect::<Vec<_>>();
        scripts.push(answer());
        let p = FakeProvider::new(scripts);
        let c = conversation(p.clone(), vec![tool(None, |_| async { Ok("done".into()) })]);
        let op = complete(c.submit("Run tools".into()).unwrap()).await;
        assert_eq!(p.count(), 128);
        assert_eq!(outcomes(&c).len(), tool_steps);
        if tool_steps == 127 {
            assert_eq!(op.state, OperationState::Completed);
        } else {
            assert_eq!(op.state, OperationState::Failed);
            assert!(op.error.unwrap().contains("step limit"));
        }
    }
}
#[tokio::test]
async fn step_limit_stops_tool_loop_without_another_request() {
    let p = FakeProvider::new(vec![response(vec![call("a"), ProviderEvent::Done])]);
    let mut options = options(p.clone(), vec![tool(None, |_| async { Ok("done".into()) })]);
    options.max_steps = 1;
    let c = Conversation::new(options, None).unwrap();
    let op = complete(c.submit("Change".into()).unwrap()).await;
    assert_eq!(op.state, OperationState::Failed);
    assert!(op.error.unwrap().contains("step limit"));
    assert_eq!(p.count(), 1);
}
#[tokio::test]
async fn cancellation_before_startup_sends_no_inference() {
    let p = FakeProvider::new(vec![]);
    let c = conversation(p.clone(), vec![]);
    let run = c.submit("Cancel".into()).unwrap();
    assert!(c.cancel(&run.operation_id));
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(p.count(), 0);
}
#[tokio::test]
async fn cancellation_after_approval_before_execution_prevents_effects() {
    let c = conversation(
        FakeProvider::new(vec![response(vec![call("a"), ProviderEvent::Done])]),
        vec![tool(Some("approve"), |_| async {
            panic!("cancelled action executed")
        })],
    );
    let run = c.submit("Change".into()).unwrap();
    let a = approval(&c).await;
    c.resolve_approval(&run.operation_id, &a.id, true);
    c.cancel(&run.operation_id);
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert!(c.snapshot().approval.is_none());
    assert_eq!(outcomes(&c), [ToolOutcome::NotExecuted]);
}
#[tokio::test]
async fn preparation_errors_never_execute_or_expose_raw_errors() {
    let tool = Arc::new(TestTool {
        approval: None,
        fail_preparation: true,
        executor: Arc::new(|_| Box::pin(async { panic!("preparation failed") })),
    });
    let p = FakeProvider::new(vec![
        response(vec![call("a"), ProviderEvent::Done]),
        answer(),
    ]);
    let c = conversation(p.clone(), vec![tool]);
    assert_eq!(
        complete(c.submit("Change".into()).unwrap()).await.state,
        OperationState::Completed
    );
    assert_eq!(outcomes(&c), [ToolOutcome::Failed]);
    assert!(c.snapshot().messages[2].text().contains("did not execute"));
    assert!(matches!(
        p.requests.lock().unwrap()[1].messages.last(),
        Some(ContextMessage::Tool { call_id, text, outcome: ToolOutcome::Failed })
        if call_id == "a" && text.contains("did not execute")
    ));
}
#[tokio::test]
async fn manager_conversations_have_independent_cancellation_and_context() {
    let a_started = CancellationToken::new();
    let b_started = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = b_started.clone();
    let held = release.clone();
    let a = FakeProvider::new(vec![waiting(a_started.clone())]);
    let b = FakeProvider::new(vec![script(move |_| {
        Box::pin(
            async_stream::try_stream! {ready.cancel();held.cancelled().await;yield ProviderEvent::Text("Independent".into());yield ProviderEvent::Done;},
        )
    })]);
    let manager = AgentManager::default();
    let first = manager.create(options(a.clone(), vec![])).await.unwrap();
    let second = manager.create(options(b.clone(), vec![])).await.unwrap();
    let run_a = first.submit("First".into()).unwrap();
    let run_b = second.submit("Second".into()).unwrap();
    a_started.cancelled().await;
    b_started.cancelled().await;
    assert_eq!(
        manager
            .list()
            .unwrap()
            .iter()
            .filter(|s| s.operation.as_ref().unwrap().state == OperationState::Running)
            .count(),
        2
    );
    manager.delete(&first.id).await.unwrap();
    assert_eq!(complete(run_a).await.state, OperationState::Interrupted);
    assert!(second.busy());
    release.cancel();
    assert_eq!(complete(run_b).await.state, OperationState::Completed);
    assert_eq!(
        b.requests.lock().unwrap()[0].messages,
        vec![ContextMessage::User {
            text: "Second".into()
        }]
    );
    assert_eq!(a.count(), 1);
    assert!(manager.get(&first.id).is_err());
    assert_eq!(manager.list().unwrap().len(), 1);
    manager.close().await.unwrap();
}
