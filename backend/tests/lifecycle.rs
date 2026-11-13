mod support;
use exec_agent::{Error, core::*};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use support::*;
use tokio_util::sync::CancellationToken;
#[tokio::test]
async fn live_ownership_excludes_approval_and_intent_survives_cancellation_and_never_restores() {
    let intent = CancellationToken::new();
    let allow = CancellationToken::new();
    let cleanup = CancellationToken::new();
    let executions = Arc::new(AtomicUsize::new(0));
    let counter = executions.clone();
    let held = cleanup.clone();
    let tools = vec![tool(Some("Exact action"), move |_| {
        counter.fetch_add(1, Ordering::SeqCst);
        let held = held.clone();
        async move {
            held.cancelled().await;
            Ok("effect settled".into())
        }
    })];
    let provider = FakeProvider::new(vec![response(vec![
        call("first"),
        call("second"),
        ProviderEvent::Done,
    ])]);
    let mut config = options(provider.clone(), tools.clone());
    let saved = intent.clone();
    let blocked = allow.clone();
    config.checkpoint = Some(checkpoint(move |r| {
        let saved = saved.clone();
        let blocked = blocked.clone();
        async move {
            if r.executing_tool_id.as_deref() == Some("first") {
                saved.cancel();
                blocked.cancelled().await;
            }
            Ok(())
        }
    }));
    let c = Conversation::new(config, None).unwrap();
    let (_, mut events) = c.subscribe();
    let run = c.submit("Act".into()).unwrap();
    let a = approval(&c).await;
    assert!(c.snapshot().active_tool_call_id.is_none());
    assert_eq!(executions.load(Ordering::SeqCst), 0);
    c.resolve_approval(&run.operation_id, &a.id, true);
    intent.cancelled().await;
    assert_eq!(c.record().executing_tool_id.as_deref(), Some("first"));
    assert!(c.snapshot().active_tool_call_id.is_none());
    let recovered = Conversation::new(options(provider, tools), Some(c.record())).unwrap();
    assert!(recovered.snapshot().active_tool_call_id.is_none());
    assert!(recovered.snapshot().approval.is_none());
    assert_eq!(
        recovered.snapshot().operation.unwrap().state,
        OperationState::Interrupted
    );
    assert_eq!(executions.load(Ordering::SeqCst), 0);
    allow.cancel();
    until(&c, |s| s.active_tool_call_id.is_some()).await;
    assert_eq!(executions.load(Ordering::SeqCst), 1);
    c.cancel(&run.operation_id);
    assert_eq!(c.snapshot().active_tool_call_id.as_deref(), Some("first"));
    assert!(c.busy());
    cleanup.cancel();
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    let kinds = event_kinds(&mut events);
    assert_eq!(
        kinds
            .iter()
            .filter(|e| matches!(e, EventKind::ToolStarted { .. }))
            .count(),
        1
    );
    let finished: Vec<_> = kinds
        .into_iter()
        .filter_map(|e| {
            if let EventKind::ToolFinished {
                call_id,
                message_id,
                outcome,
            } = e
            {
                assert!(c.snapshot().messages.iter().any(|m| m.id() == message_id));
                Some((call_id, outcome))
            } else {
                None
            }
        })
        .collect();
    assert_eq!(
        finished,
        [
            ("first".into(), ToolOutcome::Interrupted),
            ("second".into(), ToolOutcome::NotExecuted)
        ]
    );
    assert!(c.snapshot().active_tool_call_id.is_none());
}
async fn lifecycle(phase: &str) {
    let phase = phase.to_owned();
    let execute_phase = phase.clone();
    let approval_required = matches!(phase.as_str(), "denied" | "cancelled approval");
    let tool = Arc::new(TestTool {
        approval: approval_required.then(|| "Please approve".into()),
        fail_preparation: phase == "preparation",
        executor: Arc::new(move |_| {
            let phase = execute_phase.clone();
            Box::pin(async move {
                if phase == "execution failure" {
                    return Err(Error::Internal);
                }
                Ok("done".into())
            })
        }),
    });
    let c = conversation(
        FakeProvider::new(vec![
            response(vec![call("first"), ProviderEvent::Done]),
            answer(),
        ]),
        vec![tool],
    );
    let (_, mut events) = c.subscribe();
    let run = c.submit("Act".into()).unwrap();
    if approval_required {
        let a = approval(&c).await;
        if phase == "cancelled approval" {
            c.cancel(&run.operation_id);
        } else {
            c.resolve_approval(&run.operation_id, &a.id, false);
        }
    }
    complete(run).await;
    let kinds = event_kinds(&mut events);
    assert_eq!(
        kinds
            .iter()
            .filter(|e| matches!(e, EventKind::ToolStarted { .. }))
            .count(),
        usize::from(matches!(phase.as_str(), "execution failure" | "completed"))
    );
    let expected = match phase.as_str() {
        "denied" => ToolOutcome::Denied,
        "completed" => ToolOutcome::Completed,
        "cancelled approval" => ToolOutcome::NotExecuted,
        _ => ToolOutcome::Failed,
    };
    let finished: Vec<_> = kinds
        .iter()
        .filter_map(|e| {
            if let EventKind::ToolFinished { outcome, .. } = e {
                Some(*outcome)
            } else {
                None
            }
        })
        .collect();
    assert_eq!(finished, [expected]);
    assert!(c.snapshot().active_tool_call_id.is_none());
}
macro_rules! phase {
    ($name:ident,$phase:literal) => {
        #[tokio::test]
        async fn $name() {
            lifecycle($phase).await;
        }
    };
}
phase!(denied_lifecycle, "denied");
phase!(cancelled_approval_lifecycle, "cancelled approval");
phase!(preparation_failure_lifecycle, "preparation");
phase!(executor_failure_lifecycle, "execution failure");
phase!(completed_lifecycle, "completed");
async fn failed_boundary(boundary: &str) {
    let executions = Arc::new(AtomicUsize::new(0));
    let counter = executions.clone();
    let mut config = options(
        FakeProvider::new(vec![response(vec![
            call("first"),
            call("second"),
            ProviderEvent::Done,
        ])]),
        vec![tool(None, move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
            async { Ok("done".into()) }
        })],
    );
    let intent = boundary == "intent";
    config.checkpoint = Some(checkpoint(move |r| async move {
        if (intent && r.executing_tool_id.is_some())
            || (!intent && r.messages.iter().any(|m| matches!(m, Message::Tool { .. })))
        {
            Err(Error::Internal)
        } else {
            Ok(())
        }
    }));
    let c = Conversation::new(config, None).unwrap();
    let (_, mut events) = c.subscribe();
    assert_eq!(
        complete(c.submit("Act".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(executions.load(Ordering::SeqCst), usize::from(!intent));
    let kinds = event_kinds(&mut events);
    assert_eq!(
        kinds
            .iter()
            .filter(|e| matches!(e, EventKind::ToolStarted { .. }))
            .count(),
        usize::from(!intent)
    );
    assert_eq!(
        kinds
            .iter()
            .filter(|e| matches!(e, EventKind::ToolFinished { .. }))
            .count(),
        2
    );
    assert_eq!(
        outcomes(&c),
        [
            if intent {
                ToolOutcome::NotExecuted
            } else {
                ToolOutcome::Completed
            },
            ToolOutcome::NotExecuted
        ]
    );
    assert!(c.snapshot().active_tool_call_id.is_none());
    assert!(c.submit("Retry".into()).is_err());
}
#[tokio::test]
async fn failed_intent_checkpoint_publishes_exactly_one_result_per_call() {
    failed_boundary("intent").await;
}
#[tokio::test]
async fn failed_result_checkpoint_publishes_exactly_one_result_per_call() {
    failed_boundary("result").await;
}
