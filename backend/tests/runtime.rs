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
async fn cancelled_streaming_stays_visible_but_not_in_completed_context() {
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
    assert!(
        !p.requests.lock().unwrap()[1]
            .messages
            .iter()
            .any(|m| matches!(m, ContextMessage::Assistant { .. }))
    );
}
#[tokio::test]
async fn incomplete_output_never_executes_calls_or_retries() {
    let p = FakeProvider::new(vec![response(vec![
        ProviderEvent::Text("Partial".into()),
        call("a"),
    ])]);
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
    let p = FakeProvider::new(vec![script(|_| {
        Box::pin(futures_util::stream::once(async {
            Err(Error::Tool("secret token raw response".into()))
        }))
    })]);
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
    let c = conversation(p, vec![tool]);
    assert_eq!(
        complete(c.submit("Change".into()).unwrap()).await.state,
        OperationState::Completed
    );
    assert_eq!(outcomes(&c), [ToolOutcome::Failed]);
    assert!(c.snapshot().messages[2].text().contains("did not execute"));
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
    assert!(manager.delete(&first.id).await.is_err());
    first.cancel(&run_a.operation_id);
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
    manager.delete(&first.id).await.unwrap();
    assert_eq!(manager.list().unwrap().len(), 1);
    manager.close().await.unwrap();
}
