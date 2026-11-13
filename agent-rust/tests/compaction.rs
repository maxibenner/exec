use support::client::AgentClient;
mod support;
use async_trait::async_trait;
use exec_agent::{Error, Result, core::*};
use futures_util::stream::{self, BoxStream};
use serde_json::{Value, json};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use tokio_util::sync::CancellationToken;
#[derive(Default)]
struct Provider {
    requests: Mutex<Vec<ProviderRequest>>,
    compactions: Mutex<Vec<ProviderRequest>>,
    hold: AtomicBool,
    fail: AtomicBool,
    entered: CancellationToken,
}
#[async_trait]
impl ChatProvider for Provider {
    fn supports_compaction(&self, _: &str) -> bool {
        true
    }
    fn context_window(&self, _: &str) -> Option<u64> {
        Some(100)
    }
    fn stream(&self, r: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        self.requests.lock().unwrap().push(r.clone());
        Box::pin(stream::iter([
            Ok(ProviderEvent::Text("answer".into())),
            Ok(ProviderEvent::Metadata {
                state: r.provider_state.or(Some(json!({"original":true}))),
                usage: Some(TokenUsage {
                    input_tokens: Some(90),
                    output_tokens: Some(6),
                    total_tokens: Some(96),
                }),
            }),
            Ok(ProviderEvent::Done),
        ]))
    }
    async fn compact(&self, r: ProviderRequest) -> Result<Value> {
        self.compactions.lock().unwrap().push(r.clone());
        self.entered.cancel();
        if self.hold.load(Ordering::SeqCst) {
            r.cancel.cancelled().await;
            return Err(Error::Cancelled);
        }
        if self.fail.load(Ordering::SeqCst) {
            return Err(Error::Internal);
        }
        Ok(json!({"compacted":r.message_ids.last()}))
    }
}
#[tokio::test]
async fn automatic_compaction_uses_completed_prefix_keeps_new_input_and_visible_history() {
    let p = Arc::new(Provider::default());
    let c = support::conversation(p.clone(), vec![]);
    support::complete(c.submit("first".into()).unwrap()).await;
    let original = c.snapshot().messages;
    assert_eq!(c.snapshot().context_usage.unwrap().tokens, 96);
    support::complete(c.submit("second".into()).unwrap()).await;
    let compactions = p.compactions.lock().unwrap();
    assert_eq!(compactions.len(), 1);
    assert_eq!(compactions[0].messages, context(&original));
    assert_eq!(
        compactions[0].message_ids,
        original
            .iter()
            .map(|m| m.id().to_owned())
            .collect::<Vec<_>>()
    );
    assert_eq!(&c.snapshot().messages[..original.len()], &original);
    assert!(
        matches!(p.requests.lock().unwrap()[1].messages.last(),Some(ContextMessage::User{text}) if text=="second")
    );
    assert!(
        p.requests.lock().unwrap()[1]
            .provider_state
            .as_ref()
            .unwrap()
            .get("compacted")
            .is_some()
    );
}
#[tokio::test]
async fn manual_compaction_is_exclusive_cancellable_and_keeps_original_on_failure() {
    let p = Arc::new(Provider::default());
    let c = support::conversation(p.clone(), vec![]);
    support::complete(c.submit("first".into()).unwrap()).await;
    let original = c.record().provider_state;
    let history = c.snapshot().messages;
    p.hold.store(true, Ordering::SeqCst);
    let run = c.compact().unwrap();
    p.entered.cancelled().await;
    assert!(c.submit("overlap".into()).is_err());
    assert!(
        c.steer(
            &run.operation_id,
            "cannot steer a maintenance operation".into()
        )
        .is_err()
    );
    assert!(c.cancel(&run.operation_id));
    assert_eq!(
        support::complete(run).await.state,
        OperationState::Interrupted
    );
    assert_eq!(c.record().provider_state, original);
    assert_eq!(c.snapshot().messages, history);
    p.hold.store(false, Ordering::SeqCst);
    p.fail.store(true, Ordering::SeqCst);
    assert_eq!(
        support::complete(c.compact().unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(c.record().provider_state, original);
    assert_eq!(p.requests.lock().unwrap().len(), 1);
}
#[tokio::test]
async fn compaction_checkpoint_failure_blocks_inference_and_success_publication() {
    let p = Arc::new(Provider::default());
    let fail = Arc::new(AtomicBool::new(false));
    let f = fail.clone();
    let mut options = support::options(p.clone(), vec![]);
    options.checkpoint = Some(support::checkpoint(move |r| {
        let fail = f.clone();
        async move {
            if fail.load(Ordering::SeqCst)
                && r.provider_state
                    .as_ref()
                    .is_some_and(|s| s.get("compacted").is_some())
            {
                Err(Error::Storage)
            } else {
                Ok(())
            }
        }
    }));
    let c = Conversation::new(options, None).unwrap();
    support::complete(c.submit("first".into()).unwrap()).await;
    fail.store(true, Ordering::SeqCst);
    assert_eq!(
        support::complete(c.submit("second".into()).unwrap())
            .await
            .state,
        OperationState::Failed
    );
    assert_eq!(p.requests.lock().unwrap().len(), 1);
    assert!(c.snapshot().storage_error.is_some());
    assert!(c.submit("unsafe".into()).is_err());
}
#[tokio::test]
async fn accepted_steering_is_checkpointed_while_automatic_compaction_waits() {
    let p = Arc::new(Provider::default());
    let saved = Arc::new(Mutex::new(Vec::new()));
    let capture = saved.clone();
    let mut options = support::options(p.clone(), vec![]);
    options.checkpoint = Some(support::checkpoint(move |record| {
        let capture = capture.clone();
        async move {
            capture.lock().unwrap().push(record);
            Ok(())
        }
    }));
    let c = Conversation::new(options, None).unwrap();
    support::complete(c.submit("first".into()).unwrap()).await;
    p.hold.store(true, Ordering::SeqCst);
    let run = c.submit("second".into()).unwrap();
    p.entered.cancelled().await;
    let id = c.steer(&run.operation_id, "adjust".into()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            if saved
                .lock()
                .unwrap()
                .iter()
                .any(|r| r.pending_input.iter().any(|m| m.id() == id))
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(c.cancel(&run.operation_id));
    assert_eq!(
        support::complete(run).await.state,
        OperationState::Interrupted
    );
    assert_eq!(p.requests.lock().unwrap().len(), 1);
    assert_eq!(c.snapshot().pending_input[0].id(), id);
}
#[tokio::test]
async fn manual_compaction_api_receipt_and_opaque_checkpoint_survive_restart() {
    use exec_agent::service::*;
    use futures_util::StreamExt;
    let root = support::directory();
    let workspace = support::directory();
    let p = Arc::new(Provider::default());
    let service = start_persistent_service(
        root.path(),
        p.clone(),
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let c = client
        .create("model", workspace.path().to_str().unwrap())
        .await
        .unwrap();
    client.submit(&c.id, "first").await.unwrap();
    let wait = |operation: Option<String>| {
        let client = client.clone();
        let id = c.id.clone();
        async move {
            let mut events = client.events(&id, CancellationToken::new());
            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                while let Some(frame) = events.next().await {
                    let snapshot = match frame.unwrap() {
                        ServiceEvent::Snapshot { snapshot }
                        | ServiceEvent::Runtime {
                            snapshot: Some(snapshot),
                            ..
                        } => snapshot,
                        _ => continue,
                    };
                    if snapshot.operation.as_ref().is_some_and(|o| {
                        !o.state.active() && operation.as_ref().is_none_or(|id| o.id == *id)
                    }) {
                        return snapshot;
                    }
                }
                panic!("missing operation settlement")
            })
            .await
            .unwrap()
        }
    };
    let history = wait(None).await.messages;
    let operation = client.compact(&c.id).await.unwrap();
    let compacted = wait(Some(operation.clone())).await;
    assert_eq!(
        compacted.operation.unwrap().state,
        OperationState::Completed
    );
    assert_eq!(compacted.messages, history);
    assert!(compacted.context_usage.is_none());
    service.close().await.unwrap();
    let service = start_persistent_service(
        root.path(),
        p,
        false,
        "127.0.0.1:0".parse().unwrap(),
        support::http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let snapshot = client.get(&c.id).await.unwrap();
    assert_eq!(snapshot.operation.unwrap().id, operation);
    assert_eq!(snapshot.messages, history);
    let disk: serde_json::Value = serde_json::from_slice(
        &std::fs::read(
            root.path()
                .join("conversations")
                .join(format!("{}.json", c.id)),
        )
        .unwrap(),
    )
    .unwrap();
    assert!(disk["providerState"].get("compacted").is_some());
    service.close().await.unwrap();
}
