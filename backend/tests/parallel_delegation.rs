mod support;
use async_trait::async_trait;
use exec_agent::{Result, core::*, manager::AgentManager};
use futures_util::stream::BoxStream;
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::*;
use tokio_util::sync::CancellationToken;

fn batch(tasks: serde_json::Value) -> ProviderEvent {
    ProviderEvent::ToolCall(ToolCall {
        id: "batch".into(),
        name: "delegate".into(),
        arguments: serde_json::json!({"tasks": tasks})
            .as_object()
            .unwrap()
            .clone(),
    })
}
async fn setup(
    provider: Arc<dyn ChatProvider>,
    tools: Vec<Arc<dyn Tool>>,
    workspace: &std::path::Path,
) -> (Arc<AgentManager>, Arc<Conversation>) {
    let manager = Arc::new(AgentManager::default());
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    let parent = manager
        .create_session(
            provider,
            tools,
            Some("fake".into()),
            workspace.to_string_lossy().into_owned(),
            None,
            Some(vec![]),
        )
        .await
        .unwrap();
    (manager, parent)
}
#[tokio::test]
async fn children_overlap_return_ordered_results_and_are_deleted() {
    let workspace = directory();
    let barrier = Arc::new(tokio::sync::Barrier::new(2));
    let children = (0..2).map(|_| {
        let barrier = barrier.clone();
        script(move |request| Box::pin(async_stream::try_stream! {
            barrier.wait().await;
            let ContextMessage::User { text, .. } = &request.messages[0] else { panic!("missing task") };
            yield ProviderEvent::Text(format!("Answer to {text}"));
            yield ProviderEvent::Done;
        }))
    });
    let mut scripts = vec![response(vec![
        batch(
            serde_json::json!([{"task":"first", "title":"First review"}, {"task":"second", "title":"Second review"}]),
        ),
        ProviderEvent::Done,
    ])];
    scripts.extend(children);
    scripts.push(answer());
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(provider.clone(), vec![], workspace.path()).await;
    assert_eq!(
        complete(manager.submit(&parent.id, "Delegate".into()).await.unwrap())
            .await
            .state,
        OperationState::Completed
    );
    let snapshot = parent.snapshot();
    let text = snapshot
        .messages
        .iter()
        .find_map(|m| match m {
            Message::Tool { text, .. } => Some(text),
            _ => None,
        })
        .unwrap();
    assert!(text.find("Answer to first").unwrap() < text.find("Answer to second").unwrap());
    assert_eq!(manager.list().unwrap().len(), 1);
    assert_eq!(provider.count(), 4);
}
#[tokio::test]
async fn cancellation_waits_for_every_child_executor_cleanup() {
    let workspace = directory();
    let entered = Arc::new(tokio::sync::Barrier::new(3));
    let cleanup = CancellationToken::new();
    let provider = FakeProvider::new(vec![
        response(vec![
            batch(
                serde_json::json!([{"task":"first", "title":"First review"}, {"task":"second", "title":"Second review"}]),
            ),
            ProviderEvent::Done,
        ]),
        response(vec![call("effect-one"), ProviderEvent::Done]),
        response(vec![call("effect-two"), ProviderEvent::Done]),
    ]);
    let effect = tool(None, {
        let entered = entered.clone();
        let cleanup = cleanup.clone();
        move |context| {
            let entered = entered.clone();
            let cleanup = cleanup.clone();
            async move {
                entered.wait().await;
                context.cancel.cancelled().await;
                cleanup.cancelled().await;
                Err(exec_agent::Error::Cancelled)
            }
        }
    });
    let (manager, parent) = setup(provider.clone(), vec![effect], workspace.path()).await;
    let mut run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), entered.wait())
        .await
        .unwrap();
    let mut titles: Vec<_> = manager
        .list()
        .unwrap()
        .into_iter()
        .filter(|s| s.metadata.parent.is_some())
        .map(|s| s.metadata.title.unwrap())
        .collect();
    titles.sort();
    assert_eq!(titles, ["First review", "Second review"]);
    assert!(parent.cancel(&run.operation_id));
    assert!(
        tokio::time::timeout(Duration::from_millis(50), &mut run.completion)
            .await
            .is_err()
    );
    assert_eq!(manager.list().unwrap().len(), 3);
    cleanup.cancel();
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(manager.list().unwrap().len(), 1);
    let snapshot = parent.snapshot();
    let results = snapshot
        .messages
        .iter()
        .find_map(|message| match message {
            Message::Tool {
                details: Some(ToolDetails::Delegation { results, .. }),
                ..
            } => Some(results),
            _ => None,
        })
        .unwrap();
    assert_eq!(results.len(), 2);
    assert!(
        results
            .iter()
            .all(|result| result.outcome == ToolOutcome::Interrupted)
    );
    assert_eq!(outcomes(&parent), [ToolOutcome::Interrupted]);
    parent.record().validate().unwrap();
    assert_eq!(provider.count(), 3);
}
#[tokio::test]
async fn invalid_delegations_never_create_children() {
    let mut invalid = vec![
        serde_json::json!({}),
        serde_json::json!({"task": "work"}),
        serde_json::json!({"title": "Review"}),
        serde_json::json!({"task": "work", "title": "Review", "tasks": [{"task":"other", "title":"Other"}]}),
        serde_json::json!({"tasks": [{"task":"work", "title":"Review"}], "title":"Unexpected"}),
        serde_json::json!({"tasks": []}),
        serde_json::json!({"tasks": ["legacy task"]}),
        serde_json::json!({"tasks": [42]}),
        serde_json::json!({"tasks": vec![serde_json::json!({"task":"work", "title":"Review"}); 9]}),
        serde_json::json!({"tasks": [{"task":"work"}]}),
        serde_json::json!({"tasks": [{"title":"Review"}]}),
        serde_json::json!({"tasks": [{"task":"work", "title":"Review", "extra":true}]}),
    ];
    for title in [
        serde_json::Value::Null,
        serde_json::json!(42),
        serde_json::json!(""),
        serde_json::json!("   "),
        serde_json::json!("x".repeat(61)),
        serde_json::json!("é".repeat(61)),
        serde_json::json!("two\nlines"),
        serde_json::json!("two\rlines"),
        serde_json::json!("tab\ttitle"),
        serde_json::json!("nul\0title"),
        serde_json::json!("line\u{2028}separator"),
        serde_json::json!("paragraph\u{2029}separator"),
    ] {
        invalid.push(serde_json::json!({"task":"work", "title":title}));
        // A valid first entry must not be created if any later entry is invalid.
        invalid.push(serde_json::json!({"tasks":[{"task":"valid", "title":"Valid"}, {"task":"work", "title":title}]}));
    }
    for task in [
        "".to_owned(),
        "  ".to_owned(),
        "nul\0task".to_owned(),
        "x".repeat(16 * 1024 + 1),
    ] {
        invalid.push(serde_json::json!({"task":task, "title":"Review"}));
        invalid.push(serde_json::json!({"tasks":[{"task":"valid", "title":"Valid"}, {"task":task, "title":"Review"}]}));
    }
    for arguments in invalid {
        let workspace = directory();
        let provider = FakeProvider::new(vec![
            response(vec![
                ProviderEvent::ToolCall(ToolCall {
                    id: "invalid".into(),
                    name: "delegate".into(),
                    arguments: arguments.as_object().unwrap().clone(),
                }),
                ProviderEvent::Done,
            ]),
            answer(),
        ]);
        let (manager, parent) = setup(provider.clone(), vec![], workspace.path()).await;
        assert_eq!(
            complete(manager.submit(&parent.id, "Delegate".into()).await.unwrap())
                .await
                .state,
            OperationState::Completed
        );
        assert_eq!(outcomes(&parent), vec![ToolOutcome::Failed]);
        assert_eq!(manager.list().unwrap().len(), 1);
        assert_eq!(provider.count(), 2);
    }
}
#[tokio::test]
async fn failed_child_does_not_drop_siblings_and_returned_sessions_are_deleted() {
    let workspace = directory();
    let barrier = Arc::new(tokio::sync::Barrier::new(2));
    let mut scripts = vec![response(vec![
        batch(
            serde_json::json!([{"task":"fail", "title":"Failure check"}, {"task":"succeed", "title":"Success check"}]),
        ),
        ProviderEvent::Done,
    ])];
    for _ in 0..2 {
        let barrier = barrier.clone();
        scripts.push(script(move |request| Box::pin(async_stream::try_stream! {
            barrier.wait().await;
            if matches!(&request.messages[0], ContextMessage::User { text, .. } if text == "fail") {
                Err(exec_agent::Error::Internal)?;
            }
            yield ProviderEvent::Text("Sibling completed".into());
            yield ProviderEvent::Done;
        })));
    }
    scripts.push(answer());
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(provider.clone(), vec![], workspace.path()).await;
    assert_eq!(
        complete(manager.submit(&parent.id, "Delegate".into()).await.unwrap())
            .await
            .state,
        OperationState::Completed
    );
    let children: Vec<_> = manager
        .list()
        .unwrap()
        .into_iter()
        .filter(|s| s.metadata.parent.is_some())
        .collect();
    assert!(children.is_empty());
    assert!(parent.snapshot().messages.iter().any(|m| matches!(m, Message::Tool { text, .. } if text.contains("failed") && text.contains("Sibling completed"))));
    assert_eq!(provider.count(), 4);
}

