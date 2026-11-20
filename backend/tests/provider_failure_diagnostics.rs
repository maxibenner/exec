mod support;

use exec_agent::{
    Error, ProviderDiagnostic, ProviderFailure, ProviderTransportKind, ProviderTransportPhase,
    core::*, manager::AgentManager, storage::JsonConversationStore,
};
use serde_json::{Value, json};
use std::{fs, path::Path};
use support::*;

fn diagnostics(profile: &Path, id: &str) -> (String, Vec<SessionDiagnostic>) {
    let text = fs::read_to_string(profile.join(id).join("diagnostics.jsonl")).unwrap();
    assert!(text.ends_with('\n'));
    let entries = text
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    (text, entries)
}

#[tokio::test]
async fn detailed_failures_persist_safely_without_retry_and_recover_only_on_new_turn() {
    use DiagnosticEvent::*;
    use ProviderTransportKind::*;
    use ProviderTransportPhase::*;

    let mut cases = vec![
        (
            ProviderFailure::Authentication,
            ProviderDiagnostic::HttpStatus { status: 401 },
            json!({"kind": "http_status", "status": 401}),
        ),
        (
            ProviderFailure::RateLimit,
            ProviderDiagnostic::HttpStatus { status: 429 },
            json!({"kind": "http_status", "status": 429}),
        ),
        (
            ProviderFailure::Transport,
            ProviderDiagnostic::HttpStatus { status: 503 },
            json!({"kind": "http_status", "status": 503}),
        ),
    ];
    for (phase, phase_wire) in [
        (Setup, "setup"),
        (Send, "send"),
        (ProviderTransportPhase::Body, "body"),
    ] {
        for (cause, cause_wire) in [
            (Timeout, "timeout"),
            (Connect, "connect"),
            (Request, "request"),
            (ProviderTransportKind::Body, "body"),
            (Decode, "decode"),
            (Other, "other"),
        ] {
            cases.push((
                ProviderFailure::Transport,
                ProviderDiagnostic::Transport { phase, cause },
                json!({"kind": "transport", "phase": phase_wire, "cause": cause_wire}),
            ));
        }
    }

    for (reason, detail, detail_wire) in cases {
        let root = directory();
        let profile = root.path().join("conversations");
        let error = Error::ProviderDetailed { reason, detail };
        let display = Error::Provider(reason).to_string();
        assert_eq!(error.to_string(), display);
        let p = FakeProvider::new(vec![
            script(move |_| Box::pin(futures_util::stream::once(async move { Err(error) }))),
            answer(),
        ]);
        let manager =
            AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
                (p.clone(), vec![])
            })
            .await
            .unwrap();
        let mut opts = options(p.clone(), vec![]);
        opts.workspace = root.path().to_string_lossy().into_owned();
        opts.settings.system_prompt = "private-system-instructions-f729".into();
        let c = manager.create(opts).await.unwrap();
        let run = c.submit("private-failed-prompt-175a".into()).unwrap();
        let operation_id = run.operation_id.clone();
        let operation = complete(run).await;
        assert_eq!(operation.state, OperationState::Failed, "{detail:?}");
        assert_eq!(operation.error.as_deref(), Some(display.as_str()));
        assert_eq!(p.count(), 1, "failure must not trigger an automatic retry");
        c.record().validate().unwrap();
        let messages = c.snapshot().messages;
        let failed_id = messages.last().unwrap().id();
        assert!(matches!(messages.last().unwrap(),
            Message::Assistant { status: MessageStatus::Failed, text, .. } if text.is_empty()));
        let expected_failure = DiagnosticFailure::Provider {
            reason,
            detail: Some(detail),
        };
        let (before, entries) = diagnostics(&profile, &c.id);
        assert_eq!(
            entries
                .iter()
                .map(|entry| (
                    entry.event,
                    entry.message_id.as_deref(),
                    entry.failure.clone()
                ))
                .collect::<Vec<_>>(),
            vec![
                (OperationStarted, None, None),
                (ResponseStarted, Some(failed_id), None),
                (
                    ResponseFailed,
                    Some(failed_id),
                    Some(expected_failure.clone())
                ),
                (OperationFailed, None, Some(expected_failure)),
            ]
        );
        for entry in &entries {
            assert_eq!(entry.conversation_id, c.id);
            assert_eq!(entry.operation_id, operation_id);
            assert!(entry.timestamp_ms > 0);
        }
        let failure_wire = json!({
            "category": "provider", "reason": reason, "detail": detail_wire,
        });
        for line in before.lines().skip(2) {
            let wire: Value = serde_json::from_str(line).unwrap();
            assert_eq!(wire["failure"], failure_wire);
            assert_eq!(
                serde_json::to_value(serde_json::from_str::<SessionDiagnostic>(line).unwrap())
                    .unwrap(),
                wire
            );
        }
        manager.close().await.unwrap();

        let manager =
            AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
                (p.clone(), vec![])
            })
            .await
            .unwrap();
        let restored = manager.get(&c.id).unwrap();
        assert_eq!(
            p.count(),
            1,
            "reopening must not resume failed provider work"
        );
        assert_eq!(restored.snapshot().messages, messages);
        assert_eq!(diagnostics(&profile, &c.id).0, before);
        let run = restored
            .submit("private-recovery-prompt-123b".into())
            .unwrap();
        let next_id = run.operation_id.clone();
        assert_ne!(next_id, operation_id);
        assert_eq!(complete(run).await.state, OperationState::Completed);
        assert_eq!(
            p.count(),
            2,
            "only the explicit new turn may call the provider again"
        );
        restored.record().validate().unwrap();
        assert!(matches!(restored.snapshot().messages.last().unwrap(),
            Message::Assistant { status: MessageStatus::Completed, text, .. }
                if text == "Completed answer"));
        assert!(
            p.requests.lock().unwrap()[1]
                .incomplete_message_ids
                .iter()
                .any(|id| id == failed_id)
        );
        let (after, recovered) = diagnostics(&profile, &c.id);
        assert!(after.starts_with(&before));
        assert_eq!(recovered[..entries.len()], entries);
        let next = &recovered[entries.len()..];
        assert_eq!(
            next.iter().map(|entry| entry.event).collect::<Vec<_>>(),
            vec![
                OperationStarted,
                ResponseStarted,
                ResponseCompleted,
                OperationCompleted
            ]
        );
        for entry in next {
            assert_eq!(entry.operation_id, next_id);
            assert!(entry.failure.is_none());
        }
        for private in [
            "private-system-instructions-f729",
            "private-failed-prompt-175a",
            "private-recovery-prompt-123b",
            "Completed answer",
            display.as_str(),
        ] {
            assert!(!after.contains(private), "diagnostics leaked {private}");
        }
        manager.close().await.unwrap();
    }
}

