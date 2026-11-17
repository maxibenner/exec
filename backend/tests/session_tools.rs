mod support;

use async_trait::async_trait;
use exec_agent::{Error, Result, core::*, manager::AgentManager, storage::JsonConversationStore};
use serde_json::json;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use support::*;
use tokio_util::sync::CancellationToken;

struct Probe {
    inner: Arc<dyn Tool>,
    preparations: AtomicUsize,
    saved: AtomicUsize,
}
impl Probe {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: tool(Some("effect"), |_| async { Ok("done".into()) }),
            preparations: AtomicUsize::new(0),
            saved: AtomicUsize::new(0),
        })
    }
}
#[async_trait]
impl Tool for Probe {
    fn definition(&self) -> ToolDefinition {
        self.inner.definition()
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
async fn disabled_tools_are_not_advertised_prepared_or_executed_and_can_be_reenabled() {
    let provider = FakeProvider::new(vec![
        response(vec![call("disabled"), ProviderEvent::Done]),
        answer(),
        response(vec![call("enabled"), ProviderEvent::Done]),
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
        assert!(!request.instructions.contains("Use the provided tools"));
    }
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
    assert_eq!(provider.requests.lock().unwrap()[2].tools[0].name, "change");
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
    let provider = FakeProvider::new(vec![]);
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
            vec!["change".into(), "delegate".into()],
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
    fork.update_disabled_tools(vec![]).await.unwrap();
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
    assert!(
        manager
            .get(&fork.id)
            .unwrap()
            .snapshot()
            .metadata
            .disabled_tools
            .is_empty()
    );
    restored.update_disabled_tools(vec![]).await.unwrap();
    manager.close().await.unwrap();
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
    for names in [
        vec!["".into()],
        vec!["change".into(), "change".into()],
        vec!["bad\0name".into()],
        vec!["bad name".into()],
        vec!["x".repeat(129)],
        vec!["change".into(); 257],
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
                    entered.cancel();
                    release.cancelled().await;
                    yield call("forbidden");
                    yield ProviderEvent::Done;
                })
            }
        }),
        // Parent cancellation retains unfinished children for inspection.
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
            vec!["change".into()],
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
    release.cancel();
    tokio::time::timeout(std::time::Duration::from_secs(5), child_waiting.cancelled())
        .await
        .unwrap();
    parent.cancel(&run.operation_id);
    complete(run).await;
    let child = manager.get(&child.id).unwrap();
    assert_eq!(outcomes(&child), [ToolOutcome::NotExecuted]);
    assert_eq!(probe.preparations.load(Ordering::SeqCst), 0);
    assert!(matches!(
        child.update_disabled_tools(vec![]).await,
        Err(Error::Invalid(_))
    ));
    // A user-created fork is independent, but initially inherits the child's policy.
    let fork = manager
        .fork(&child.id, provider, vec![probe])
        .await
        .unwrap();
    assert!(fork.snapshot().metadata.parent.is_none());
    assert_eq!(fork.snapshot().metadata.disabled_tools, ["change"]);
    fork.update_disabled_tools(vec![]).await.unwrap();
    manager.close().await.unwrap();
}
