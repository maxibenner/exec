//! Explicit non-final completions are next decisions, never retries or resumed tasks.
mod support;
use exec_agent::{Error, core::*};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use support::*;
use tokio_util::sync::CancellationToken;

fn progress() -> Script {
    response(vec![
        ProviderEvent::Text("Progress".into()),
        ProviderEvent::Continue,
    ])
}

#[tokio::test]
async fn nonfinal_responses_exhaust_the_existing_budget_and_never_resume_on_restore() {
    let provider = FakeProvider::new(vec![progress(), progress()]);
    let mut opts = options(provider.clone(), vec![]);
    opts.max_steps = 2;
    let conversation = Conversation::new(opts, None).unwrap();
    let operation = complete(conversation.submit("Task".into()).unwrap()).await;
    assert_eq!(operation.state, OperationState::Failed);
    assert!(operation.error.unwrap().contains("step limit"));
    assert_eq!(provider.count(), 2);
    let saved = conversation.record();
    saved.validate().unwrap();
    let restored_provider = FakeProvider::new(vec![]);
    let restored =
        Conversation::new(options(restored_provider.clone(), vec![]), Some(saved)).unwrap();
    assert!(!restored.busy());
    assert_eq!(restored_provider.count(), 0);
}

#[tokio::test]
async fn cancellation_after_nonfinal_checkpoint_sends_no_next_request() {
    let provider = FakeProvider::new(vec![progress()]);
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = entered.clone();
    let held = release.clone();
    let armed = Arc::new(AtomicBool::new(true));
    let mut opts = options(provider.clone(), vec![]);
    opts.checkpoint = Some(checkpoint(move |record| {
        let ready = ready.clone();
        let held = held.clone();
        let block = matches!(
            record.messages.last(),
            Some(Message::Assistant {
                status: MessageStatus::Completed,
                ..
            })
        ) && armed.swap(false, Ordering::SeqCst);
        async move {
            record.validate().unwrap();
            if block {
                ready.cancel();
                held.cancelled().await;
            }
            Ok(())
        }
    }));
    let conversation = Conversation::new(opts, None).unwrap();
    let run = conversation.submit("Task".into()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
    assert!(conversation.cancel(&run.operation_id));
    release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(provider.count(), 1);
    conversation.record().validate().unwrap();
}

#[tokio::test]
async fn failed_stream_after_progress_never_executes_partial_tools_or_retries() {
    let provider = FakeProvider::new(vec![
        progress(),
        script(|_| {
            Box::pin(futures_util::stream::iter([
                Ok(call("partial")),
                Err(Error::Internal),
            ]))
        }),
    ]);
    let conversation = conversation(
        provider.clone(),
        vec![tool(None, |_| async {
            panic!("unfinalized tool executed")
        })],
    );
    assert_eq!(
        complete(conversation.submit("Task".into()).unwrap())
            .await
            .state,
        OperationState::Failed
    );
    assert_eq!(provider.count(), 2);
    assert!(outcomes(&conversation).is_empty());
    assert!(matches!(
        conversation.snapshot().messages.last(),
        Some(Message::Assistant {
            status: MessageStatus::Failed,
            ..
        })
    ));
    conversation.record().validate().unwrap();
}