#[tokio::test]
async fn steering_a_child_preserves_approval_and_reaches_its_next_response() {
    let workspace = directory();
    let provider = FakeProvider::new(vec![
        response(vec![
            batch(serde_json::json!([{"task":"original task", "title":"Original review"}])),
            ProviderEvent::Done,
        ]),
        response(vec![call("effect"), ProviderEvent::Done]),
        answer(),
        answer(),
    ]);
    let (manager, parent) = setup(
        provider.clone(),
        vec![tool(Some("Approve"), |_| async {
            Ok("Action completed".into())
        })],
        workspace.path(),
    )
    .await;
    let mut settings = parent.snapshot().configuration.settings;
    settings.auto_approve = false;
    manager.update_settings(&parent.id, settings).await.unwrap();
    let run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    let child = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(child) = manager
                .list()
                .unwrap()
                .into_iter()
                .find(|s| s.metadata.parent.is_some() && s.approval.is_some())
            {
                break child;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let operation = child.operation.unwrap().id;
    let approval = child.approval.unwrap().id;
    manager
        .steer(&child.id, &operation, "Explain the result afterward".into())
        .unwrap();
    let session = manager.get(&child.id).unwrap();
    assert_eq!(session.snapshot().approval.unwrap().id, approval);
    assert_eq!(provider.count(), 2);
    assert!(session.resolve_approval(&operation, &approval, true));
    assert_eq!(complete(run).await.state, OperationState::Completed);
    let requests = provider.requests.lock().unwrap();
    assert!(requests[2].messages.iter().any(|m| matches!(m,
        ContextMessage::Tool { outcome: ToolOutcome::Completed, text, .. }
        if text == "Action completed"
    )));
    assert!(matches!(requests[2].messages.last(),
        Some(ContextMessage::User { text }) if text == "Explain the result afterward"
    ));
    assert_eq!(requests.len(), 4);
    assert_eq!(manager.list().unwrap().len(), 1);
}

fn sized_batch(id: &str, count: usize) -> ProviderEvent {
    let ProviderEvent::ToolCall(mut call) = batch(serde_json::json!(
        (0..count)
            .map(|i| serde_json::json!({"task": format!("Task {i}"), "title": format!("Task {i}")}))
            .collect::<Vec<_>>()
    )) else {
        unreachable!()
    };
    call.id = id.into();
    ProviderEvent::ToolCall(call)
}

fn high_usage() -> ProviderEvent {
    ProviderEvent::Metadata {
        state: None,
        usage: Some(TokenUsage {
            input_tokens: Some(95),
            output_tokens: Some(0),
            total_tokens: Some(95),
        }),
    }
}

fn delegation_response(id: &str, count: usize, compact: bool) -> Script {
    let mut events = vec![sized_batch(id, count)];
    if compact {
        events.push(high_usage());
    }
    events.push(ProviderEvent::Done);
    response(events)
}

fn gated_answer(entered: CancellationToken, release: CancellationToken, compact: bool) -> Script {
    script(move |_| {
        Box::pin(async_stream::try_stream! {
            entered.cancel();
            release.cancelled().await;
            yield ProviderEvent::Text("Completed answer".into());
            if compact {
                yield high_usage();
            }
            yield ProviderEvent::Done;
        })
    })
}

struct CompactingProvider {
    inner: Arc<FakeProvider>,
    compactions: AtomicUsize,
}
#[async_trait]
impl ChatProvider for CompactingProvider {
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        self.inner.stream(request)
    }
    fn supports_compaction(&self, _: &str) -> bool {
        true
    }
    fn context_window(&self, _: &str) -> Option<u64> {
        Some(100)
    }
    async fn compact(&self, request: ProviderRequest) -> Result<serde_json::Value> {
        assert!(request.tools.iter().any(|t| t.name == "delegate"));
        Ok(serde_json::json!({
            "compacted": self.compactions.fetch_add(1, Ordering::SeqCst)
        }))
    }
}

