mod support;
use exec_agent::{
    core::*,
    storage::{ConversationStore, JsonConversationStore},
};
use support::*;

#[tokio::test]
async fn dropping_completion_receipt_detaches_without_aborting_work() {
    let c = conversation(FakeProvider::new(vec![answer()]), vec![]);
    let submission = c.submit("Run to completion".into()).unwrap();
    drop(submission);
    let snapshot = until(&c, |s| {
        s.operation.as_ref().is_some_and(|o| !o.state.active())
    })
    .await;
    assert_eq!(snapshot.operation.unwrap().state, OperationState::Completed);
    assert!(!c.busy());
}

#[tokio::test]
async fn stalled_observer_is_byte_bounded_and_does_not_block_execution() {
    let c = conversation(
        FakeProvider::new(vec![response(vec![
            ProviderEvent::Text("a".repeat(600_000)),
            ProviderEvent::Text("b".repeat(600_000)),
            ProviderEvent::Done,
        ])]),
        vec![],
    );
    let (_, mut stalled) = c.subscribe();
    assert_eq!(
        complete(c.submit("Stream".into()).unwrap()).await.state,
        OperationState::Completed
    );
    assert!(stalled.recv().await.is_err());
    let (snapshot, _) = c.subscribe();
    assert_eq!(snapshot.messages.last().unwrap().text().len(), 1_200_000);
    assert_eq!(snapshot.operation.unwrap().state, OperationState::Completed);

    let mut deltas = vec![ProviderEvent::Text("x".into()); 100];
    deltas.push(ProviderEvent::Done);
    let c = conversation(FakeProvider::new(vec![response(deltas)]), vec![]);
    let (_, mut observer) = c.subscribe();
    complete(c.submit("Small burst".into()).unwrap()).await;
    assert_eq!(
        event_kinds(&mut observer)
            .iter()
            .filter(|event| matches!(event, EventKind::Text { .. }))
            .count(),
        100
    );
}

#[tokio::test]
async fn queued_checkpoint_writes_preserve_poll_order() {
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let mut first = conversation(FakeProvider::new(vec![]), vec![]).record();
    first.model = "first".into();
    let mut last = first.clone();
    last.model = "last".into();
    let (a, b) = tokio::join!(store.save(first), store.save(last));
    a.unwrap();
    b.unwrap();
    assert_eq!(store.load().await.unwrap()[0].model, "last");
    store.close().await.unwrap();
}
