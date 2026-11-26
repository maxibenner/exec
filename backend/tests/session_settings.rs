mod support;
use exec_agent::{Error, core::*, manager::AgentManager, storage::JsonConversationStore};
use std::{
    fs,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::*;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn live_auto_approval_preserves_pending_prompt_and_applies_to_later_calls() {
    const BEFORE_SAVE: &str = "Starting the next batch";
    const DURING_SAVE: &str = "Starting the next batch with more text";

    let saving = CancellationToken::new();
    let acknowledge = CancellationToken::new();
    let offer_call = CancellationToken::new();
    let writing = saving.clone();
    let proceed = offer_call.clone();
    let provider = FakeProvider::new(vec![
        response(vec![
            call("pending"),
            call("auto-1"),
            call("auto-2"),
            ProviderEvent::Done,
        ]),
        script(move |_| {
            Box::pin(async_stream::try_stream! {
                yield ProviderEvent::TextSnapshot(BEFORE_SAVE.into());
                writing.cancelled().await;
                yield ProviderEvent::TextSnapshot(DURING_SAVE.into());
                proceed.cancelled().await;
                yield call("manual-again");
                yield ProviderEvent::Done;
            })
        }),
        answer(),
    ]);
    let executions = Arc::new(AtomicUsize::new(0));
    let count = executions.clone();
    let mut opts = options(
        provider,
        vec![tool(Some("exact effect"), move |context| {
            count.fetch_add(1, Ordering::SeqCst);
            async move { Ok(context.call_id) }
        })],
    );
    let saved = Arc::new(Mutex::new(None::<ConversationRecord>));
    let slot = saved.clone();
    let ack = acknowledge.clone();
    opts.checkpoint = Some(checkpoint(move |record| {
        let (slot, saving, ack) = (slot.clone(), saving.clone(), ack.clone());
        async move {
            record.validate()?;
            if !record.configuration.as_ref().unwrap().settings.auto_approve
                && record.messages.last().map(Message::text) == Some(BEFORE_SAVE)
            {
                saving.cancel();
                ack.cancelled().await;
            }
            *slot.lock().unwrap() = Some(record);
            Ok(())
        }
    }));
    let saved_record = || saved.lock().unwrap().clone().unwrap();
    let c = Conversation::new(opts, None).unwrap();
    let run = c.submit("Act".into()).unwrap();
    let first = approval(&c).await;
    assert_eq!(first.call.id, "pending");

    let wait = Duration::from_secs(5);
    timeout(wait, c.update_auto_approve(true))
        .await
        .unwrap()
        .unwrap();
    let enabled = c.snapshot();
    assert!(enabled.configuration.settings.auto_approve);
    assert!(saved_record().configuration.unwrap().settings.auto_approve);
    assert_eq!(enabled.approval.as_ref(), Some(&first));
    assert_eq!(executions.load(Ordering::SeqCst), 0);
    assert!(c.resolve_approval(&run.operation_id, &first.id, false));

    // Both remaining calls in the first batch finish without an approval reply.
    until(&c, |s| {
        s.messages.last().map(Message::text) == Some(BEFORE_SAVE)
    })
    .await;
    assert_eq!(
        outcomes(&c),
        [
            ToolOutcome::Denied,
            ToolOutcome::Completed,
            ToolOutcome::Completed
        ]
    );

    // Let the transcript advance while disabling is saving, but don't offer the
    // later call until the flag update has been acknowledged.
    let updating = c.clone();
    let disable = tokio::spawn(async move { updating.update_auto_approve(false).await });
    let streaming = until(&c, |s| {
        s.messages.last().map(Message::text) == Some(DURING_SAVE)
    })
    .await;
    assert!(streaming.configuration.settings.auto_approve);
    assert!(!disable.is_finished());
    acknowledge.cancel();
    timeout(wait, disable).await.unwrap().unwrap().unwrap();
    let disabled = c.snapshot();
    assert!(!disabled.configuration.settings.auto_approve);
    assert!(!saved_record().configuration.unwrap().settings.auto_approve);
    assert_eq!(disabled.messages, streaming.messages);

    offer_call.cancel();
    let prompting = until(&c, |s| s.approval.is_some()).await;
    assert_eq!(
        prompting.messages.last().map(Message::text),
        Some(DURING_SAVE)
    );
    let later = prompting.approval.unwrap();
    assert_eq!(later.call.id, "manual-again");
    assert_eq!(later.operation_id, run.operation_id);
    assert_eq!(executions.load(Ordering::SeqCst), 2);
    assert!(c.resolve_approval(&run.operation_id, &later.id, true));
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(executions.load(Ordering::SeqCst), 3);
    let persisted = saved_record();
    assert!(!persisted.configuration.unwrap().settings.auto_approve);
    assert!(persisted.messages.starts_with(&prompting.messages));
    assert_eq!(persisted.messages, c.snapshot().messages);
}

#[tokio::test]
async fn default_auto_policy_executes_prepared_action_without_an_observer() {
    let executions = Arc::new(AtomicUsize::new(0));
    let count = executions.clone();
    let provider = FakeProvider::new(vec![
        response(vec![call("a"), ProviderEvent::Done]),
        answer(),
    ]);
    let mut options = ConversationOptions::new(provider, "fake", "/isolated-test-workspace");
    options.tools = vec![tool(Some("exact effect"), move |_| {
        count.fetch_add(1, Ordering::SeqCst);
        async { Ok("done".into()) }
    })];
    let c = Conversation::new(options, None).unwrap();
    assert!(c.snapshot().configuration.settings.auto_approve);
    assert_eq!(
        complete(c.submit("Act".into()).unwrap()).await.state,
        OperationState::Completed
    );
    assert_eq!(executions.load(Ordering::SeqCst), 1);
    assert!(c.snapshot().approval.is_none());
}

#[tokio::test]
async fn auto_policy_cannot_bypass_intent_save_or_cancellation() {
    for cancel_at_intent in [false, true] {
        let entered = CancellationToken::new();
        let release = CancellationToken::new();
        let ready = entered.clone();
        let held = release.clone();
        let mut options = ConversationOptions::new(
            FakeProvider::new(vec![response(vec![call("a"), ProviderEvent::Done])]),
            "fake",
            "/isolated-test-workspace",
        );
        options.tools = vec![tool(Some("effect"), |_| async {
            panic!("unsaved or cancelled effect executed")
        })];
        options.checkpoint = Some(checkpoint(move |record| {
            let ready = ready.clone();
            let held = held.clone();
            async move {
                if record.executing_tool_id.is_some() {
                    ready.cancel();
                    held.cancelled().await;
                    if !cancel_at_intent {
                        return Err(Error::Storage);
                    }
                }
                Ok(())
            }
        }));
        let c = Conversation::new(options, None).unwrap();
        let run = c.submit("Act".into()).unwrap();
        entered.cancelled().await;
        if cancel_at_intent {
            assert!(c.cancel(&run.operation_id));
        }
        release.cancel();
        let result = complete(run).await;
        assert_eq!(
            result.state,
            if cancel_at_intent {
                OperationState::Interrupted
            } else {
                OperationState::Failed
            }
        );
        assert_eq!(outcomes(&c), [ToolOutcome::NotExecuted]);
    }
}

#[tokio::test]
async fn settings_are_durable_exclusive_and_published_only_after_save() {
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = entered.clone();
    let held = release.clone();
    let mut options = options(FakeProvider::new(vec![answer()]), vec![]);
    options.checkpoint = Some(checkpoint(move |_| {
        let ready = ready.clone();
        let held = held.clone();
        async move {
            ready.cancel();
            held.cancelled().await;
            Ok(())
        }
    }));
    let c = Conversation::new(options, None).unwrap();
    let updating = c.clone();
    let task =
        tokio::spawn(async move { updating.update_settings(SessionSettings::default()).await });
    entered.cancelled().await;
    assert!(!c.snapshot().configuration.settings.auto_approve);
    assert!(matches!(c.submit("busy".into()), Err(Error::Busy)));
    assert_eq!(c.dispose(), Err(Error::Busy));
    assert_eq!(
        c.update_settings(SessionSettings::default())
            .await
            .unwrap_err(),
        Error::Busy
    );
    // Caller detachment must not abandon the durable mutation.
    task.abort();
    release.cancel();
    until(&c, |s| s.configuration.settings.auto_approve).await;
    complete(c.submit("now ready".into()).unwrap()).await;
}

#[tokio::test]
async fn failed_settings_ack_blocks_work_and_keeps_last_published_policy() {
    let saves = Arc::new(AtomicUsize::new(0));
    let counter = saves.clone();
    let mut options = options(FakeProvider::new(vec![]), vec![]);
    options.checkpoint = Some(checkpoint(move |_| {
        counter.fetch_add(1, Ordering::SeqCst);
        async { Err(Error::Storage) }
    }));
    let c = Conversation::new(options, None).unwrap();
    assert_eq!(
        c.update_settings(SessionSettings::default())
            .await
            .unwrap_err(),
        Error::Storage
    );
    assert!(!c.snapshot().configuration.settings.auto_approve);
    assert!(matches!(c.submit("blocked".into()), Err(Error::Storage)));
    assert_eq!(
        c.update_settings(SessionSettings::default())
            .await
            .unwrap_err(),
        Error::Storage
    );
    assert_eq!(saves.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn manager_freezes_first_send_instructions_and_restores_without_rereading() {
    let root = directory();
    let workspace = directory();
    let path = workspace.path().join("AGENTS.md");
    fs::write(&path, "before creation").unwrap();
    let provider = FakeProvider::new(vec![answer(), answer(), answer()]);
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    let c = manager
        .create(ConversationOptions::new(
            provider.clone(),
            "fake",
            workspace.path().to_str().unwrap(),
        ))
        .await
        .unwrap();
    fs::write(&path, "frozen at first send").unwrap();
    let settings = SessionSettings {
        auto_approve: false,
        system_prompt: "Custom instructions".into(),
        effort: None,
        search_model: None,
    };
    manager
        .update_settings(&c.id, settings.clone())
        .await
        .unwrap();
    complete(manager.submit(&c.id, "First".into()).await.unwrap()).await;
    fs::write(&path, "not used").unwrap();
    complete(manager.submit(&c.id, "Second".into()).await.unwrap()).await;
    manager.close().await.unwrap();
    fs::remove_file(path).unwrap();
    let manager = AgentManager::open(
        JsonConversationStore::open(root.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    assert_eq!(
        manager
            .get(&c.id)
            .unwrap()
            .snapshot()
            .configuration
            .settings,
        settings
    );
    complete(manager.submit(&c.id, "Third".into()).await.unwrap()).await;
    for request in provider.requests.lock().unwrap().iter() {
        assert!(request.instructions.contains("Custom instructions"));
        assert!(request.instructions.contains("frozen at first send"));
        assert!(!request.instructions.contains("before creation"));
        assert!(!request.instructions.contains("not used"));
        assert!(
            request
                .instructions
                .contains(workspace.path().to_str().unwrap())
        );
        assert!(!request.messages.iter().any(
            |m| matches!(m, ContextMessage::User { text } if text.contains("frozen at first send"))
        ));
    }
    manager.close().await.unwrap();
}

#[tokio::test]
async fn invalid_project_instructions_fail_before_acceptance_or_inference() {
    for kind in ["symlink", "directory", "fifo", "oversize", "utf8", "nul"] {
        let workspace = directory();
        let path = workspace.path().join("AGENTS.md");
        match kind {
            "symlink" => std::os::unix::fs::symlink("missing", &path).unwrap(),
            "directory" => fs::create_dir(&path).unwrap(),
            "fifo" => {
                use std::os::unix::ffi::OsStrExt;
                let path = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
            }
            "oversize" => fs::write(&path, vec![b'x'; INSTRUCTION_LIMIT + 1]).unwrap(),
            "utf8" => fs::write(&path, [0xff]).unwrap(),
            _ => fs::write(&path, b"a\0b").unwrap(),
        }
        let p = FakeProvider::new(vec![]);
        let manager = AgentManager::default();
        let c = manager
            .create(ConversationOptions::new(
                p.clone(),
                "fake",
                workspace.path().to_str().unwrap(),
            ))
            .await
            .unwrap();
        assert!(
            manager.submit(&c.id, "hello".into()).await.is_err(),
            "{kind}"
        );
        assert!(c.snapshot().messages.is_empty());
        assert!(!c.snapshot().configuration.instructions_frozen);
        assert_eq!(p.count(), 0);
        manager.close().await.unwrap();
    }
}

#[test]
fn old_records_keep_manual_policy_and_v2_requires_configuration() {
    let record = conversation(FakeProvider::new(vec![]), vec![]).record();
    let mut value = serde_json::to_value(record).unwrap();
    value.as_object_mut().unwrap().remove("configuration");
    let missing: ConversationRecord = serde_json::from_value(value.clone()).unwrap();
    assert!(missing.validate().is_err());
    let mut incomplete =
        serde_json::to_value(conversation(FakeProvider::new(vec![]), vec![]).record()).unwrap();
    incomplete["configuration"]
        .as_object_mut()
        .unwrap()
        .remove("workspaceInstructions");
    assert!(serde_json::from_value::<ConversationRecord>(incomplete).is_err());
    value["version"] = 1.into();
    let legacy: ConversationRecord = serde_json::from_value(value).unwrap();
    let recovered = legacy.recover().unwrap();
    assert_eq!(recovered.version, 9);
    let config = recovered.configuration.unwrap();
    assert!(!config.settings.auto_approve);
    assert!(config.instructions_frozen);
}
