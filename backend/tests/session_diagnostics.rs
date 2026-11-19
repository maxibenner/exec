mod support;

use async_trait::async_trait;
use exec_agent::{
    Error, ProviderFailure, Result, core::*, manager::AgentManager, storage::JsonConversationStore,
};
use std::{
    fs,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::*;
use tokio_util::sync::CancellationToken;

fn failure(error: Error) -> Script {
    script(move |_| Box::pin(futures_util::stream::once(async move { Err(error) })))
}

fn diagnostics(profile: &Path, id: &str) -> (String, Vec<SessionDiagnostic>) {
    let text = fs::read_to_string(profile.join(id).join("diagnostics.jsonl")).unwrap();
    assert!(text.ends_with('\n'));
    let entries = text
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    (text, entries)
}

fn assert_trace(
    entries: &[SessionDiagnostic],
    conversation_id: &str,
    operation_id: &str,
    expected: &[(DiagnosticEvent, Option<&str>, Option<DiagnosticFailure>)],
) {
    for entry in entries {
        assert_eq!(entry.conversation_id, conversation_id);
        assert_eq!(entry.operation_id, operation_id);
        assert!(entry.timestamp_ms > 0);
    }
    assert_eq!(
        entries
            .iter()
            .map(|entry| (
                entry.event,
                entry.message_id.as_deref(),
                entry.failure.clone()
            ))
            .collect::<Vec<_>>(),
        expected
    );
}

#[tokio::test]
async fn empty_response_after_completed_tool_is_precise_private_and_recoverable() {
    use DiagnosticEvent::*;
    const PROMPT: &str = "private-user-prompt-67d8";
    const INSTRUCTIONS: &str = "private-system-instructions-b732";
    const ARGUMENT: &str = "private-tool-argument-194e";
    const RESULT: &str = "private-completed-tool-result-e8a4";
    const CONTEXT: &str = "private-opaque-provider-context-a593";
    const TEXT: &str = "private-assistant-text-e42c";
    const NEXT: &str = "private-recovery-prompt-1a6e";
    let root = directory();
    let profile = root.path().join("conversations");
    let state = serde_json::json!({"opaque": CONTEXT});
    let mut tool_call = call("private-provider-call-id-429d");
    let ProviderEvent::ToolCall(ref mut call) = tool_call else {
        unreachable!()
    };
    call.arguments.insert("value".into(), ARGUMENT.into());
    let p = FakeProvider::new(vec![
        response(vec![
            ProviderEvent::Text(TEXT.into()),
            tool_call,
            ProviderEvent::Metadata {
                state: Some(state.clone()),
                usage: None,
            },
            ProviderEvent::Done,
        ]),
        failure(Error::Provider(ProviderFailure::EmptyResponse)),
        answer(),
    ]);
    let executions = Arc::new(AtomicUsize::new(0));
    let counter = executions.clone();
    let tools = vec![tool(None, move |_| {
        counter.fetch_add(1, Ordering::SeqCst);
        async { Ok(RESULT.into()) }
    })];
    let manager = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (p.clone(), tools.clone())
    })
    .await
    .unwrap();
    let mut opts = options(p.clone(), tools.clone());
    opts.workspace = root.path().to_string_lossy().into_owned();
    opts.settings.system_prompt = INSTRUCTIONS.into();
    let c = manager.create(opts).await.unwrap();
    let run = c.submit(PROMPT.into()).unwrap();
    let failed_operation = run.operation_id.clone();
    assert_eq!(complete(run).await.state, OperationState::Failed);
    assert_eq!(p.count(), 2, "the failed response must not be retried");
    assert_eq!(executions.load(Ordering::SeqCst), 1);
    c.record().validate().unwrap();
    let messages = c.snapshot().messages;
    assert!(matches!(
        &messages[1],
        Message::Assistant {
            status: MessageStatus::Completed,
            ..
        }
    ));
    let completed_tool = messages[2].clone();
    assert!(matches!(
        &completed_tool,
        Message::Tool { text, outcome: ToolOutcome::Completed, .. } if text == RESULT
    ));
    assert!(matches!(
        messages.last().unwrap(),
        Message::Assistant { text, status: MessageStatus::Failed, .. } if text.is_empty()
    ));
    let failed_message = messages.last().unwrap().id();
    let reason = DiagnosticFailure::Provider {
        reason: ProviderFailure::EmptyResponse,
    };
    let (before, previous) = diagnostics(&profile, &c.id);
    assert_trace(
        &previous,
        &c.id,
        &failed_operation,
        &[
            (OperationStarted, None, None),
            (ResponseStarted, Some(messages[1].id()), None),
            (ResponseCompleted, Some(messages[1].id()), None),
            (ResponseStarted, Some(failed_message), None),
            (ResponseFailed, Some(failed_message), Some(reason.clone())),
            (OperationFailed, None, Some(reason)),
        ],
    );
    let wire: serde_json::Value = serde_json::from_str(before.lines().nth(4).unwrap()).unwrap();
    assert_eq!(
        wire["failure"],
        serde_json::json!({"category": "provider", "reason": "empty_response"})
    );
    manager.close().await.unwrap();

    let manager = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (p.clone(), tools.clone())
    })
    .await
    .unwrap();
    let restored = manager.get(&c.id).unwrap();
    assert_eq!(p.count(), 2, "reopening must not resume provider work");
    assert_eq!(restored.snapshot().messages, messages);
    assert_eq!(diagnostics(&profile, &c.id).0, before);
    let run = restored.submit(NEXT.into()).unwrap();
    let next_operation = run.operation_id.clone();
    assert_ne!(next_operation, failed_operation);
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(p.count(), 3);
    assert_eq!(executions.load(Ordering::SeqCst), 1);
    assert_eq!(restored.snapshot().messages[2], completed_tool);
    let final_messages = restored.snapshot().messages;
    let (text, entries) = diagnostics(&profile, &c.id);
    assert!(text.starts_with(&before));
    assert_eq!(entries[..previous.len()], previous);
    assert_trace(
        &entries[previous.len()..],
        &c.id,
        &next_operation,
        &[
            (OperationStarted, None, None),
            (
                ResponseStarted,
                Some(final_messages.last().unwrap().id()),
                None,
            ),
            (
                ResponseCompleted,
                Some(final_messages.last().unwrap().id()),
                None,
            ),
            (OperationCompleted, None, None),
        ],
    );
    {
        let requests = p.requests.lock().unwrap();
        assert!(requests[0].instructions.contains(INSTRUCTIONS));
        for request in &requests[1..] {
            assert_eq!(request.provider_state, Some(state.clone()));
            assert!(request.messages.iter().any(|message| matches!(
                message,
                ContextMessage::Tool { text, outcome: ToolOutcome::Completed, .. }
                    if text == RESULT
            )));
        }
        assert!(requests[2].incomplete_message_ids.contains(failed_message));
    }
    for private in [
        PROMPT,
        INSTRUCTIONS,
        ARGUMENT,
        RESULT,
        CONTEXT,
        TEXT,
        NEXT,
        "private-provider-call-id-429d",
        "Completed answer",
    ] {
        assert!(!text.contains(private), "diagnostics leaked {private}");
    }
    manager.close().await.unwrap();
}

