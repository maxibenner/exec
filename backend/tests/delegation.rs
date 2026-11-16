mod support;

use exec_agent::{Error, core::*, manager::AgentManager, storage::JsonConversationStore};
use futures_util::stream;
use std::{sync::Arc, time::Duration};
use support::*;
use tokio_util::sync::CancellationToken;

fn delegate(id: &str, task: &str) -> ProviderEvent {
    ProviderEvent::ToolCall(ToolCall {
        id: id.into(),
        name: "delegate".into(),
        arguments: serde_json::json!({"task": task})
            .as_object()
            .unwrap()
            .clone(),
    })
}
async fn root(
    manager: &Arc<AgentManager>,
    provider: Arc<dyn ChatProvider>,
    tools: Vec<Arc<dyn Tool>>,
    workspace: &std::path::Path,
) -> Arc<Conversation> {
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    manager
        .create_session(
            provider,
            tools,
            Some("fake".into()),
            workspace.to_string_lossy().into_owned(),
            Some(SessionSettings {
                system_prompt: "Inherited instructions".into(),
                auto_approve: false,
                effort: Some("low".into()),
                search_model: Some("search-model".into()),
            }),
        )
        .await
        .unwrap()
}
async fn child(manager: &AgentManager) -> Arc<Conversation> {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(snapshot) = manager
                .list()
                .unwrap()
                .into_iter()
                .find(|s| s.metadata.parent.is_some())
            {
                return manager.get(&snapshot.id).unwrap();
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap()
}
async fn finish(submission: Submission) -> Operation {
    tokio::time::timeout(Duration::from_secs(5), submission.completion)
        .await
        .unwrap()
        .unwrap()
}

#[tokio::test]
async fn delegation_reuses_sessions_without_sharing_context_and_survives_restore() {
    let profile = directory();
    let workspace = directory();
    std::fs::write(
        workspace.path().join("AGENTS.md"),
        "Frozen project instructions",
    )
    .unwrap();
    let large_answer = "é".repeat(20_000);
    let provider = FakeProvider::new(vec![
        response(vec![
            delegate("delegate-one", "Inspect the parser"),
            ProviderEvent::Metadata {
                state: Some(serde_json::json!({"opaque":"parent-only"})),
                usage: None,
            },
            ProviderEvent::Done,
        ]),
        response(vec![ProviderEvent::Text(large_answer), ProviderEvent::Done]),
        answer(),
    ]);
    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    let parent = root(&manager, provider.clone(), vec![], workspace.path()).await;
    let submission = manager
        .submit(
            &parent.id,
            "Private parent context; delegate parser inspection".into(),
        )
        .await
        .unwrap();
    let operation_id = submission.operation_id.clone();
    assert_eq!(finish(submission).await.state, OperationState::Completed);
    let child = child(&manager).await;
    let saved = child.snapshot();
    assert_eq!(
        saved.metadata.parent,
        Some(SessionParent {
            session_id: parent.id.clone(),
            operation_id,
            tool_call_id: "delegate-one".into()
        })
    );
    assert_eq!(saved.metadata.title.as_deref(), Some("Inspect the parser"));
    assert_eq!(saved.configuration, parent.snapshot().configuration);
    assert_eq!(saved.model, parent.snapshot().model);
    assert_eq!(saved.workspace, parent.snapshot().workspace);
    assert_eq!(child.record().max_steps, 16);
    {
        let requests = provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 3);
        assert!(requests[0].tools.iter().any(|t| t.name == "delegate"));
        assert!(requests[1].tools.iter().all(|t| t.name != "delegate"));
        assert!(requests[1].provider_state.is_none());
        assert_eq!(requests[1].messages.len(), 1);
        assert!(
            matches!(&requests[1].messages[0], ContextMessage::User { text, .. } if text == "Inspect the parser")
        );
        assert!(
            requests[1]
                .instructions
                .contains("Frozen project instructions")
        );
        assert!(requests[1].instructions.contains("Inherited instructions"));
        assert_eq!(requests[1].effort.as_deref(), Some("low"));
        let text = requests[2]
            .messages
            .iter()
            .find_map(|m| match m {
                ContextMessage::Tool { text, .. } => Some(text),
                _ => None,
            })
            .unwrap();
        assert!(text.contains(&child.id) && text.contains("Response truncated"));
        assert!(text.len() < 33 * 1024);
    }
    assert!(manager.delete(&parent.id).await.is_err());
    let fork = manager
        .fork(&child.id, provider.clone(), vec![])
        .await
        .unwrap();
    assert!(fork.parent().is_none());
    manager.delete(&fork.id).await.unwrap();
    manager.close().await.unwrap();
    let restored = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    assert_eq!(restored.get(&child.id).unwrap().snapshot(), saved);
    assert_eq!(provider.count(), 3);
    restored.delete(&child.id).await.unwrap();
    restored.delete(&parent.id).await.unwrap();
    restored.close().await.unwrap();
}

