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
        batch(serde_json::json!(["first", "second"])),
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
            batch(serde_json::json!(["first", "second"])),
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
async fn invalid_batches_never_create_children() {
    for tasks in [
        serde_json::json!([]),
        serde_json::json!([" "]),
        serde_json::json!([42]),
        serde_json::json!(["a", "b", "c", "d", "e", "f", "g", "h", "i"]),
    ] {
        let workspace = directory();
        let provider = FakeProvider::new(vec![
            response(vec![batch(tasks), ProviderEvent::Done]),
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
async fn failed_child_does_not_drop_siblings_and_only_successes_are_deleted() {
    let workspace = directory();
    let barrier = Arc::new(tokio::sync::Barrier::new(2));
    let mut scripts = vec![response(vec![
        batch(serde_json::json!(["fail", "succeed"])),
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
    assert_eq!(children.len(), 1);
    assert_eq!(
        children[0].operation.as_ref().unwrap().state,
        OperationState::Failed
    );
    assert!(parent.snapshot().messages.iter().any(|m| matches!(m, Message::Tool { text, .. } if text.contains("failed") && text.contains("Sibling completed") && text.contains(&children[0].id))));
    assert_eq!(provider.count(), 4);
}

#[tokio::test]
async fn steering_a_child_withdraws_approval_and_reaches_its_context() {
    let workspace = directory();
    let provider = FakeProvider::new(vec![
        response(vec![
            batch(serde_json::json!(["original task"])),
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