#[tokio::test]
async fn arbitrary_tool_and_invalid_errors_log_only_safe_categories_without_retry() {
    use DiagnosticEvent::*;
    for (error, category, private) in [
        (
            Error::Tool("private-arbitrary-tool-error-32c9".into()),
            DiagnosticFailure::Tool,
            "private-arbitrary-tool-error-32c9",
        ),
        (
            Error::Invalid("private-arbitrary-invalid-error-138b"),
            DiagnosticFailure::Invalid,
            "private-arbitrary-invalid-error-138b",
        ),
    ] {
        let root = directory();
        let profile = root.path().join("conversations");
        let p = FakeProvider::new(vec![failure(error)]);
        let manager =
            AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
                (p.clone(), vec![])
            })
            .await
            .unwrap();
        let mut opts = options(p.clone(), vec![]);
        opts.workspace = root.path().to_string_lossy().into_owned();
        let c = manager.create(opts).await.unwrap();
        let run = c.submit("private-error-test-prompt-8cb0".into()).unwrap();
        let operation_id = run.operation_id.clone();
        assert_eq!(complete(run).await.state, OperationState::Failed);
        assert_eq!(p.count(), 1);
        let messages = c.snapshot().messages;
        let (text, entries) = diagnostics(&profile, &c.id);
        assert_trace(
            &entries,
            &c.id,
            &operation_id,
            &[
                (OperationStarted, None, None),
                (ResponseStarted, Some(messages.last().unwrap().id()), None),
                (
                    ResponseFailed,
                    Some(messages.last().unwrap().id()),
                    Some(category.clone()),
                ),
                (OperationFailed, None, Some(category)),
            ],
        );
        assert!(!text.contains(private));
        assert!(!text.contains("private-error-test-prompt-8cb0"));
        manager.close().await.unwrap();
    }
}