#[tokio::test]
async fn parent_cancellation_interrupts_a_child_approval_without_executing_it() {
    let workspace = directory();
    let provider = FakeProvider::new(vec![
        response(vec![
            delegate("delegate-one", "Run checks"),
            ProviderEvent::Done,
        ]),
        response(vec![call("child-effect"), ProviderEvent::Done]),
    ]);
    let manager = Arc::new(AgentManager::default());
    let parent = root(
        &manager,
        provider.clone(),
        vec![tool(Some("Run checks"), |_| async {
            panic!("approval was never granted")
        })],
        workspace.path(),
    )
    .await;
    let run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    let child = child(&manager).await;
    let pending = approval(&child).await;
    assert_eq!(pending.workspace, parent.snapshot().workspace);
    assert!(matches!(manager.delete(&child.id).await, Err(Error::Busy)));
    assert!(
        manager
            .submit(&child.id, "Another turn".into())
            .await
            .is_err()
    );
    assert!(manager.compact(&child.id).is_err());
    assert!(parent.cancel(&run.operation_id));
    assert_eq!(finish(run).await.state, OperationState::Interrupted);
    assert_eq!(
        child.snapshot().operation.unwrap().state,
        OperationState::Interrupted
    );
    assert!(child.snapshot().approval.is_none());
    assert!(!child.resolve_approval(&pending.operation_id, &pending.id, true));
    assert_eq!(provider.count(), 2);
    assert!(!child.busy());
}

#[tokio::test]
async fn parent_keeps_ownership_until_child_tool_cleanup_finishes() {
    let workspace = directory();
    let entered = CancellationToken::new();
    let cancelled = CancellationToken::new();
    let cleanup = CancellationToken::new();
    let tools = vec![tool(None, {
        let entered = entered.clone();
        let cancelled = cancelled.clone();
        let cleanup = cleanup.clone();
        move |context| {
            let entered = entered.clone();
            let cancelled = cancelled.clone();
            let cleanup = cleanup.clone();
            async move {
                entered.cancel();
                context.cancel.cancelled().await;
                cancelled.cancel();
                cleanup.cancelled().await;
                Err(Error::Cancelled)
            }
        }
    })];
    let provider = FakeProvider::new(vec![
        response(vec![delegate("d", "Work"), ProviderEvent::Done]),
        response(vec![call("c"), ProviderEvent::Done]),
    ]);
    let manager = Arc::new(AgentManager::default());
    let parent = root(&manager, provider.clone(), tools, workspace.path()).await;
    let run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
    let child = child(&manager).await;
    parent.cancel(&run.operation_id);
    tokio::time::timeout(Duration::from_secs(5), cancelled.cancelled())
        .await
        .unwrap();
    assert!(parent.busy() && child.busy());
    cleanup.cancel();
    assert_eq!(finish(run).await.state, OperationState::Interrupted);
    assert!(!parent.busy() && !child.busy());
    assert_eq!(provider.count(), 2);
}

