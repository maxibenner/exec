mod support;
use exec_agent::{
    Error,
    core::*,
    manager::AgentManager,
    storage::{ConversationStore, JsonConversationStore},
};
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};
use support::*;
use tokio_util::sync::CancellationToken;
fn empty_record() -> ConversationRecord {
    conversation(FakeProvider::new(vec![]), vec![]).record()
}
#[tokio::test]
async fn completed_conversations_round_trip_continue_and_delete_durably() {
    let root = directory();
    let profile = root.path().join("profile");
    let p = FakeProvider::new(vec![answer(), answer()]);
    let manager = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (p.clone(), vec![])
    })
    .await
    .unwrap();
    let a = manager.create(options(p.clone(), vec![])).await.unwrap();
    let b = manager.create(options(p, vec![])).await.unwrap();
    tokio::join!(
        complete(a.submit("First".into()).unwrap()),
        complete(b.submit("Second".into()).unwrap())
    );
    let expected = a.snapshot();
    manager.close().await.unwrap();
    assert!(a.submit("Stale".into()).is_err());
    let p = FakeProvider::new(vec![answer()]);
    let restored = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (p.clone(), vec![])
    })
    .await
    .unwrap();
    assert_eq!(p.count(), 0);
    assert_eq!(restored.list().unwrap().len(), 2);
    assert_eq!(restored.get(&a.id).unwrap().snapshot(), expected);
    complete(
        restored
            .get(&a.id)
            .unwrap()
            .submit("Continue explicitly".into())
            .unwrap(),
    )
    .await;
    assert_eq!(
        p.requests.lock().unwrap()[0].messages,
        vec![
            ContextMessage::User {
                text: "First".into()
            },
            ContextMessage::Assistant {
                text: "Completed answer".into(),
                calls: vec![]
            },
            ContextMessage::User {
                text: "Continue explicitly".into()
            }
        ]
    );
    let old = restored.get(&b.id).unwrap();
    restored.delete(&b.id).await.unwrap();
    assert!(old.submit("Resurrect".into()).is_err());
    restored.close().await.unwrap();
    let store = JsonConversationStore::open(&profile).await.unwrap();
    assert_eq!(
        store
            .load()
            .await
            .unwrap()
            .iter()
            .map(|r| &r.id)
            .collect::<Vec<_>>(),
        vec![&a.id]
    );
    assert_eq!(
        fs::metadata(profile.join(format!("{}.json", a.id)))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&profile).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert!(
        fs::read_dir(&profile).unwrap().all(|e| !e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".tmp"))
    );
    store.close().await.unwrap();
}
#[tokio::test]
async fn crash_fixture() {
    let Ok(profile) = std::env::var("EXEC_TEST_CRASH_PROFILE") else {
        return;
    };
    let phase = std::env::var("EXEC_TEST_CRASH_PHASE").unwrap();
    let partial = phase == "partial";
    let p = FakeProvider::new(vec![script(move |_| {
        Box::pin(async_stream::try_stream! {
            if partial{yield ProviderEvent::Text("Saved partial response".into());std::process::exit(0);}
            yield call("first");yield call("second");yield ProviderEvent::Done;
        })
    })]);
    let effect = std::path::Path::new(&profile)
        .parent()
        .unwrap()
        .join("effect");
    let tools = vec![tool(
        if phase == "approval" {
            Some("Approve test effect")
        } else {
            None
        },
        move |_| {
            let effect = effect.clone();
            async move {
                tokio::fs::write(effect, "executed once").await.unwrap();
                std::process::exit(0);
            }
        },
    )];
    let manager = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (p.clone(), tools.clone())
    })
    .await
    .unwrap();
    let c = manager.create(options(p, tools)).await.unwrap();
    let run = c.submit("Start test operation".into()).unwrap();
    if phase == "approval" {
        approval(&c).await;
        std::process::exit(0);
    }
    complete(run).await;
    panic!("Fixture missed crash boundary");
}
async fn crash_restart(phase: &str) {
    let root = directory();
    let profile = root.path().join("profile");
    let mut child = tokio::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "crash_fixture", "--nocapture"])
        .env_clear()
        .env("EXEC_TEST_CRASH_PROFILE", &profile)
        .env("EXEC_TEST_CRASH_PHASE", phase)
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(8), child.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
    assert!(JsonConversationStore::open(&profile).await.is_err());
    assert!(
        fs::read_to_string(profile.join(".lock/owner"))
            .unwrap()
            .contains("PID:")
    );
    fs::remove_dir_all(profile.join(".lock")).unwrap();
    let p = FakeProvider::new(vec![answer()]);
    let manager = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (
            p.clone(),
            vec![tool(None, |_| async { panic!("recovery replayed a tool") })],
        )
    })
    .await
    .unwrap();
    let saved = manager.list().unwrap().remove(0);
    assert_eq!(p.count(), 0);
    assert_eq!(
        saved.operation.as_ref().unwrap().state,
        OperationState::Interrupted
    );
    assert!(saved.approval.is_none());
    assert!(saved.active_tool_call_id.is_none());
    let c = manager.get(&saved.id).unwrap();
    assert!(!c.resolve_approval(&saved.operation.as_ref().unwrap().id, "old", true));
    if phase == "partial" {
        assert!(
            matches!(&saved.messages[1],Message::Assistant{text,status:MessageStatus::Interrupted,..} if text=="Saved partial response")
        );
    } else {
        assert_eq!(
            outcomes(&c),
            [
                if phase == "tool" {
                    ToolOutcome::Interrupted
                } else {
                    ToolOutcome::NotExecuted
                },
                ToolOutcome::NotExecuted
            ]
        );
        if phase == "tool" {
            assert!(saved.messages[2].text().contains("may have had effects"));
            assert_eq!(
                fs::read_to_string(root.path().join("effect")).unwrap(),
                "executed once"
            );
        } else {
            assert!(!root.path().join("effect").exists());
        }
    }
    manager.close().await.unwrap();
    let again = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (p.clone(), vec![])
    })
    .await
    .unwrap();
    let c = again.get(&saved.id).unwrap();
    assert_eq!(c.snapshot(), saved);
    complete(c.submit("New instruction".into()).unwrap()).await;
    assert_eq!(p.count(), 1);
    {
        let requests = p.requests.lock().unwrap();
        if phase == "partial" {
            assert!(
                !requests[0]
                    .messages
                    .iter()
                    .any(|m| matches!(m, ContextMessage::Assistant { .. }))
            );
        } else {
            assert_eq!(
                requests[0]
                    .messages
                    .iter()
                    .filter(|m| matches!(m, ContextMessage::Tool { .. }))
                    .count(),
                2
            );
        }
    }
    again.close().await.unwrap();
}
#[tokio::test]
async fn abrupt_restart_at_partial_boundary_never_replays() {
    crash_restart("partial").await;
}
#[tokio::test]
async fn abrupt_restart_at_approval_boundary_never_replays() {
    crash_restart("approval").await;
}
#[tokio::test]
async fn abrupt_restart_at_tool_boundary_never_replays() {
    crash_restart("tool").await;
}
#[tokio::test]
async fn exclusive_profile_ownership_and_independent_queued_records() {
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    assert!(JsonConversationStore::open(root.path()).await.is_err());
    let a = empty_record();
    let b = empty_record();
    let (a_save, b_save) = tokio::join!(store.save(a.clone()), store.save(b.clone()));
    a_save.unwrap();
    b_save.unwrap();
    assert_eq!(store.load().await.unwrap().len(), 2);
    store.close().await.unwrap();
    assert!(store.save(a).await.is_err());
    let reopened = JsonConversationStore::open(root.path()).await.unwrap();
    assert_eq!(reopened.load().await.unwrap().len(), 2);
    reopened.close().await.unwrap();
}
#[tokio::test]
async fn corrupt_and_unsupported_records_are_retained_without_overwrite() {
    let root = directory();
    let record = empty_record();
    let path = root.path().join(format!("{}.json", record.id));
    fs::write(&path, "{invalid JSON").unwrap();
    let p = FakeProvider::new(vec![]);
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (p.clone(), vec![]),
    )
    .await
    .unwrap();
    assert_eq!(manager.unreadable_sessions(), vec![record.id.clone()]);
    assert!(manager.get(&record.id).is_err());
    manager.close().await.unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "{invalid JSON");
    assert_eq!(p.count(), 0);
    let mut record = record;
    record.version = 999;
    fs::write(path, serde_json::to_vec(&record).unwrap()).unwrap();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    assert!(store.load().await.is_err());
    store.close().await.unwrap();
}
#[tokio::test]
async fn linked_checkpoints_refused_and_invalid_save_preserves_previous_data() {
    let root = directory();
    let profile = root.path().join("profile");
    let store = JsonConversationStore::open(&profile).await.unwrap();
    let record = empty_record();
    store.save(record.clone()).await.unwrap();
    let path = profile.join(format!("{}.json", record.id));
    let before = fs::read(&path).unwrap();
    let mut invalid = record;
    invalid.version = 999;
    assert!(store.save(invalid).await.is_err());
    assert_eq!(fs::read(path).unwrap(), before);
    let outside = root.path().join("outside");
    fs::write(&outside, &before).unwrap();
    symlink(&outside, profile.join(format!("{}.json", new_id()))).unwrap();
    assert!(store.load().await.is_err());
    assert_eq!(fs::read(outside).unwrap(), before);
    store.close().await.unwrap();
}
#[test]
fn validation_rejects_orphan_duplicate_and_unpaired_terminal_results() {
    let mut record = empty_record();
    for field in ["operation", "executingToolID"] {
        let mut value = serde_json::to_value(&record).unwrap();
        value.as_object_mut().unwrap().remove(field);
        assert!(serde_json::from_value::<ConversationRecord>(value).is_err());
    }
    record.configuration.as_mut().unwrap().instructions_frozen = true;
    record.operation = Some(Operation {
        id: new_id(),
        state: OperationState::Running,
        error: None,
    });
    record.messages = vec![
        Message::User {
            images: vec![],
            id: new_id(),
            text: "Hi".into(),
        },
        Message::Assistant {
            id: new_id(),
            text: String::new(),
            calls: vec![ToolCall {
                id: "call".into(),
                name: "effect".into(),
                arguments: Default::default(),
            }],
            status: MessageStatus::Completed,
        },
    ];
    record.validate().unwrap();
    let mut terminal = record.clone();
    terminal.operation.as_mut().unwrap().state = OperationState::Completed;
    assert!(terminal.validate().is_err());
    let mut wrong = record.clone();
    wrong.executing_tool_id = Some("unknown".into());
    assert!(wrong.validate().is_err());
    record.messages.push(Message::Tool {
        id: new_id(),
        call_id: "wrong".into(),
        details: None,
        text: "done".into(),
        outcome: ToolOutcome::Completed,
    });
    assert!(record.validate().is_err());
    if let Some(Message::Tool { call_id, .. }) = record.messages.last_mut() {
        *call_id = "call".into();
    }
    record.validate().unwrap();
    record
        .messages
        .push(record.messages.last().unwrap().clone());
    assert!(record.validate().is_err());
}
#[tokio::test]
async fn checkpoint_failure_before_inference_blocks_later_submissions() {
    let p = FakeProvider::new(vec![]);
    let writes = Arc::new(AtomicUsize::new(0));
    let count = writes.clone();
    let mut config = options(p.clone(), vec![]);
    config.checkpoint = Some(checkpoint(move |_| {
        count.fetch_add(1, Ordering::SeqCst);
        async { Err(Error::Tool("raw private storage path".into())) }
    }));
    let c = Conversation::new(config, None).unwrap();
    assert_eq!(
        complete(c.submit("Hi".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(p.count(), 0);
    assert_eq!(writes.load(Ordering::SeqCst), 1);
    assert!(c.submit("Retry".into()).is_err());
    assert!(
        !serde_json::to_string(&c.snapshot())
            .unwrap()
            .contains("raw private")
    );
}
async fn failed_execution_boundary(intent: bool) {
    let durable = Arc::new(Mutex::new(None));
    let saved = durable.clone();
    let executions = Arc::new(AtomicUsize::new(0));
    let count = executions.clone();
    let mut config = options(
        FakeProvider::new(vec![response(vec![
            call("first"),
            call("second"),
            ProviderEvent::Done,
        ])]),
        vec![tool(None, move |_| {
            count.fetch_add(1, Ordering::SeqCst);
            async { Ok("effect".into()) }
        })],
    );
    config.checkpoint = Some(checkpoint(move |record| {
        let saved = saved.clone();
        async move {
            if (intent && record.executing_tool_id.is_some())
                || (!intent
                    && record
                        .messages
                        .iter()
                        .any(|m| matches!(m, Message::Tool { .. })))
            {
                return Err(Error::Internal);
            }
            *saved.lock().unwrap() = Some(record);
            Ok(())
        }
    }));
    let c = Conversation::new(config, None).unwrap();
    assert_eq!(
        complete(c.submit("Act".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(executions.load(Ordering::SeqCst), usize::from(!intent));
    let recovered = Conversation::new(
        options(FakeProvider::new(vec![]), vec![]),
        durable.lock().unwrap().clone(),
    )
    .unwrap();
    assert_eq!(
        outcomes(&recovered),
        [
            if intent {
                ToolOutcome::NotExecuted
            } else {
                ToolOutcome::Interrupted
            },
            ToolOutcome::NotExecuted
        ]
    );
}
#[tokio::test]
async fn failed_intent_checkpoint_preserves_honest_recovery() {
    failed_execution_boundary(true).await;
}
#[tokio::test]
async fn failed_result_checkpoint_preserves_honest_recovery() {
    failed_execution_boundary(false).await;
}
#[tokio::test]
async fn terminal_success_waits_for_save_and_failed_ack_is_not_retried() {
    let entered = CancellationToken::new();
    let allow = CancellationToken::new();
    let saved = entered.clone();
    let held = allow.clone();
    let attempts = Arc::new(AtomicUsize::new(0));
    let count = attempts.clone();
    let mut config = options(FakeProvider::new(vec![answer()]), vec![]);
    config.checkpoint = Some(checkpoint(move |r| {
        let saved = saved.clone();
        let held = held.clone();
        let count = count.clone();
        async move {
            if r.operation
                .as_ref()
                .is_some_and(|o| o.state == OperationState::Completed)
            {
                count.fetch_add(1, Ordering::SeqCst);
                saved.cancel();
                held.cancelled().await;
                return Err(Error::Internal);
            }
            Ok(())
        }
    }));
    let c = Conversation::new(config, None).unwrap();
    let run = c.submit("Hi".into()).unwrap();
    entered.cancelled().await;
    assert!(c.busy());
    assert_ne!(
        c.snapshot().operation.unwrap().state,
        OperationState::Completed
    );
    assert!(!c.cancel(&run.operation_id));
    allow.cancel();
    assert_eq!(complete(run).await.state, OperationState::Failed);
    assert_eq!(attempts.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn saved_checkpoint_with_failed_ack_is_inspected_never_replayed() {
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let saving = store.clone();
    let p = FakeProvider::new(vec![response(vec![
        call("first"),
        call("second"),
        ProviderEvent::Done,
    ])]);
    let mut config = options(
        p.clone(),
        vec![tool(None, |_| async {
            panic!("failed acknowledgement executed work")
        })],
    );
    config.checkpoint = Some(checkpoint(move |r| {
        let store = saving.clone();
        async move {
            let fail = r.executing_tool_id.is_some();
            store.save(r).await?;
            if fail { Err(Error::Internal) } else { Ok(()) }
        }
    }));
    let c = Conversation::new(config, None).unwrap();
    assert_eq!(
        complete(c.submit("Act".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(p.count(), 1);
    store.close().await.unwrap();
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (FakeProvider::new(vec![]), vec![]),
    )
    .await
    .unwrap();
    assert_eq!(
        outcomes(&manager.get(&c.id).unwrap()),
        [ToolOutcome::Interrupted, ToolOutcome::NotExecuted]
    );
    manager.close().await.unwrap();
}
#[tokio::test]
async fn manager_refuses_close_during_execution_and_closes_retained_references() {
    let entered = CancellationToken::new();
    let manager = AgentManager::default();
    let c = manager
        .create(options(
            FakeProvider::new(vec![waiting(entered.clone())]),
            vec![],
        ))
        .await
        .unwrap();
    let run = c.submit("Wait".into()).unwrap();
    entered.cancelled().await;
    assert!(manager.close().await.is_err());
    c.cancel(&run.operation_id);
    complete(run).await;
    manager.close().await.unwrap();
    assert!(c.submit("Stale".into()).is_err());
    assert!(manager.get(&c.id).is_err());
}
