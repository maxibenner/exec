mod support;
use exec_agent::{Error, core::*, manager::AgentManager, storage::JsonConversationStore};
use futures_util::stream;
use std::{sync::Arc, time::Duration};
use support::*;
use tokio_util::sync::CancellationToken;

struct ManagedImageTool(&'static str);
#[async_trait::async_trait]
impl Tool for ManagedImageTool {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: self.0.into(),
            description: "Must stay in the parent".into(),
            parameters: Default::default(),
        }
    }
    async fn prepare(
        &self,
        _: Arguments,
        _: ToolContext,
    ) -> exec_agent::Result<Box<dyn PreparedTool>> {
        panic!("child must not prepare managed image tools")
    }
}
fn image_tools() -> Vec<Arc<dyn Tool>> {
    vec![
        Arc::new(ManagedImageTool("generate_image")),
        Arc::new(ManagedImageTool("take_screenshot")),
    ]
}
fn forbidden_image_call() -> ProviderEvent {
    ProviderEvent::ToolCall(ToolCall {
        id: "forbidden-image".into(),
        name: "generate_image".into(),
        arguments: Default::default(),
    })
}

#[tokio::test]
async fn delegated_children_cannot_execute_managed_image_tools_even_if_the_model_calls_them() {
    let workspace = directory();
    let provider = FakeProvider::new(vec![
        response(vec![
            delegate("delegate-one", "Review this task"),
            ProviderEvent::Done,
        ]),
        response(vec![forbidden_image_call(), ProviderEvent::Done]),
        answer(),
        answer(),
    ]);
    let manager = Arc::new(AgentManager::default());
    let parent = root(&manager, provider.clone(), image_tools(), workspace.path()).await;
    assert_eq!(
        finish(manager.submit(&parent.id, "Delegate".into()).await.unwrap())
            .await
            .state,
        OperationState::Completed
    );
    let requests = provider.requests.lock().unwrap();
    assert!(requests[0].tools.iter().any(|t| t.name == "generate_image"));
    assert!(
        requests[0]
            .tools
            .iter()
            .any(|t| t.name == "take_screenshot")
    );
    assert!(
        requests[1]
            .tools
            .iter()
            .all(|t| !matches!(t.name.as_str(), "generate_image" | "take_screenshot"))
    );
    assert!(requests[2].messages.iter().any(|m| matches!(m, ContextMessage::Tool { call_id, outcome: ToolOutcome::Failed, .. } if call_id == "forbidden-image")));
}

#[tokio::test]
async fn restored_children_also_exclude_managed_image_executors() {
    let profile = directory();
    let provider = FakeProvider::new(vec![
        response(vec![forbidden_image_call(), ProviderEvent::Done]),
        answer(),
    ]);
    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), image_tools()),
    )
    .await
    .unwrap();
    let mut child_options = options(provider.clone(), image_tools());
    child_options.workspace = profile.path().to_string_lossy().into_owned();
    child_options.metadata.parent = Some(SessionParent {
        session_id: new_id(),
        operation_id: new_id(),
        tool_call_id: "original-delegation".into(),
    });
    let child = manager.create(child_options).await.unwrap();
    manager.close().await.unwrap();
    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), image_tools()),
    )
    .await
    .unwrap();
    assert_eq!(
        finish(
            manager
                .submit(&child.id, "Continue explicitly".into())
                .await
                .unwrap()
        )
        .await
        .state,
        OperationState::Completed
    );
    assert!(provider.requests.lock().unwrap()[0].tools.is_empty());
    manager.delete(&child.id).await.unwrap();
    manager.close().await.unwrap();
}

