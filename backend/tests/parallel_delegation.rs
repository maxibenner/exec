mod support;
use exec_agent::{core::*, manager::AgentManager};
use std::{sync::Arc, time::Duration};
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
    cleanup.cancel();
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    let children: Vec<_> = manager
        .list()
        .unwrap()
        .into_iter()
        .filter(|s| s.metadata.parent.is_some())
        .collect();
    assert_eq!(children.len(), 2);
    for child in children {
        let child = manager.get(&child.id).unwrap();
        assert!(!child.busy());
        assert_eq!(
            child.snapshot().operation.unwrap().state,
            OperationState::Interrupted
        );
    }
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
async fn steering_a_child_withdraws_approval_and_reaches_its_context() {
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
            panic!("steering must withdraw approval")
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
    manager
        .steer(
            &child.id,
            &child.operation.unwrap().id,
            "Do not run the tool; explain instead".into(),
        )
        .unwrap();
    assert_eq!(complete(run).await.state, OperationState::Completed);
    let requests = provider.requests.lock().unwrap();
    assert!(requests[2].messages.iter().any(|m| matches!(m, ContextMessage::User { text, .. } if text == "Do not run the tool; explain instead")));
    assert_eq!(requests.len(), 4);
    assert_eq!(manager.list().unwrap().len(), 1);
}