#[test]
fn detailed_errors_preserve_existing_user_facing_display_for_every_reason() {
    use ProviderFailure::*;
    for reason in [
        Authentication,
        Quota,
        RateLimit,
        Request,
        Timeout,
        Transport,
        Response,
        EmptyResponse,
        IncompleteResponse,
        FailedResponse,
        StreamEnded,
        MalformedResponse,
        UnexpectedContentType,
        Unsupported,
    ] {
        for detail in [
            ProviderDiagnostic::HttpStatus { status: 599 },
            ProviderDiagnostic::Transport {
                phase: ProviderTransportPhase::Body,
                cause: ProviderTransportKind::Decode,
            },
        ] {
            assert_eq!(
                Error::ProviderDetailed { reason, detail }.to_string(),
                Error::Provider(reason).to_string()
            );
        }
    }
}

#[test]
fn legacy_provider_diagnostics_without_detail_round_trip_unchanged() {
    for event in ["response_failed", "operation_failed"] {
        let mut wire = json!({
            "timestampMs": 1234,
            "conversationId": "legacy-session",
            "operationId": "legacy-operation",
            "event": event,
            "failure": {"category": "provider", "reason": "transport"},
        });
        if event == "response_failed" {
            wire["messageId"] = json!("legacy-message");
        }
        let diagnostic: SessionDiagnostic = serde_json::from_value(wire.clone()).unwrap();
        assert_eq!(
            diagnostic.failure,
            Some(DiagnosticFailure::Provider {
                reason: ProviderFailure::Transport,
                detail: None,
            })
        );
        assert_eq!(serde_json::to_value(diagnostic).unwrap(), wire);
    }
}
