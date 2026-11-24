mod support;

use async_trait::async_trait;
use exec_agent::{Error, Result, core::*, manager::AgentManager, storage::JsonConversationStore};
use serde_json::json;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use support::*;
use tokio_util::sync::CancellationToken;

struct Probe {
    name: &'static str,
    available: AtomicBool,
    inner: Arc<dyn Tool>,
    preparations: AtomicUsize,
    saved: AtomicUsize,
}
impl Probe {
    fn new() -> Arc<Self> {
        Self::named("change")
    }
    fn named(name: &'static str) -> Arc<Self> {
        Arc::new(Self {
            name,
            available: AtomicBool::new(true),
            inner: tool(Some("effect"), |_| async { Ok("done".into()) }),
            preparations: AtomicUsize::new(0),
            saved: AtomicUsize::new(0),
        })
    }
}
#[async_trait]
impl Tool for Probe {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: self.name.into(),
            ..self.inner.definition()
        }
    }
    fn availability(&self, _: &ToolContext) -> RuntimeToolAvailability {
        if self.available.load(Ordering::SeqCst) {
            RuntimeToolAvailability::available()
        } else {
            RuntimeToolAvailability::unavailable("Probe capability is unavailable.")
        }
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        self.preparations.fetch_add(1, Ordering::SeqCst);
        self.inner.prepare(args, context).await
    }
    async fn result_saved(&self, _: &str, _: &str) -> Result<()> {
        self.saved.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

#[tokio::test]
async fn disabled_tools_filter_catalog_preserve_history_and_cannot_execute() {
    let provider = FakeProvider::new(vec![
        response(vec![call("disabled"), ProviderEvent::Done]),
        answer(),
        response(vec![call("enabled"), ProviderEvent::Done]),
        answer(),
        answer(),
        answer(),
    ]);
    let probe = Probe::new();
    let mut options =
        ConversationOptions::new(provider.clone(), "fake", "/isolated-test-workspace");
    options.tools = vec![probe.clone()];
    options.metadata.disabled_tools = vec!["change".into()];
    let c = Conversation::new(options, None).unwrap();
    assert_eq!(
        complete(c.submit("act".into()).unwrap()).await.state,
        OperationState::Completed
    );
    assert_eq!(outcomes(&c), [ToolOutcome::NotExecuted]);
    assert_eq!(probe.preparations.load(Ordering::SeqCst), 0);
    assert_eq!(probe.saved.load(Ordering::SeqCst), 0);
    assert!(c.snapshot().approval.is_none());
    for request in provider.requests.lock().unwrap().iter() {
        assert!(request.tools.is_empty());
        assert!(request.instructions.contains("Use the provided tools"));
        assert!(
            request
                .messages
                .contains(&ContextMessage::ToolAvailability { enabled: vec![] })
        );
    }
    assert_eq!(c.record().tool_availability.len(), 1);
    let snapshot = serde_json::to_value(c.snapshot()).unwrap();
    assert!(snapshot.get("toolAvailability").is_none());
    assert_eq!(snapshot["messages"].as_array().unwrap().len(), 4);
    c.update_disabled_tools(vec![]).await.unwrap();
    assert_eq!(
        complete(c.submit("act again".into()).unwrap()).await.state,
        OperationState::Completed
    );
    assert_eq!(
        outcomes(&c),
        [ToolOutcome::NotExecuted, ToolOutcome::Completed]
    );
    assert_eq!(probe.preparations.load(Ordering::SeqCst), 1);
    assert_eq!(probe.saved.load(Ordering::SeqCst), 1);
    assert_eq!(c.record().tool_availability.len(), 2);
    let history = c.snapshot().messages;
    c.update_disabled_tools(vec!["change".into()])
        .await
        .unwrap();
    complete(c.submit("continue without tools".into()).unwrap()).await;
    assert!(c.snapshot().messages.starts_with(&history));
    c.update_disabled_tools(vec![]).await.unwrap();
    complete(c.submit("tools re-enabled".into()).unwrap()).await;
    let requests = provider.requests.lock().unwrap();
    assert_eq!(requests.len(), 6);
    for (request, enabled) in requests.iter().zip([false, false, true, true, false, true]) {
        assert_eq!(
            request.tools,
            if enabled {
                vec![probe.definition()]
            } else {
                vec![]
            }
        );
        assert_eq!(request.instructions, requests[0].instructions);
        assert_eq!(request.messages.len(), request.message_ids.len());
    }
    for pair in requests.windows(2) {
        assert!(pair[1].messages.starts_with(&pair[0].messages));
        assert!(pair[1].message_ids.starts_with(&pair[0].message_ids));
    }
    assert!(
        matches!(requests[2].messages.last(), Some(ContextMessage::ToolAvailability { enabled }) if enabled == &["change"])
    );
    assert!(requests[4].messages.iter().any(|message| {
        matches!(message, ContextMessage::Assistant { calls, .. }
            if calls.iter().any(|call| call.id == "enabled" && call.name == "change"))
    }));
    assert!(requests[4].messages.iter().any(|message| {
        matches!(message, ContextMessage::Tool { call_id, text, outcome: ToolOutcome::Completed }
            if call_id == "enabled" && text == "done")
    }));
    assert_eq!(c.record().tool_availability.len(), 4);
    c.record().validate().unwrap();
}

#[tokio::test]
async fn only_net_changes_append_at_requests_and_restore_preserves_order_and_ids() {
    let provider = FakeProvider::new(vec![answer(), answer(), answer(), answer(), answer()]);
    let a = Probe::new();
    let z = Probe::named("zeta");
    let saved = Arc::new(Mutex::new(Vec::new()));
    let mut opts = options(provider.clone(), vec![z.clone(), a.clone()]);
    opts.checkpoint = Some(checkpoint({
        let saved = saved.clone();
        move |record| {
            record.validate().unwrap();
            saved.lock().unwrap().push(record);
            async { Ok(()) }
        }
    }));
    let c = Conversation::new(opts, None).unwrap();
    c.update_disabled_tools(vec!["change".into()])
        .await
        .unwrap();
    c.update_disabled_tools(vec![]).await.unwrap();
    assert!(c.record().tool_availability.is_empty());
    complete(c.submit("first".into()).unwrap()).await;
    let initial = c.record().tool_availability;
    assert_eq!(initial.len(), 1);
    assert_eq!(initial[0].enabled, ["change", "zeta"]);
    c.update_disabled_tools(vec!["zeta".into(), "change".into()])
        .await
        .unwrap();
    c.update_disabled_tools(vec![]).await.unwrap();
    complete(c.submit("back to the same set".into()).unwrap()).await;
    assert_eq!(c.record().tool_availability, initial);
    c.update_disabled_tools(vec!["change".into()])
        .await
        .unwrap();
    c.update_disabled_tools(vec!["change".into(), "zeta".into()])
        .await
        .unwrap();
    c.update_disabled_tools(vec!["zeta".into(), "change".into()])
        .await
        .unwrap();
    assert_eq!(c.record().tool_availability, initial);
    complete(c.submit("both disabled".into()).unwrap()).await;
    let history = c.record().tool_availability;
    assert_eq!(history.len(), 2);
    assert!(history[1].enabled.is_empty());
    // Restore from serialized data with the registry supplied in a different order.
    let record = serde_json::from_slice(&serde_json::to_vec(&c.record()).unwrap()).unwrap();
    let restored = Conversation::new(
        options(provider.clone(), vec![a.clone(), z.clone()]),
        Some(record),
    )
    .unwrap();
    complete(restored.submit("restored".into()).unwrap()).await;
    assert_eq!(restored.record().tool_availability, history);
    {
        let requests = provider.requests.lock().unwrap();
        for (index, request) in requests.iter().enumerate() {
            let expected: &[&str] = if index < 2 { &["change", "zeta"] } else { &[] };
            assert_eq!(
                request
                    .tools
                    .iter()
                    .map(|d| d.name.as_str())
                    .collect::<Vec<_>>(),
                expected
            );
            assert_eq!(request.instructions, requests[0].instructions);
            assert_eq!(request.messages.len(), request.message_ids.len());
        }
        for pair in requests.windows(2) {
            assert!(pair[1].messages.starts_with(&pair[0].messages));
            assert!(pair[1].message_ids.starts_with(&pair[0].message_ids));
        }
    }
    assert!(saved.lock().unwrap().iter().any(|record| {
        record.tool_availability == initial
            && matches!(
                record.messages.last(),
                Some(Message::Assistant {
                    status: MessageStatus::Streaming,
                    ..
                })
            )
    }));
    // Legacy history acquires a current policy only at its next request, without
    // inserting a synthetic instruction into already-sent history.
    let mut legacy = restored.record();
    legacy.version = 9;
    legacy.tool_availability.clear();
    let restored = Conversation::new(options(provider.clone(), vec![z, a]), Some(legacy)).unwrap();
    assert!(restored.record().tool_availability.is_empty());
    complete(restored.submit("legacy continuation".into()).unwrap()).await;
    assert_eq!(restored.record().tool_availability.len(), 1);
    let requests = provider.requests.lock().unwrap();
    assert!(
        matches!(requests[4].messages.last(), Some(ContextMessage::ToolAvailability { enabled }) if enabled.is_empty())
    );
}

#[tokio::test]
async fn capability_changes_filter_catalog_and_are_checked_again_before_preparation() {
    let probe = Probe::new();
    let unavailable = probe.clone();
    let provider = FakeProvider::new(vec![
        script(move |_| {
            unavailable.available.store(false, Ordering::SeqCst);
            Box::pin(futures_util::stream::iter([
                Ok(call("unavailable")),
                Ok(ProviderEvent::Done),
            ]))
        }),
        answer(),
    ]);
    let c = conversation(provider.clone(), vec![probe.clone()]);
    let names = vec!["change".into()];
    assert_eq!(
        c.tool_availability(&names, "fake", None)["change"],
        RuntimeToolAvailability::available()
    );
    complete(c.submit("act".into()).unwrap()).await;
    assert_eq!(
        c.tool_availability(&names, "fake", None)["change"],
        RuntimeToolAvailability::unavailable("Probe capability is unavailable.")
    );
    assert_eq!(probe.preparations.load(Ordering::SeqCst), 0);
    assert_eq!(probe.saved.load(Ordering::SeqCst), 0);
    assert!(c.snapshot().approval.is_none());
    assert_eq!(outcomes(&c), [ToolOutcome::NotExecuted]);
    let requests = provider.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].tools, [probe.definition()]);
    assert!(requests[1].tools.is_empty());
    assert_eq!(requests[0].instructions, requests[1].instructions);
    assert!(requests[1].messages.starts_with(&requests[0].messages));
    assert!(
        requests[1]
            .message_ids
            .starts_with(&requests[0].message_ids)
    );
    assert!(
        matches!(requests[1].messages.last(), Some(ContextMessage::ToolAvailability { enabled }) if enabled.is_empty())
    );
    let mut invalid = c.record();
    invalid.tool_availability[0].after_message_id = invalid.messages[1].id().into();
    assert!(
        invalid.validate().is_err(),
        "policy must not split tool calls/results"
    );
    let mut invalid = c.record();
    invalid.tool_availability[0].id = invalid.messages[0].id().into();
    assert!(invalid.validate().is_err(), "context IDs must be unique");
    let mut invalid = c.record();
    invalid.tool_availability[0].after_message_id = new_id();
    assert!(invalid.validate().is_err(), "policy anchors must exist");
}

