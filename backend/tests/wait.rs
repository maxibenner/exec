mod support;

use async_trait::async_trait;
use exec_agent::{
    Error, Result,
    core::*,
    manager::AgentManager,
    service::{ServiceOptions, start_service},
    storage::ConversationStore,
    tools::create_wait_tool,
};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::*;
use tokio::time::advance;

fn wait_call(id: &str, seconds: u64, prompt: &str) -> ProviderEvent {
    ProviderEvent::ToolCall(ToolCall {
        id: id.into(),
        name: "wait".into(),
        arguments: json!({
            "duration_seconds": seconds,
            "description": "Wait for the next check",
            "wake_prompt": prompt,
        })
        .as_object()
        .unwrap()
        .clone(),
    })
}

fn wait_response(id: &str, seconds: u64, prompt: &str) -> Script {
    response(vec![wait_call(id, seconds, prompt), ProviderEvent::Done])
}

async fn active_wait(c: &Conversation, call_id: &str) -> ConversationSnapshot {
    // ToolStarted is published after the executor's first poll, so its timer is armed.
    let snapshot = until(c, |s| s.active_tool_call_id.as_deref() == Some(call_id)).await;
    assert_eq!(snapshot.active_tool_name.as_deref(), Some("wait"));
    assert_eq!(
        snapshot.operation.as_ref().unwrap().state,
        OperationState::Running
    );
    assert!(snapshot.approval.is_none());
    snapshot
}

fn wake_results(request: &ProviderRequest) -> Vec<(String, Value)> {
    request
        .messages
        .iter()
        .filter_map(|message| match message {
            ContextMessage::Tool {
                call_id,
                text,
                outcome: ToolOutcome::Completed,
            } => Some((call_id.clone(), serde_json::from_str(text).unwrap())),
            _ => None,
        })
        .collect()
}

// Isolated checkpoints round-trip through the persisted schema, without disk or credentials.
#[derive(Default)]
struct MemoryStore(Mutex<Vec<ConversationRecord>>);

#[async_trait]
impl Checkpoint for MemoryStore {
    async fn save(&self, record: ConversationRecord) -> Result<()> {
        record.validate()?;
        let record: ConversationRecord = serde_json::from_slice(&serde_json::to_vec(&record)?)?;
        let mut records = self.0.lock().unwrap();
        records.retain(|saved| saved.id != record.id);
        records.push(record);
        Ok(())
    }
}

#[async_trait]
impl ConversationStore for MemoryStore {
    async fn load(&self) -> Result<Vec<ConversationRecord>> {
        Ok(self.0.lock().unwrap().clone())
    }
    async fn delete(&self, id: String) -> Result<()> {
        self.0.lock().unwrap().retain(|record| record.id != id);
        Ok(())
    }
    async fn close(&self) -> Result<()> {
        Ok(())
    }
}

