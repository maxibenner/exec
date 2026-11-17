mod support;
use exec_agent::{Error, core::*};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use support::*;
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn steering_preserves_approvals_and_saves_input_until_calls_settle() {
    let provider = FakeProvider::new(vec![
        response(vec![call("a"), call("b"), ProviderEvent::Done]),
        answer(),
    ]);
    let effects = Arc::new(AtomicUsize::new(0));
    let count = effects.clone();
    let saved = CancellationToken::new();
    let signal = saved.clone();
    let mut opts = options(
        provider.clone(),
        vec![tool(Some("original action"), move |_| {
            count.fetch_add(1, Ordering::SeqCst);
            async { Ok("completed".into()) }
        })],
    );
    opts.checkpoint = Some(checkpoint(move |record| {
        record.validate().unwrap();
        if !record.pending_input.is_empty() {
            signal.cancel();
        }
        async { Ok(()) }
    }));
    let c = Conversation::new(opts, None).unwrap();
    let run = c.submit("original".into()).unwrap();
    let a = approval(&c).await;
    assert!(matches!(
        c.steer(&new_id(), "stale".into()),
        Err(Error::Busy)
    ));
    let id = c
        .steer(&run.operation_id, "do something else next".into())
        .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(3), saved.cancelled())
        .await
        .unwrap();
    assert_eq!(c.snapshot().approval.unwrap().id, a.id);
    assert_eq!(effects.load(Ordering::SeqCst), 0);
    assert_eq!(provider.count(), 1);
    assert!(c.resolve_approval(&run.operation_id, &a.id, true));
    let b = until(&c, |s| s.approval.as_ref().is_some_and(|b| b.id != a.id))
        .await
        .approval
        .unwrap();
    assert!(c.resolve_approval(&run.operation_id, &b.id, false));
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(effects.load(Ordering::SeqCst), 1);
    assert_eq!(outcomes(&c), [ToolOutcome::Completed, ToolOutcome::Denied]);
    assert!(c.snapshot().pending_input.is_empty());
    let requests = provider.requests.lock().unwrap();
    assert!(
        matches!(requests[1].messages.last(), Some(ContextMessage::User { text }) if text == "do something else next")
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
                yield ProviderEvent::Text("partial".into()); ready.cancel(); held.cancelled().await;
                yield call("a"); yield ProviderEvent::Done;
            })
        }),
        answer(),
    ]);
    let records = Arc::new(Mutex::new(Vec::new()));
    let saved = records.clone();
    let mut opts = options(
        provider.clone(),
        vec![tool(None, |context| async move {
            assert!(!context.cancel.is_cancelled());
            Ok("original action completed".into())
        })],
    );
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
    assert_eq!(outcomes(&c), [ToolOutcome::Completed]);
    assert!(matches!(
        provider.requests.lock().unwrap()[1].messages.last(),
        Some(ContextMessage::User { text }) if text == "new input"
    ));
    for record in records.lock().unwrap().iter() {
        record.validate().unwrap();
    }
}

#[tokio::test]
async fn steering_keeps_live_executor_and_remaining_calls_in_the_batch() {
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
        provider.clone(),
        vec![tool(None, move |context| {
            count.fetch_add(1, Ordering::SeqCst);
            let ready = ready.clone();
            let held = held.clone();
            async move {
                ready.cancel();
                held.cancelled().await;
                assert!(!context.cancel.is_cancelled());
                Ok(format!("{} completed", context.call_id))
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
    assert_eq!(effects.load(Ordering::SeqCst), 2);
    assert_eq!(
        outcomes(&c),
        [ToolOutcome::Completed, ToolOutcome::Completed]
    );
    let requests = provider.requests.lock().unwrap();
    assert!(matches!(
        &requests[1].messages[2],
        ContextMessage::Tool { call_id, text, outcome: ToolOutcome::Completed }
        if call_id == "a" && text == "a completed"
    ));
    assert!(matches!(
        &requests[1].messages[3],
        ContextMessage::Tool { call_id, text, outcome: ToolOutcome::Completed }
        if call_id == "b" && text == "b completed"
    ));
    assert!(matches!(
        requests[1].messages.last(),
        Some(ContextMessage::User { text }) if text == "change direction"
    ));
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
        matches!(&requests[0].messages[2], ContextMessage::User { text } if text == "retained instruction")
    );
    assert!(restored.snapshot().pending_input.is_empty());
}

#[tokio::test]
async fn steering_during_intent_checkpoint_preserves_approved_actions() {
    for auto_approve in [false, true] {
        let entered = CancellationToken::new();
        let release = CancellationToken::new();
        let ready = entered.clone();
        let held = release.clone();
        let effects = Arc::new(AtomicUsize::new(0));
        let count = effects.clone();
        let provider = FakeProvider::new(vec![
            response(vec![call("a"), ProviderEvent::Done]),
            answer(),
        ]);
        let mut opts = options(
            provider,
            vec![tool(Some("effect"), move |_| {
                count.fetch_add(1, Ordering::SeqCst);
                async { Ok("original action completed".into()) }
            })],
        );
        opts.settings.auto_approve = auto_approve;
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
        if !auto_approve {
            let a = approval(&c).await;
            assert!(c.resolve_approval(&run.operation_id, &a.id, true));
        }
        entered.cancelled().await;
        c.steer(&run.operation_id, "additional instructions".into())
            .unwrap();
        assert_eq!(effects.load(Ordering::SeqCst), 0);
        release.cancel();
        assert_eq!(complete(run).await.state, OperationState::Completed);
        assert_eq!(effects.load(Ordering::SeqCst), 1);
        assert_eq!(outcomes(&c), [ToolOutcome::Completed]);
    }
}

#[tokio::test]
async fn steering_during_preparation_does_not_discard_the_call() {
    struct PreparingTool {
        inner: Arc<dyn Tool>,
        entered: CancellationToken,
        release: CancellationToken,
    }
    #[async_trait::async_trait]
    impl Tool for PreparingTool {
        fn definition(&self) -> ToolDefinition {
            self.inner.definition()
        }
        async fn prepare(
            &self,
            args: Arguments,
            context: ToolContext,
        ) -> exec_agent::Result<Box<dyn PreparedTool>> {
            self.entered.cancel();
            self.release.cancelled().await;
            self.inner.prepare(args, context).await
        }
    }
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let provider = FakeProvider::new(vec![
        response(vec![call("a"), ProviderEvent::Done]),
        answer(),
    ]);
    let c = conversation(
        provider,
        vec![Arc::new(PreparingTool {
            inner: tool(Some("original action"), |_| async {
                Ok("completed".into())
            }),
            entered: entered.clone(),
            release: release.clone(),
        })],
    );
    let run = c.submit("original".into()).unwrap();
    entered.cancelled().await;
    c.steer(&run.operation_id, "additional instructions".into())
        .unwrap();
    release.cancel();
    let a = approval(&c).await;
    assert!(c.resolve_approval(&run.operation_id, &a.id, true));
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(outcomes(&c), [ToolOutcome::Completed]);
}