fn delegate(id: &str, task: &str) -> ProviderEvent {
    ProviderEvent::ToolCall(ToolCall {
        id: id.into(),
        name: "delegate".into(),
        arguments: serde_json::json!({"task": task, "title": "Parser review"})
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
            Some(vec![]),
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
async fn new_delegates_use_current_model_and_effort_without_changing_previous_children() {
    let workspace = directory();
    let entered = [CancellationToken::new(), CancellationToken::new()];
    let release = [CancellationToken::new(), CancellationToken::new()];
    let mut scripts = Vec::new();
    for index in 0..2 {
        scripts.push(response(vec![
            delegate(
                &format!("delegate-{index}"),
                "Inspect current configuration",
            ),
            ProviderEvent::Done,
        ]));
        let entered = entered[index].clone();
        let release = release[index].clone();
        scripts.push(script(move |_| {
            Box::pin(async_stream::try_stream! {
                entered.cancel();
                release.cancelled().await;
                yield ProviderEvent::Text("Child answer".into());
                yield ProviderEvent::Done;
            })
        }));
        scripts.push(answer());
    }
    let provider = FakeProvider::new(scripts);
    let manager = Arc::new(AgentManager::default());
    let parent = root(&manager, provider.clone(), vec![], workspace.path()).await;
    assert_eq!(parent.snapshot().model, "fake");
    assert_eq!(
        parent.snapshot().configuration.settings.effort.as_deref(),
        Some("low")
    );
    let mut previous: Vec<Arc<Conversation>> = Vec::new();
    for (index, (model, effort)) in [("updated-model", Some("high")), ("another-model", None)]
        .into_iter()
        .enumerate()
    {
        manager
            .select_model(&parent.id, model.into())
            .await
            .unwrap();
        let mut settings = parent.snapshot().configuration.settings;
        settings.effort = effort.map(str::to_owned);
        manager.update_settings(&parent.id, settings).await.unwrap();
        let submission = manager
            .submit(&parent.id, "Delegate now".into())
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(5), entered[index].cancelled())
            .await
            .unwrap();
        let current = child(&manager).await;
        let snapshot = current.snapshot();
        assert_eq!(snapshot.model, model);
        assert_eq!(snapshot.configuration.settings.effort.as_deref(), effort);
        {
            let requests = provider.requests.lock().unwrap();
            let request = &requests[index * 3 + 1];
            assert_eq!(
                request.model, model,
                "Check the actual child inference, not just metadata"
            );
            assert_eq!(request.effort.as_deref(), effort);
        }
        // Even retained native references to an earlier child remain independent;
        // only a newly created child receives the parent's new selection.
        if let Some(earlier) = previous.first() {
            assert_eq!(earlier.snapshot().model, "updated-model");
            assert_eq!(
                earlier.snapshot().configuration.settings.effort.as_deref(),
                Some("high")
            );
        }
        release[index].cancel();
        assert_eq!(finish(submission).await.state, OperationState::Completed);
        previous.push(current);
    }
    assert_eq!(provider.count(), 6, "No extra inference or replay");
    manager.close().await.unwrap();
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
    let release = CancellationToken::new();
    let entered = CancellationToken::new();
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
        script({
            let release = release.clone();
            let entered = entered.clone();
            move |_| {
                Box::pin(async_stream::try_stream! {
                    entered.cancel();
                    release.cancelled().await;
                    yield ProviderEvent::Text(large_answer);
                    yield ProviderEvent::Done;
                })
            }
        }),
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
    tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
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
    assert_eq!(saved.metadata.title.as_deref(), Some("Parser review"));
    assert_eq!(saved.configuration, parent.snapshot().configuration);
    assert_eq!(saved.model, parent.snapshot().model);
    assert_eq!(saved.workspace, parent.snapshot().workspace);
    assert_eq!(child.record().max_steps, 128);
    release.cancel();
    assert_eq!(finish(submission).await.state, OperationState::Completed);
    assert!(manager.get(&child.id).is_err());
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
    let saved_parent = parent.snapshot();
    manager.close().await.unwrap();
    let restored = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    assert!(restored.get(&child.id).is_err());
    assert_eq!(restored.get(&parent.id).unwrap().snapshot(), saved_parent);
    assert_eq!(provider.count(), 3);
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
    assert!(manager.get(&child.id).is_err());
    assert_eq!(manager.list().unwrap().len(), 1);
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
    assert!(manager.get(&child.id).is_ok());
    cleanup.cancel();
    assert_eq!(finish(run).await.state, OperationState::Interrupted);
    assert!(!parent.busy() && !child.busy());
    assert!(manager.get(&child.id).is_err());
    assert_eq!(manager.list().unwrap().len(), 1);
    assert_eq!(provider.count(), 2);
}

#[tokio::test]
async fn user_deletion_waits_for_cleanup_and_reports_child_cancellation_to_parent() {
    for delete_parent in [false, true] {
        let workspace = directory();
        let entered = CancellationToken::new();
        let cancelled = CancellationToken::new();
        let cleanup = CancellationToken::new();
        let effect = tool(None, {
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
        });
        let mut scripts = vec![
            response(vec![delegate("d", "Work"), ProviderEvent::Done]),
            response(vec![call("effect"), ProviderEvent::Done]),
        ];
        if !delete_parent {
            scripts.push(answer());
        }
        let provider = FakeProvider::new(scripts);
        let manager = Arc::new(AgentManager::default());
        let parent = root(&manager, provider.clone(), vec![effect], workspace.path()).await;
        let run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
            .await
            .unwrap();
        let child = child(&manager).await;
        let deletion = tokio::spawn({
            let manager = manager.clone();
            let id = if delete_parent {
                parent.id.clone()
            } else {
                child.id.clone()
            };
            async move { manager.delete(&id).await }
        });
        tokio::time::timeout(Duration::from_secs(5), cancelled.cancelled())
            .await
            .unwrap();
        assert!(!deletion.is_finished());
        assert!(child.busy());
        cleanup.cancel();
        tokio::time::timeout(Duration::from_secs(5), deletion)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(
            finish(run).await.state,
            if delete_parent {
                OperationState::Interrupted
            } else {
                OperationState::Completed
            }
        );
        assert!(!child.busy());
        assert!(manager.get(&child.id).is_err());
        assert_eq!(
            manager.list().unwrap().len(),
            if delete_parent { 0 } else { 1 }
        );
        if !delete_parent {
            assert!(parent.snapshot().messages.iter().any(
                |m| matches!(m, Message::Tool { text, .. } if text.contains("cancelled by user"))
            ));
            assert!(provider.requests.lock().unwrap()[2].messages.iter().any(|m| matches!(m, ContextMessage::Tool { text, .. } if text.contains("cancelled by user"))));
        }
        assert_eq!(provider.count(), if delete_parent { 2 } else { 3 });
    }
}

#[tokio::test]
async fn failed_or_cancelled_children_return_failed_tool_results_and_are_removed_without_retry() {
    for cancel_child in [false, true] {
        let workspace = directory();
        let entered = CancellationToken::new();
        let provider = FakeProvider::new(vec![
            response(vec![delegate("d", "Work"), ProviderEvent::Done]),
            if cancel_child {
                waiting(entered.clone())
            } else {
                script(|_| Box::pin(stream::iter(vec![Err(Error::Internal)])))
            },
            answer(),
        ]);
        let manager = Arc::new(AgentManager::default());
        let parent = root(&manager, provider.clone(), vec![], workspace.path()).await;
        let run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
        if cancel_child {
            tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
                .await
                .unwrap();
            let child = child(&manager).await;
            assert!(child.cancel(&child.snapshot().operation.unwrap().id));
        }
        assert_eq!(finish(run).await.state, OperationState::Completed);
        assert_eq!(manager.list().unwrap().len(), 1);
        let reason = if cancel_child {
            "cancelled by user"
        } else {
            "failed"
        };
        assert!(parent.snapshot().messages.iter().any(|m| matches!(m, Message::Tool { text, outcome: ToolOutcome::Failed, .. } if text.contains("Sub-agent session") && text.contains(reason) && text.contains("Do not retry"))));
        assert_eq!(provider.count(), 3);
    }
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
    assert_eq!(sessions.len(), 1);
    assert!(
        provider.requests.lock().unwrap()[2].messages.iter().any(
            |m| matches!(m, ContextMessage::Tool { text, .. } if text.contains("Unknown tool"))
        )
    );
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
    let mut legacy_parent = parent.record();
    legacy_parent.max_steps = 64;
    let mut legacy_child = child.record();
    legacy_child.max_steps = 16;
    store.save(legacy_parent).await.unwrap();
    store.save(legacy_child).await.unwrap();
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
    assert_eq!(restored.get(&parent.id).unwrap().record().max_steps, 128);
    assert_eq!(restored.get(&child.id).unwrap().record().max_steps, 128);
    assert_eq!(provider.count(), 2);
    restored.close().await.unwrap();
}

#[tokio::test]
async fn parent_and_child_have_independent_full_step_budgets() {
    for child_tool_steps in [127, 128] {
        let workspace = directory();
        let mut scripts = vec![response(vec![
            delegate("delegate-budget", "Perform the child work"),
            ProviderEvent::Done,
        ])];
        scripts.extend(
            (0..child_tool_steps)
                .map(|i| response(vec![call(&format!("child-{i}")), ProviderEvent::Done])),
        );
        if child_tool_steps == 127 {
            scripts.push(answer());
        }
        // The parent can still use all 127 remaining steps, even when its child
        // consumes its entire independent budget or fails at that boundary.
        scripts.extend(
            (0..126).map(|i| response(vec![call(&format!("parent-{i}")), ProviderEvent::Done])),
        );
        scripts.push(answer());
        let provider = FakeProvider::new(scripts);
        let manager = Arc::new(AgentManager::default());
        let parent = root(
            &manager,
            provider.clone(),
            vec![tool(None, |_| async { Ok("done".into()) })],
            workspace.path(),
        )
        .await;
        let operation = finish(
            manager
                .submit(&parent.id, "Delegate work".into())
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(operation.state, OperationState::Completed);
        assert_eq!(provider.count(), 256);
        assert_eq!(outcomes(&parent).len(), 127);
        let snapshot = parent.snapshot();
        let child_result = snapshot
            .messages
            .iter()
            .find_map(|message| match message {
                Message::Tool {
                    call_id, outcome, ..
                } if call_id == "delegate-budget" => Some(*outcome),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            child_result,
            if child_tool_steps == 127 {
                ToolOutcome::Completed
            } else {
                ToolOutcome::Failed
            }
        );
    }
}