#[tokio::test]
async fn steering_after_six_children_starts_a_new_budget_without_replacing_the_operation() {
    for compact in [false, true] {
        let workspace = directory();
        let entered = CancellationToken::new();
        let release = CancellationToken::new();
        let mut scripts = vec![delegation_response("first-six", 6, compact)];
        scripts.extend((0..6).map(|_| answer()));
        scripts.push(gated_answer(entered.clone(), release.clone(), compact));
        scripts.push(delegation_response("next-six", 6, compact));
        scripts.extend((0..6).map(|_| answer()));
        // Child deletion and automatic compaction must not refund this turn's six.
        scripts.push(delegation_response("over-budget", 3, false));
        // Rejection must not consume the two remaining reservations either.
        scripts.push(delegation_response("remaining-two", 2, compact));
        scripts.extend((0..2).map(|_| answer()));
        scripts.push(delegation_response("ninth", 1, false));
        scripts.push(answer());
        let inner = FakeProvider::new(scripts);
        let provider = Arc::new(CompactingProvider {
            inner: inner.clone(),
            compactions: AtomicUsize::new(0),
        });
        let (manager, parent) = setup(provider.clone(), vec![], workspace.path()).await;
        let run = manager
            .submit(&parent.id, "First six".into())
            .await
            .unwrap();
        let operation_id = run.operation_id.clone();
        tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
            .await
            .unwrap();
        assert_eq!(manager.list().unwrap().len(), 1); // All six children were deleted.
        let input_id = manager
            .steer(&parent.id, &operation_id, "Next six".into())
            .unwrap();
        // Coalesced inputs get one budget, not eight reservations per queued message.
        manager
            .steer(
                &parent.id,
                &operation_id,
                "Keep the same task titles".into(),
            )
            .unwrap();
        release.cancel();
        let completed = complete(run).await;
        assert_eq!(completed.state, OperationState::Completed);
        assert_eq!(completed.id, operation_id);
        let snapshot = parent.snapshot();
        assert!(snapshot.pending_input.is_empty());
        assert_eq!(
            snapshot
                .messages
                .iter()
                .filter(|m| m.id() == input_id)
                .count(),
            1
        );
        let delegation_outcomes: Vec<_> = snapshot
            .messages
            .iter()
            .filter_map(|m| match m {
                Message::Tool { outcome, .. } if !m.is_compaction() => Some(*outcome),
                _ => None,
            })
            .collect();
        assert_eq!(
            delegation_outcomes,
            [
                ToolOutcome::Completed,
                ToolOutcome::Completed,
                ToolOutcome::Failed,
                ToolOutcome::Completed,
                ToolOutcome::Failed,
            ]
        );
        for id in ["over-budget", "ninth"] {
            assert!(snapshot.messages.iter().any(|m| matches!(m,
                Message::Tool { call_id, text, .. }
                if call_id == id && text.contains("eight sub-agents per turn")
            )));
        }
        assert_eq!(manager.list().unwrap().len(), 1);
        assert_eq!(inner.count(), 21);
        assert_eq!(
            provider.compactions.load(Ordering::SeqCst),
            if compact { 4 } else { 0 }
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rapid_completed_turns_get_fresh_budgets_even_with_compacted_history() {
    const TURNS: usize = 32;
    let workspace = directory();
    let mut scripts = vec![];
    for turn in 0..TURNS {
        scripts.push(delegation_response(&format!("turn-{turn}"), 6, false));
        scripts.extend((0..6).map(|_| answer()));
        scripts.push(answer());
    }
    let inner = FakeProvider::new(scripts);
    let provider = Arc::new(CompactingProvider {
        inner: inner.clone(),
        compactions: AtomicUsize::new(0),
    });
    let (manager, parent) = setup(provider.clone(), vec![], workspace.path()).await;
    let mut operations = std::collections::HashSet::new();
    for turn in 0..TURNS {
        let run = manager
            .submit(&parent.id, format!("Six tasks for turn {turn}"))
            .await
            .unwrap();
        assert!(operations.insert(run.operation_id.clone()));
        assert_eq!(complete(run).await.state, OperationState::Completed);
        assert_eq!(manager.list().unwrap().len(), 1);
        if turn % 4 == 3 {
            assert_eq!(
                complete(manager.compact(&parent.id).unwrap()).await.state,
                OperationState::Completed
            );
        }
    }
    let snapshot = parent.snapshot();
    assert_eq!(
        snapshot
            .messages
            .iter()
            .filter(|m| matches!(m, Message::User { .. }))
            .count(),
        TURNS
    );
    assert_eq!(
        outcomes(&parent),
        vec![ToolOutcome::Completed; TURNS + TURNS / 4]
    );
    assert_eq!(inner.count(), TURNS * 8);
    assert_eq!(provider.compactions.load(Ordering::SeqCst), TURNS / 4);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rapid_steering_during_child_execution_gets_fresh_budgets_after_cleanup() {
    const TURNS: usize = 24;
    let workspace = directory();
    let mut gates = vec![];
    let mut scripts = vec![];
    for turn in 0..TURNS {
        let entered = CancellationToken::new();
        let release = CancellationToken::new();
        scripts.push(delegation_response(&format!("turn-{turn}"), 6, false));
        scripts.push(gated_answer(entered.clone(), release.clone(), false));
        scripts.extend((0..5).map(|_| answer()));
        gates.push((entered, release));
    }
    scripts.push(answer());
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(provider.clone(), vec![], workspace.path()).await;
    let run = manager
        .submit(&parent.id, "First six".into())
        .await
        .unwrap();
    let operation_id = run.operation_id.clone();
    for (turn, (entered, release)) in gates.into_iter().enumerate() {
        tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
            .await
            .unwrap();
        // Fast siblings may already be durably published and removed; the gated
        // child must still be owned while the next turn is queued.
        let sessions = manager.list().unwrap();
        assert!((2..=7).contains(&sessions.len()));
        assert!(sessions.iter().any(|s| s.metadata.parent.is_some()
            && s.operation.as_ref().is_some_and(|op| op.state.active())));
        let snapshot = parent.snapshot();
        assert_eq!(snapshot.operation.unwrap().id, operation_id);
        assert_eq!(snapshot.active_tool_call_id, Some(format!("turn-{turn}")));
        if turn + 1 < TURNS {
            manager
                .steer(&parent.id, &operation_id, format!("Next six: {}", turn + 1))
                .unwrap();
        }
        release.cancel();
    }
    let completed = complete(run).await;
    assert_eq!(completed.state, OperationState::Completed);
    assert_eq!(completed.id, operation_id);
    assert_eq!(outcomes(&parent), vec![ToolOutcome::Completed; TURNS]);
    assert_eq!(manager.list().unwrap().len(), 1);
    assert_eq!(provider.count(), TURNS * 7 + 1);
}