#[tokio::test]
async fn failed_availability_checkpoint_prevents_inference_without_retry() {
    let provider = FakeProvider::new(vec![]);
    let mut opts = options(provider.clone(), vec![Probe::new()]);
    opts.checkpoint = Some(checkpoint(|record| async move {
        if record.tool_availability.is_empty() {
            Ok(())
        } else {
            Err(Error::Storage)
        }
    }));
    let c = Conversation::new(opts, None).unwrap();
    assert_eq!(
        complete(c.submit("act".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(provider.count(), 0);
    assert!(c.snapshot().storage_error.is_some());
    assert!(matches!(c.submit("blocked".into()), Err(Error::Storage)));
}

#[tokio::test]
async fn selection_is_immutable_during_inference_and_pending_approval() {
    let entered = CancellationToken::new();
    let c = conversation(
        FakeProvider::new(vec![waiting(entered.clone())]),
        vec![Probe::new()],
    );
    let run = c.submit("hold".into()).unwrap();
    entered.cancelled().await;
    assert_eq!(
        c.update_disabled_tools(vec!["change".into()])
            .await
            .unwrap_err(),
        Error::Busy
    );
    assert!(c.snapshot().metadata.disabled_tools.is_empty());
    c.cancel(&run.operation_id);
    complete(run).await;

    let c = conversation(
        FakeProvider::new(vec![
            response(vec![call("approval"), ProviderEvent::Done]),
            answer(),
        ]),
        vec![Probe::new()],
    );
    let run = c.submit("act".into()).unwrap();
    approval(&c).await;
    assert_eq!(
        c.update_disabled_tools(vec!["change".into()])
            .await
            .unwrap_err(),
        Error::Busy
    );
    c.cancel(&run.operation_id);
    complete(run).await;
}

#[tokio::test]
async fn selections_publish_only_after_save_and_failed_save_blocks_work() {
    for fail in [false, true] {
        let entered = CancellationToken::new();
        let release = CancellationToken::new();
        let mut opts = options(FakeProvider::new(vec![]), vec![Probe::new()]);
        opts.checkpoint = Some(checkpoint({
            let entered = entered.clone();
            let release = release.clone();
            move |record| {
                assert_eq!(record.metadata.disabled_tools, ["change"]);
                let entered = entered.clone();
                let release = release.clone();
                async move {
                    entered.cancel();
                    release.cancelled().await;
                    if fail { Err(Error::Storage) } else { Ok(()) }
                }
            }
        }));
        let c = Conversation::new(opts, None).unwrap();
        let updating = c.clone();
        let task =
            tokio::spawn(
                async move { updating.update_disabled_tools(vec!["change".into()]).await },
            );
        entered.cancelled().await;
        assert!(c.snapshot().metadata.disabled_tools.is_empty());
        assert!(matches!(c.submit("blocked".into()), Err(Error::Busy)));
        release.cancel();
        let result = task.await.unwrap();
        if fail {
            assert_eq!(result.unwrap_err(), Error::Storage);
            assert!(c.snapshot().metadata.disabled_tools.is_empty());
            assert!(matches!(c.submit("blocked".into()), Err(Error::Storage)));
        } else {
            assert_eq!(result.unwrap().metadata.disabled_tools, ["change"]);
        }
    }
}

#[tokio::test]
async fn selections_survive_restart_forks_and_temporarily_missing_tools() {
    let profile = directory();
    let workspace = directory();
    let provider = FakeProvider::new(vec![answer(), answer(), answer(), answer()]);
    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![Probe::new()]),
    )
    .await
    .unwrap();
    let c = manager
        .create_session(
            provider.clone(),
            vec![Probe::new()],
            Some("fake".into()),
            workspace.path().to_string_lossy().into_owned(),
            None,
            Some(vec!["change".into(), "delegate".into()]),
        )
        .await
        .unwrap();
    let fork = manager
        .fork(&c.id, provider.clone(), vec![Probe::new()])
        .await
        .unwrap();
    assert_eq!(
        fork.snapshot().metadata.disabled_tools,
        ["change", "delegate"]
    );
    complete(fork.submit("inherited selection".into()).unwrap()).await;
    fork.update_disabled_tools(vec![]).await.unwrap();
    complete(fork.submit("fork selection changed".into()).unwrap()).await;
    assert_eq!(c.snapshot().metadata.disabled_tools, ["change", "delegate"]);
    manager.close().await.unwrap();
    // An unavailable tool in persisted metadata must not make a session unreadable.
    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    let restored = manager.get(&c.id).unwrap();
    assert_eq!(
        restored.snapshot().metadata.disabled_tools,
        ["change", "delegate"]
    );
    let restored_fork = manager.get(&fork.id).unwrap();
    assert!(restored_fork.snapshot().metadata.disabled_tools.is_empty());
    complete(restored.submit("restored selection".into()).unwrap()).await;
    complete(restored_fork.submit("missing change tool".into()).unwrap()).await;
    restored.update_disabled_tools(vec![]).await.unwrap();
    manager.close().await.unwrap();
    let requests = provider.requests.lock().unwrap();
    assert_eq!(requests.len(), 4);
    for (request, names) in
        requests
            .iter()
            .zip([vec![], vec!["change", "delegate"], vec![], vec!["delegate"]])
    {
        assert_eq!(
            request
                .tools
                .iter()
                .map(|d| d.name.as_str())
                .collect::<Vec<_>>(),
            names
        );
        assert_eq!(request.messages.len(), request.message_ids.len());
    }
    assert!(requests[3].messages.starts_with(&requests[1].messages));
    assert!(
        requests[3]
            .message_ids
            .starts_with(&requests[1].message_ids)
    );
}

#[test]
fn old_records_default_to_all_tools_and_invalid_names_are_rejected() {
    let c = conversation(FakeProvider::new(vec![]), vec![]);
    let mut value = serde_json::to_value(c.record()).unwrap();
    value["metadata"]
        .as_object_mut()
        .unwrap()
        .remove("disabledTools");
    let old: ConversationRecord = serde_json::from_value(value).unwrap();
    assert!(old.recover().unwrap().metadata.disabled_tools.is_empty());
    // Availability queries have a stricter syntax and a 128-name limit. Saved
    // selections retain their original 256-name, non-whitespace contract.
    let retained: Vec<_> = (0..256).map(|n| format!("legacy.tool/{n}")).collect();
    let mut record = c.record();
    record.metadata.disabled_tools = retained.clone();
    record.validate().unwrap();
    let library = LibraryConfiguration {
        default_disabled_tools: retained,
        ..Default::default()
    };
    library.validate().unwrap();
    for names in [
        vec!["".into()],
        vec!["change".into(), "change".into()],
        vec!["bad\0name".into()],
        vec!["bad name".into()],
        vec!["x".repeat(129)],
        vec!["change".into(); 257],
        (0..257).map(|n| format!("legacy.tool/{n}")).collect(),
    ] {
        let mut record = c.record();
        record.metadata.disabled_tools = names;
        assert!(record.validate().is_err());
    }
}

#[tokio::test]
async fn delegated_children_inherit_enforcement_and_cannot_change_selection() {
    let workspace = directory();
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let child_waiting = CancellationToken::new();
    let provider = FakeProvider::new(vec![
        response(vec![
            ProviderEvent::ToolCall(ToolCall {
                id: "delegate".into(),
                name: "delegate".into(),
                arguments: json!({"task":"inspect", "title":"Child"})
                    .as_object()
                    .unwrap()
                    .clone(),
            }),
            ProviderEvent::Done,
        ]),
        script({
            let entered = entered.clone();
            let release = release.clone();
            move |request| {
                Box::pin(async_stream::try_stream! {
                    assert!(request.tools.is_empty());
                    assert!(matches!(request.messages.last(), Some(ContextMessage::ToolAvailability { enabled }) if enabled.is_empty()));
                    entered.cancel();
                    release.cancelled().await;
                    yield call("forbidden");
                    yield ProviderEvent::Done;
                })
            }
        }),
        // Keep the child running until the parent cancellation is exercised.
        waiting(child_waiting.clone()),
    ]);
    let manager = Arc::new(AgentManager::default());
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    let probe = Probe::new();
    let parent = manager
        .create_session(
            provider.clone(),
            vec![probe.clone()],
            Some("fake".into()),
            workspace.path().to_string_lossy().into_owned(),
            None,
            Some(vec!["change".into()]),
        )
        .await
        .unwrap();
    let run = manager.submit(&parent.id, "delegate".into()).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
    let child = manager
        .list()
        .unwrap()
        .into_iter()
        .find(|s| s.metadata.parent.is_some())
        .unwrap();
    assert_eq!(child.metadata.disabled_tools, ["change"]);
    let child = manager.get(&child.id).unwrap();
    release.cancel();
    tokio::time::timeout(std::time::Duration::from_secs(5), child_waiting.cancelled())
        .await
        .unwrap();
    // Fork while the child still exists: cancelled delegates are now removed
    // after their bounded results have been checkpointed in the parent.
    let fork = manager
        .fork(&child.id, provider.clone(), vec![probe.clone()])
        .await
        .unwrap();
    assert!(fork.snapshot().metadata.parent.is_none());
    assert_eq!(fork.snapshot().metadata.disabled_tools, ["change"]);
    fork.update_disabled_tools(vec![]).await.unwrap();
    parent.cancel(&run.operation_id);
    complete(run).await;
    assert!(manager.get(&child.id).is_err());
    assert_eq!(outcomes(&child), [ToolOutcome::NotExecuted]);
    assert_eq!(probe.preparations.load(Ordering::SeqCst), 0);
    // Restoring an idle child must still reject selection changes on policy,
    // rather than merely because the live child is busy or already disposed.
    let record = child.record();
    let mut options =
        ConversationOptions::new(provider, record.model.clone(), record.workspace.clone());
    options.tools = vec![probe];
    let restored = Conversation::new(options, Some(record)).unwrap();
    assert!(matches!(
        restored.update_disabled_tools(vec![]).await,
        Err(Error::Invalid(
            "Sub-agents inherit their parent's tool selection."
        ))
    ));
    manager.close().await.unwrap();
}