#[tokio::test]
async fn child_failure_returns_a_failed_tool_result_without_retrying() {
    let workspace = directory();
    let provider = FakeProvider::new(vec![
        response(vec![delegate("d", "Work"), ProviderEvent::Done]),
        script(|_| Box::pin(stream::iter(vec![Err(Error::Internal)]))),
        answer(),
    ]);
    let manager = Arc::new(AgentManager::default());
    let parent = root(&manager, provider.clone(), vec![], workspace.path()).await;
    assert_eq!(
        finish(manager.submit(&parent.id, "Delegate".into()).await.unwrap())
            .await
            .state,
        OperationState::Completed
    );
    let child = child(&manager).await;
    assert_eq!(
        child.snapshot().operation.unwrap().state,
        OperationState::Failed
    );
    assert!(parent.snapshot().messages.iter().any(|m| matches!(m, Message::Tool { text, outcome: ToolOutcome::Failed, .. } if text.contains(&child.id) && text.contains("Do not retry"))));
    assert_eq!(provider.count(), 3);
}

#[tokio::test]
async fn delegation_limits_spawning_and_children_cannot_recursively_delegate() {
    let workspace = directory();
    let mut calls: Vec<_> = (0..9)
        .map(|i| delegate(&format!("d-{i}"), "Work"))
        .collect();
    calls.push(ProviderEvent::Done);
    let mut scripts = vec![
        response(calls),
        response(vec![
            delegate("nested", "Recursive work"),
            ProviderEvent::Done,
        ]),
        answer(),
    ];
    scripts.extend((0..7).map(|_| answer()));
    scripts.push(answer());
    let provider = FakeProvider::new(scripts);
    let manager = Arc::new(AgentManager::default());
    let parent = root(&manager, provider.clone(), vec![], workspace.path()).await;
    finish(manager.submit(&parent.id, "Delegate".into()).await.unwrap()).await;
    let sessions = manager.list().unwrap();
    assert_eq!(sessions.len(), 9);
    assert!(sessions.iter().any(|s| s.messages.iter().any(|m| matches!(m, Message::Tool { call_id, outcome: ToolOutcome::Failed, .. } if call_id == "nested"))));
    assert!(parent.snapshot().messages.iter().any(|m| matches!(m, Message::Tool { call_id, text, outcome: ToolOutcome::Failed, .. } if call_id == "d-8" && text.contains("eight sub-agents"))));
    assert_eq!(provider.count(), 11);
}

#[tokio::test]
async fn restart_preserves_parent_links_and_interrupts_both_sessions_without_resuming() {
    let workspace = directory();
    let restored_profile = directory();
    let entered = CancellationToken::new();
    let provider = FakeProvider::new(vec![
        response(vec![delegate("d", "Work"), ProviderEvent::Done]),
        waiting(entered.clone()),
    ]);
    let manager = Arc::new(AgentManager::default());
    let parent = root(&manager, provider.clone(), vec![], workspace.path()).await;
    let run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
    let child = child(&manager).await;
    let store = JsonConversationStore::open(restored_profile.path())
        .await
        .unwrap();
    store.save(parent.record()).await.unwrap();
    store.save(child.record()).await.unwrap();
    exec_agent::storage::ConversationStore::close(store.as_ref())
        .await
        .unwrap();
    manager.cancel_and_wait().await.unwrap();
    assert_eq!(finish(run).await.state, OperationState::Interrupted);
    let restored = AgentManager::open(
        JsonConversationStore::open(restored_profile.path())
            .await
            .unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    for snapshot in restored.list().unwrap() {
        assert_eq!(
            snapshot.operation.unwrap().state,
            OperationState::Interrupted
        );
    }
    assert_eq!(restored.get(&child.id).unwrap().parent(), child.parent());
    assert_eq!(provider.count(), 2);
    restored.close().await.unwrap();
}
