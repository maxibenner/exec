mod support;
use exec_agent::{Error, core::*};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use support::*;
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn steering_withdraws_approval_pairs_calls_then_injects_input() {
    let provider = FakeProvider::new(vec![
        response(vec![call("a"), call("b"), ProviderEvent::Done]),
        answer(),
    ]);
    let c = conversation(
        provider.clone(),
        vec![tool(Some("old action"), |_| async {
            panic!("superseded action ran")
        })],
    );
    let run = c.submit("original".into()).unwrap();
    let a = approval(&c).await;
    assert!(matches!(
        c.steer(&new_id(), "stale".into()),
        Err(Error::Busy)
    ));
    let id = c
        .steer(&run.operation_id, "do something else".into())
        .unwrap();
    assert!(!c.resolve_approval(&run.operation_id, &a.id, true));
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(
        outcomes(&c),
        [ToolOutcome::NotExecuted, ToolOutcome::NotExecuted]
    );
    assert!(c.snapshot().pending_input.is_empty());
    let requests = provider.requests.lock().unwrap();
    assert!(
        matches!(requests[1].messages.last(), Some(ContextMessage::User { text }) if text == "do something else")
    );
    assert!(c.snapshot().messages.iter().any(|m| m.id() == id));
}

#[tokio::test]
async fn steering_during_stream_is_saved_without_polluting_current_request() {
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = entered.clone();
    let held = release.clone();
    let provider = FakeProvider::new(vec![
        script(move |_| {
            Box::pin(async_stream::try_stream! {
                yield ProviderEvent::Text("partial".into()); ready.cancel(); held.cancelled().await; yield ProviderEvent::Done;
            })
        }),
        answer(),
    ]);
    let records = Arc::new(Mutex::new(Vec::new()));
    let saved = records.clone();
    let mut opts = options(provider.clone(), vec![]);
    opts.checkpoint = Some(checkpoint(move |record| {
        saved.lock().unwrap().push(record);
        async { Ok(()) }
    }));
    let c = Conversation::new(opts, None).unwrap();
    let run = c.submit("original".into()).unwrap();
    entered.cancelled().await;
    c.steer(&run.operation_id, "new input".into()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            if records
                .lock()
                .unwrap()
                .iter()
                .any(|r| !r.pending_input.is_empty())
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(provider.count(), 1);
    assert_eq!(provider.requests.lock().unwrap()[0].messages.len(), 1);
    release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(provider.count(), 2);
    for record in records.lock().unwrap().iter() {
        record.validate().unwrap();
    }
}

#[tokio::test]
async fn steering_keeps_live_executor_owned_and_skips_later_actions() {
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = entered.clone();
    let held = release.clone();
    let effects = Arc::new(AtomicUsize::new(0));
    let count = effects.clone();
    let provider = FakeProvider::new(vec![
        response(vec![call("a"), call("b"), ProviderEvent::Done]),
        answer(),
    ]);
    let c = conversation(
        provider,
        vec![tool(None, move |_| {
            count.fetch_add(1, Ordering::SeqCst);
            let ready = ready.clone();
            let held = held.clone();
            async move {
                ready.cancel();
                held.cancelled().await;
                Ok("first completed".into())
            }
        })],
    );
    let run = c.submit("original".into()).unwrap();
    entered.cancelled().await;
    c.steer(&run.operation_id, "change direction".into())
        .unwrap();
    assert_eq!(c.snapshot().active_tool_call_id.as_deref(), Some("a"));
    assert!(c.busy());
    release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(effects.load(Ordering::SeqCst), 1);
    assert_eq!(
        outcomes(&c),
        [ToolOutcome::Completed, ToolOutcome::NotExecuted]
    );
}

#[tokio::test]
async fn cancelled_and_recovered_pending_input_never_replays_itself() {
    let entered = CancellationToken::new();
    let p = FakeProvider::new(vec![waiting(entered.clone())]);
    let c = conversation(p.clone(), vec![]);
    let run = c.submit("original".into()).unwrap();
    entered.cancelled().await;
    let id = c
        .steer(&run.operation_id, "retained instruction".into())
        .unwrap();
    assert!(c.cancel(&run.operation_id));
    assert!(matches!(
        c.steer(&run.operation_id, "too late".into()),
        Err(Error::Busy)
    ));
    complete(run).await;
    let saved = c.record();
    saved.validate().unwrap();
    assert_eq!(saved.pending_input.len(), 1);
    let p = FakeProvider::new(vec![answer()]);
    let restored = Conversation::new(options(p.clone(), vec![]), Some(saved)).unwrap();
    assert_eq!(p.count(), 0);
    assert_eq!(restored.snapshot().pending_input[0].id(), id);
    complete(restored.submit("Continue explicitly".into()).unwrap()).await;
    let requests = p.requests.lock().unwrap();
    assert!(
        matches!(&requests[0].messages[1], ContextMessage::User { text } if text == "retained instruction")
    );
    assert!(restored.snapshot().pending_input.is_empty());
}

#[tokio::test]
async fn steering_before_executor_entry_prevents_auto_approved_effects() {
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = entered.clone();
    let held = release.clone();
    let provider = FakeProvider::new(vec![
        response(vec![call("a"), ProviderEvent::Done]),
        answer(),
    ]);
    let mut opts = options(
        provider,
        vec![tool(Some("effect"), |_| async {
            panic!("outdated action executed")
        })],
    );
    opts.settings.auto_approve = true;
    opts.checkpoint = Some(checkpoint(move |record| {
        let ready = ready.clone();
        let held = held.clone();
        async move {
            if record.executing_tool_id.is_some() {
                ready.cancel();
                held.cancelled().await;
            }
            Ok(())
        }
    }));
    let c = Conversation::new(opts, None).unwrap();
    let run = c.submit("original".into()).unwrap();
    entered.cancelled().await;
    c.steer(&run.operation_id, "stop that action".into())
        .unwrap();
    release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(outcomes(&c), [ToolOutcome::NotExecuted]);
}