#[tokio::test(start_paused = true)]
async fn expiry_continues_once_with_exact_prompt_as_tool_output() {
    let prompt = "  Check \"build\" status.\nReport café results; do not assume success.  ";
    let provider = FakeProvider::new(vec![wait_response("pause", 10, prompt), answer()]);
    let c = conversation(provider.clone(), vec![create_wait_tool()]);
    let (_, mut events) = c.subscribe();
    let run = c.submit("Check later".into()).unwrap();
    let operation_id = run.operation_id.clone();
    active_wait(&c, "pause").await;

    advance(Duration::from_secs(9)).await;
    tokio::task::yield_now().await;
    assert_eq!(provider.count(), 1, "provider invoked before expiry");
    assert!(outcomes(&c).is_empty());
    assert_eq!(
        active_wait(&c, "pause").await.operation.unwrap().id,
        operation_id
    );

    advance(Duration::from_secs(1)).await;
    let finished = complete(run).await;
    assert_eq!(finished.state, OperationState::Completed);
    assert_eq!(finished.id, operation_id);
    assert_eq!(outcomes(&c), [ToolOutcome::Completed]);
    assert!(c.snapshot().active_tool_name.is_none());
    assert!(c.snapshot().active_tool_call_id.is_none());
    assert!(!c.busy());
    {
        let requests = provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(
            wake_results(&requests[1]),
            vec![(
                "pause".into(),
                json!({
                    "elapsed_seconds": 10, "wake_prompt": prompt,
                })
            )]
        );
        let users: Vec<_> = requests[1]
            .messages
            .iter()
            .filter_map(|m| match m {
                ContextMessage::User { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(
            users,
            ["Check later"],
            "wake prompt must not become a user instruction"
        );
    }
    let kinds = event_kinds(&mut events);
    assert_eq!(
        kinds
            .iter()
            .filter(|e| matches!(e, EventKind::ToolStarted { .. }))
            .count(),
        1
    );
    assert_eq!(
        kinds
            .iter()
            .filter(|e| matches!(
                e,
                EventKind::ToolFinished {
                    outcome: ToolOutcome::Completed,
                    ..
                }
            ))
            .count(),
        1
    );
    advance(Duration::from_secs(86_400)).await;
    tokio::task::yield_now().await;
    assert_eq!(provider.count(), 2, "one-shot wait fired again");
}

#[tokio::test(start_paused = true)]
async fn repeated_waits_stay_in_the_same_operation() {
    let provider = FakeProvider::new(vec![
        wait_response("first", 10, "Check once"),
        wait_response("second", 20, "Check again"),
        answer(),
    ]);
    let c = conversation(provider.clone(), vec![create_wait_tool()]);
    let run = c.submit("Check twice".into()).unwrap();
    let operation_id = run.operation_id.clone();
    active_wait(&c, "first").await;
    advance(Duration::from_secs(10)).await;
    let second = active_wait(&c, "second").await;
    assert_eq!(second.operation.unwrap().id, operation_id);
    assert_eq!(provider.count(), 2);
    assert_eq!(outcomes(&c), [ToolOutcome::Completed]);

    advance(Duration::from_secs(19)).await;
    tokio::task::yield_now().await;
    assert_eq!(provider.count(), 2);
    assert_eq!(
        active_wait(&c, "second").await.operation.unwrap().id,
        operation_id
    );
    advance(Duration::from_secs(1)).await;
    let finished = complete(run).await;
    assert_eq!(finished.id, operation_id);
    assert_eq!(finished.state, OperationState::Completed);
    assert_eq!(
        outcomes(&c),
        [ToolOutcome::Completed, ToolOutcome::Completed]
    );
    let requests = provider.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert_eq!(
        wake_results(&requests[1]),
        vec![(
            "first".into(),
            json!({
                "elapsed_seconds": 10, "wake_prompt": "Check once",
            })
        )]
    );
    assert_eq!(
        wake_results(&requests[2]),
        vec![
            (
                "first".into(),
                json!({"elapsed_seconds": 10, "wake_prompt": "Check once"})
            ),
            (
                "second".into(),
                json!({"elapsed_seconds": 20, "wake_prompt": "Check again"})
            ),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn waiting_excludes_new_submissions_but_not_independent_conversations() {
    let manager = AgentManager::default();
    let waiting = FakeProvider::new(vec![wait_response("pause", 60, "Check later"), answer()]);
    let other = FakeProvider::new(vec![answer()]);
    let a = manager
        .create(options(waiting.clone(), vec![create_wait_tool()]))
        .await
        .unwrap();
    let b = manager
        .create(options(other.clone(), vec![create_wait_tool()]))
        .await
        .unwrap();
    let run = a.submit("Wait here".into()).unwrap();
    active_wait(&a, "pause").await;
    assert!(matches!(
        a.submit("Conflicting operation".into()),
        Err(Error::Busy)
    ));
    assert_eq!(
        complete(b.submit("Independent work".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert_eq!(other.count(), 1);
    assert_eq!(waiting.count(), 1);
    assert!(a.busy());
    assert!(
        a.snapshot()
            .messages
            .iter()
            .all(|m| m.text() != "Conflicting operation")
    );
    advance(Duration::from_secs(60)).await;
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(waiting.count(), 2);
    manager.close().await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn cancellation_deletion_and_service_shutdown_never_wake() {
    for action in ["cancel", "delete", "shutdown"] {
        let provider = FakeProvider::new(vec![wait_response("pause", 60, "Must not wake")]);
        let store = Arc::new(MemoryStore::default());
        let manager = AgentManager::open(store.clone(), |_| {
            (provider.clone(), vec![create_wait_tool()])
        })
        .await
        .unwrap();
        let c = manager
            .create(options(provider.clone(), vec![create_wait_tool()]))
            .await
            .unwrap();
        let service = if action == "shutdown" {
            Some(
                start_service(ServiceOptions {
                    manager: manager.clone(),
                    provider: provider.clone(),
                    tools: vec![create_wait_tool()],
                    address: "127.0.0.1:0".parse().unwrap(),
                    access: http_access(),
                })
                .await
                .unwrap(),
            )
        } else {
            None
        };
        let run = c.submit("Wait".into()).unwrap();
        active_wait(&c, "pause").await;
        match action {
            "cancel" => assert!(c.cancel(&run.operation_id)),
            "delete" => manager.delete(&c.id).await.unwrap(),
            "shutdown" => service.unwrap().close().await.unwrap(),
            _ => unreachable!(),
        }
        assert_eq!(
            complete(run).await.state,
            OperationState::Interrupted,
            "{action}"
        );
        assert_eq!(outcomes(&c), [ToolOutcome::Interrupted], "{action}");
        assert!(!c.busy());
        assert!(c.snapshot().active_tool_call_id.is_none());
        assert!(c.snapshot().active_tool_name.is_none());
        advance(Duration::from_secs(86_400)).await;
        tokio::task::yield_now().await;
        assert_eq!(provider.count(), 1, "{action} left a wake scheduled");
        let saved = store.load().await.unwrap();
        if action == "delete" {
            assert!(saved.is_empty());
            assert!(manager.get(&c.id).is_err());
        } else {
            assert_eq!(
                saved[0].operation.as_ref().unwrap().state,
                OperationState::Interrupted
            );
            assert!(saved[0].executing_tool_id.is_none());
        }
        if action != "cancel" {
            assert!(c.submit("Stale reference".into()).is_err());
        }
        if action != "shutdown" {
            manager.close().await.unwrap();
        }
    }
}

#[tokio::test(start_paused = true)]
async fn recovery_interrupts_the_saved_wait_without_rearming_it() {
    let provider = FakeProvider::new(vec![wait_response(
        "pause",
        60,
        "Never resume automatically",
    )]);
    let store = Arc::new(MemoryStore::default());
    let manager = AgentManager::open(store.clone(), |_| {
        (provider.clone(), vec![create_wait_tool()])
    })
    .await
    .unwrap();
    let c = manager
        .create(options(provider.clone(), vec![create_wait_tool()]))
        .await
        .unwrap();
    let run = c.submit("Wait".into()).unwrap();
    active_wait(&c, "pause").await;
    let interrupted_checkpoint = store.load().await.unwrap().remove(0);
    assert_eq!(
        interrupted_checkpoint.executing_tool_id.as_deref(),
        Some("pause")
    );
    assert_eq!(
        interrupted_checkpoint.operation.as_ref().unwrap().state,
        OperationState::Running
    );
    // Preserve the pre-crash checkpoint, but settle the original task in this test runtime.
    c.cancel(&run.operation_id);
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    manager.close().await.unwrap();
    assert_eq!(provider.count(), 1);

    let restored_store = Arc::new(MemoryStore::default());
    restored_store.save(interrupted_checkpoint).await.unwrap();
    let restored_provider = FakeProvider::new(vec![answer()]);
    let restored = AgentManager::open(restored_store.clone(), |_| {
        (restored_provider.clone(), vec![create_wait_tool()])
    })
    .await
    .unwrap();
    let recovered = restored.get(&c.id).unwrap();
    let snapshot = recovered.snapshot();
    assert_eq!(
        snapshot.operation.as_ref().unwrap().state,
        OperationState::Interrupted
    );
    assert!(snapshot.active_tool_call_id.is_none());
    assert!(snapshot.active_tool_name.is_none());
    assert!(snapshot.approval.is_none());
    assert!(!recovered.busy());
    assert_eq!(outcomes(&recovered), [ToolOutcome::Interrupted]);
    advance(Duration::from_secs(86_400)).await;
    tokio::task::yield_now().await;
    assert_eq!(restored_provider.count(), 0);
    assert_eq!(recovered.snapshot(), snapshot);
    let saved = restored_store.load().await.unwrap().remove(0);
    assert_eq!(saved.operation.unwrap().state, OperationState::Interrupted);
    assert!(saved.executing_tool_id.is_none());
    assert_eq!(
        complete(recovered.submit("New explicit instruction".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert_eq!(restored_provider.count(), 1);
    assert!(wake_results(&restored_provider.requests.lock().unwrap()[0]).is_empty());
    restored.close().await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn mixed_batches_and_last_step_waits_fail_before_any_tool_executes() {
    for (calls, max_steps) in [
        (vec![call("effect"), wait_call("pause", 10, "Check")], 2),
        (vec![wait_call("pause", 10, "Check"), call("effect")], 2),
        (vec![wait_call("pause", 10, "Check")], 1),
    ] {
        let call_count = calls.len();
        let executions = Arc::new(AtomicUsize::new(0));
        let counter = executions.clone();
        let mut events = calls;
        events.push(ProviderEvent::Done);
        let provider = FakeProvider::new(vec![response(events)]);
        let mut config = options(
            provider.clone(),
            vec![
                create_wait_tool(),
                tool(None, move |_| {
                    counter.fetch_add(1, Ordering::SeqCst);
                    async { Ok("effect".into()) }
                }),
            ],
        );
        config.max_steps = max_steps;
        let c = Conversation::new(config, None).unwrap();
        let (_, mut events) = c.subscribe();
        let finished = complete(c.submit("Act".into()).unwrap()).await;
        assert_eq!(finished.state, OperationState::Failed);
        if max_steps == 1 {
            assert!(finished.error.unwrap().contains("step limit"));
        }
        assert_eq!(executions.load(Ordering::SeqCst), 0);
        assert_eq!(outcomes(&c), vec![ToolOutcome::NotExecuted; call_count]);
        assert!(
            !event_kinds(&mut events)
                .iter()
                .any(|e| matches!(e, EventKind::ToolStarted { .. }))
        );
        assert!(c.snapshot().active_tool_name.is_none());
        advance(Duration::from_secs(86_400)).await;
        tokio::task::yield_now().await;
        assert_eq!(provider.count(), 1);
    }
}