#[tokio::test]
async fn cancelled_response_logs_interruption_not_failure_or_completion() {
    use DiagnosticEvent::*;
    const PARTIAL: &str = "private-partial-response-946f";
    let root = directory();
    let profile = root.path().join("conversations");
    let entered = CancellationToken::new();
    let signal = entered.clone();
    let p = FakeProvider::new(vec![script(move |request| {
        Box::pin(async_stream::try_stream! {
            yield ProviderEvent::Text(PARTIAL.into());
            signal.cancel();
            request.cancel.cancelled().await;
            Err(Error::Cancelled)?;
        })
    })]);
    let manager = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (p.clone(), vec![])
    })
    .await
    .unwrap();
    let mut opts = options(p.clone(), vec![]);
    opts.workspace = root.path().to_string_lossy().into_owned();
    let c = manager.create(opts).await.unwrap();
    let run = c.submit("private-cancellation-prompt-149d".into()).unwrap();
    let operation_id = run.operation_id.clone();
    tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
        .await
        .expect("provider never started streaming");
    assert!(c.cancel(&operation_id));
    let operation = complete(run).await;
    assert_eq!(operation.state, OperationState::Interrupted);
    assert!(operation.error.is_none());
    assert_eq!(p.count(), 1);
    let messages = c.snapshot().messages;
    assert!(matches!(
        messages.last().unwrap(),
        Message::Assistant { text, status: MessageStatus::Interrupted, .. } if text == PARTIAL
    ));
    let (text, entries) = diagnostics(&profile, &c.id);
    assert_trace(
        &entries,
        &c.id,
        &operation_id,
        &[
            (OperationStarted, None, None),
            (ResponseStarted, Some(messages.last().unwrap().id()), None),
            (
                ResponseInterrupted,
                Some(messages.last().unwrap().id()),
                Some(DiagnosticFailure::Cancelled),
            ),
            (
                OperationInterrupted,
                None,
                Some(DiagnosticFailure::Cancelled),
            ),
        ],
    );
    assert!(!text.contains(PARTIAL));
    assert!(!text.contains("private-cancellation-prompt-149d"));
    manager.close().await.unwrap();
}

#[derive(Default)]
struct RejectDiagnostics {
    saved: Mutex<Option<ConversationRecord>>,
    attempted: Mutex<Vec<SessionDiagnostic>>,
    panic: bool,
}

#[async_trait]
impl Checkpoint for RejectDiagnostics {
    async fn save(&self, record: ConversationRecord) -> Result<()> {
        *self.saved.lock().unwrap() = Some(record);
        Ok(())
    }

    async fn diagnostic(&self, entry: SessionDiagnostic) -> Result<()> {
        self.attempted.lock().unwrap().push(entry);
        assert!(!self.panic, "synthetic diagnostic sink panic");
        Err(Error::Storage)
    }
}

#[tokio::test]
async fn diagnostic_sink_errors_and_panics_do_not_fail_or_retry_a_successful_response() {
    use DiagnosticEvent::*;
    for panic in [false, true] {
        let sink = Arc::new(RejectDiagnostics {
            panic,
            ..Default::default()
        });
        let p = FakeProvider::new(vec![answer()]);
        let mut opts = options(p.clone(), vec![]);
        opts.checkpoint = Some(sink.clone());
        let c = Conversation::new(opts, None).unwrap();
        let run = c.submit("Successful isolated request".into()).unwrap();
        let operation_id = run.operation_id.clone();
        let operation = complete(run).await;
        assert_eq!(operation.state, OperationState::Completed);
        assert!(operation.error.is_none());
        assert_eq!(p.count(), 1);
        let snapshot = c.snapshot();
        assert!(snapshot.storage_error.is_none());
        assert!(!c.busy());
        assert!(matches!(
            snapshot.messages.last().unwrap(),
            Message::Assistant { text, status: MessageStatus::Completed, .. }
                if text == "Completed answer"
        ));
        let saved = sink.saved.lock().unwrap().clone().unwrap();
        saved.validate().unwrap();
        assert_eq!(saved.operation.unwrap().state, OperationState::Completed);
        assert_eq!(saved.messages, snapshot.messages);
        assert_trace(
            &sink.attempted.lock().unwrap(),
            &c.id,
            &operation_id,
            &[
                (OperationStarted, None, None),
                (
                    ResponseStarted,
                    Some(snapshot.messages.last().unwrap().id()),
                    None,
                ),
                (
                    ResponseCompleted,
                    Some(snapshot.messages.last().unwrap().id()),
                    None,
                ),
                (OperationCompleted, None, None),
            ],
        );
    }
}
