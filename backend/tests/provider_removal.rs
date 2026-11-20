mod support;
use async_trait::async_trait;
use exec_agent::{
    Error, Result,
    core::*,
    manager::AgentManager,
    providers::ProviderRegistry,
    storage::{ConversationStore, JsonConversationStore},
};
use futures_util::stream::BoxStream;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use support::*;
use tokio_util::sync::CancellationToken;

struct Account {
    id: &'static str,
    inference: Arc<FakeProvider>,
    connected: AtomicBool,
    manageable: AtomicBool,
    compacting: CancellationToken,
    writes: AtomicUsize,
    entered: CancellationToken,
    release: CancellationToken,
    fail: AtomicBool,
}
impl Account {
    fn new(id: &'static str, scripts: Vec<Script>) -> Arc<Self> {
        Arc::new(Self {
            id,
            inference: FakeProvider::new(scripts),
            connected: AtomicBool::new(true),
            manageable: AtomicBool::new(true),
            compacting: CancellationToken::new(),
            writes: AtomicUsize::new(0),
            entered: CancellationToken::new(),
            release: CancellationToken::new(),
            fail: AtomicBool::new(false),
        })
    }
}
#[async_trait]
impl ChatProvider for Account {
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        self.inference.stream(request)
    }
    fn connections(&self) -> Vec<ProviderConnection> {
        vec![ProviderConnection {
            id: self.id.into(),
            name: self.id.into(),
            connected: self.connected.load(Ordering::SeqCst),
            email: None,
            source: "fake".into(),
            manageable: self.manageable.load(Ordering::SeqCst),
            blocked: false,
        }]
    }
    fn supports_web_search(&self) -> bool {
        true
    }
    fn supports_compaction(&self, _: &str) -> bool {
        true
    }
    async fn compact(&self, request: ProviderRequest) -> Result<serde_json::Value> {
        self.compacting.cancel();
        request.cancel.cancelled().await;
        Err(Error::Cancelled)
    }
    async fn set_credential(&self, _: &str, _: Option<String>) -> Result<()> {
        self.writes.fetch_add(1, Ordering::SeqCst);
        self.entered.cancel();
        self.release.cancelled().await;
        if self.fail.load(Ordering::SeqCst) {
            return Err(Error::Storage);
        }
        self.connected.store(false, Ordering::SeqCst);
        Ok(())
    }
}
fn registry(a: Arc<Account>, b: Arc<Account>) -> Arc<ProviderRegistry> {
    Arc::new(ProviderRegistry::new("alpha", vec![("alpha".into(), a), ("beta".into(), b)]).unwrap())
}
async fn create(
    manager: &AgentManager,
    provider: Arc<dyn ChatProvider>,
    model: &str,
    workspace: &str,
    tools: Vec<Arc<dyn Tool>>,
) -> Arc<Conversation> {
    let mut o = ConversationOptions::new(provider, model, workspace);
    o.tools = tools;
    o.settings.auto_approve = false;
    manager.create(o).await.unwrap()
}
async fn signal(token: &CancellationToken) {
    tokio::time::timeout(std::time::Duration::from_secs(5), token.cancelled())
        .await
        .unwrap();
}

#[tokio::test]
async fn removal_is_confirmed_scoped_owned_and_preserves_durable_sessions() {
    let root = directory();
    let store = JsonConversationStore::open(root.path().join("conversations"))
        .await
        .unwrap();
    let started = CancellationToken::new();
    let cancelling = CancellationToken::new();
    let cleanup = CancellationToken::new();
    let (start, cancel, finish) = (started.clone(), cancelling.clone(), cleanup.clone());
    let a = Account::new(
        "alpha",
        vec![
            script(move |request| {
                Box::pin(async_stream::try_stream! {
                    yield ProviderEvent::Text("Keep partial output".into());
                    start.cancel(); request.cancel.cancelled().await; cancel.cancel();
                    finish.cancelled().await; Err(Error::Cancelled)?; yield ProviderEvent::Done;
                })
            }),
            response(vec![call("approval"), ProviderEvent::Done]),
        ],
    );
    let other_started = CancellationToken::new();
    let b = Account::new("beta", vec![waiting(other_started.clone()), answer()]);
    let provider = registry(a.clone(), b.clone());
    let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let workspace = root.path().to_str().unwrap();
    let stream = create(&manager, provider.clone(), "alpha/chat", workspace, vec![]).await;
    let approval = create(
        &manager,
        provider.clone(),
        "alpha/chat",
        workspace,
        vec![tool(Some("Confirm"), |_| async {
            panic!("Approval must never execute")
        })],
    )
    .await;
    let unrelated = create(&manager, provider.clone(), "beta/chat", workspace, vec![]).await;
    let first = stream.submit("Keep this message".into()).unwrap();
    signal(&started).await;
    let second = approval.submit("Wait for approval".into()).unwrap();
    support::approval(&approval).await;
    let third = unrelated.submit("Do not stop me".into()).unwrap();
    signal(&other_started).await;
    assert_eq!(
        manager
            .disconnect_provider(provider.clone(), "alpha", false)
            .await
            .unwrap_err(),
        Error::ProviderInUse
    );
    assert!(!cancelling.is_cancelled());
    assert_eq!(a.writes.load(Ordering::SeqCst), 0);
    assert!(approval.snapshot().approval.is_some());
    assert!(
        manager
            .disconnect_provider(provider.clone(), "missing", true)
            .await
            .is_err()
    );
    assert!(!cancelling.is_cancelled());

    a.manageable.store(false, Ordering::SeqCst);
    assert!(
        manager
            .disconnect_provider(provider.clone(), "alpha", true)
            .await
            .is_err()
    );
    assert!(!cancelling.is_cancelled());
    a.manageable.store(true, Ordering::SeqCst);

    let m = manager.clone();
    let p = provider.clone();
    let removal = tokio::spawn(async move { m.disconnect_provider(p, "alpha", true).await });
    signal(&cancelling).await;
    assert_eq!(
        a.writes.load(Ordering::SeqCst),
        0,
        "credentials must outlive cleanup"
    );
    assert_eq!(
        manager
            .disconnect_provider(provider.clone(), "alpha", true)
            .await
            .unwrap_err(),
        Error::Busy
    );
    assert!(matches!(
        manager.submit(&stream.id, "new".into()).await,
        Err(Error::Busy)
    ));
    assert!(matches!(
        stream.submit("retained handle".into()),
        Err(Error::Busy)
    ));
    assert!(unrelated.busy());
    assert!(matches!(
        provider
            .prepare_model("alpha/chat", CancellationToken::new())
            .await,
        Err(Error::Busy)
    ));
    removal.abort(); // Losing the caller cannot release the transaction reservation.
    cleanup.cancel();
    signal(&a.entered).await;
    assert!(matches!(
        stream.submit("still blocked".into()),
        Err(Error::Busy)
    ));
    assert!(matches!(
        provider
            .search_web("alpha/chat", "query".into(), CancellationToken::new())
            .await,
        Err(Error::Busy)
    ));
    a.release.cancel();
    assert_eq!(complete(first).await.state, OperationState::Interrupted);
    assert_eq!(complete(second).await.state, OperationState::Interrupted);
    until(&stream, |_| !stream.busy()).await;
    assert!(unrelated.busy());
    assert_eq!(b.writes.load(Ordering::SeqCst), 0);
    assert_eq!(a.writes.load(Ordering::SeqCst), 1);
    let records = store.load_catalog().await.unwrap().records;
    assert_eq!(records.len(), 3);
    let saved = records.iter().find(|r| r.id == stream.id).unwrap();
    assert_eq!(
        saved.operation.as_ref().unwrap().state,
        OperationState::Interrupted
    );
    assert!(saved.messages.iter().any(|m| matches!(m, Message::Assistant { text, status: MessageStatus::Interrupted, .. } if text == "Keep partial output")));
    assert!(approval.snapshot().approval.is_none());
    assert_eq!(a.inference.count(), 2);
    unrelated.cancel(&third.operation_id);
    complete(third).await;
    manager
        .select_model(&stream.id, "beta/chat".into())
        .await
        .unwrap();
    let resumed = stream
        .submit("Continue with another provider".into())
        .unwrap();
    assert_eq!(complete(resumed).await.state, OperationState::Completed);
    assert_eq!(b.inference.count(), 2);
    assert!(stream.snapshot().messages.len() > saved.messages.len());
    manager.close().await.unwrap();
}

#[tokio::test]
async fn idle_removal_needs_no_confirmation_and_failed_write_releases_reservations() {
    let a = Account::new("alpha", vec![]);
    a.release.cancel();
    a.fail.store(true, Ordering::SeqCst);
    let entered = CancellationToken::new();
    let b = Account::new("beta", vec![waiting(entered.clone())]);
    let provider = registry(a.clone(), b);
    let manager = Arc::new(AgentManager::default());
    let idle = create(&manager, provider.clone(), "alpha/chat", "/tmp", vec![]).await;
    let other = create(&manager, provider.clone(), "beta/chat", "/tmp", vec![]).await;
    let run = other.submit("unrelated".into()).unwrap();
    signal(&entered).await;
    assert_eq!(
        manager
            .disconnect_provider(provider.clone(), "alpha", false)
            .await
            .unwrap_err(),
        Error::Storage
    );
    assert!(!idle.busy());
    assert!(other.busy());
    assert!(a.connected.load(Ordering::SeqCst));
    // No retry is made after the failed write.
    assert_eq!(a.writes.load(Ordering::SeqCst), 1);
    manager
        .select_model(&idle.id, "beta/chat".into())
        .await
        .unwrap();
    other.cancel(&run.operation_id);
    complete(run).await;
    manager.close().await.unwrap();
}

#[tokio::test]
async fn registry_waits_for_inflight_requests_and_blocks_new_target_requests_only() {
    let started = CancellationToken::new();
    let cleanup = CancellationToken::new();
    let (start, finish) = (started.clone(), cleanup.clone());
    let a = Account::new(
        "alpha",
        vec![script(move |_| {
            Box::pin(async_stream::try_stream! {
                start.cancel(); finish.cancelled().await; yield ProviderEvent::Done;
            })
        })],
    );
    let b = Account::new("beta", vec![answer()]);
    let provider = registry(a.clone(), b);
    let c = conversation(provider.clone(), vec![]); // default/unqualified model routes to alpha
    let run = c.submit("request".into()).unwrap();
    signal(&started).await;
    let p = provider.clone();
    let change = tokio::spawn(async move { p.set_credential("alpha", None).await });
    // Wait until the writer has queued, without issuing inference or credential mutations.
    for _ in 0..100 {
        if matches!(
            provider
                .search_web("alpha/chat", "query".into(), CancellationToken::new())
                .await,
            Err(Error::Busy)
        ) {
            break;
        }
        tokio::task::yield_now().await;
    }
    assert_eq!(a.writes.load(Ordering::SeqCst), 0);
    let other = create(
        &AgentManager::default(),
        provider.clone(),
        "beta/chat",
        "/tmp",
        vec![],
    )
    .await;
    assert_eq!(
        complete(other.submit("works".into()).unwrap()).await.state,
        OperationState::Completed
    );
    cleanup.cancel();
    complete(run).await;
    signal(&a.entered).await;
    assert!(matches!(
        provider
            .prepare_model("alpha/chat", CancellationToken::new())
            .await,
        Err(Error::Busy)
    ));
    a.release.cancel();
    change.await.unwrap().unwrap();
}

#[tokio::test]
async fn http_removal_requires_explicit_consent_and_rejects_malformed_consent() {
    use exec_agent::service::{ServiceOptions, start_service};
    let entered = CancellationToken::new();
    let a = Account::new("alpha", vec![waiting(entered.clone())]);
    a.release.cancel();
    let provider = registry(a.clone(), Account::new("beta", vec![]));
    let manager = Arc::new(AgentManager::default());
    let c = create(&manager, provider.clone(), "alpha/chat", "/tmp", vec![]).await;
    let run = c.submit("keep history".into()).unwrap();
    signal(&entered).await;
    let service = start_service(ServiceOptions {
        manager: manager.clone(),
        provider,
        tools: vec![],
        address: "127.0.0.1:0".parse().unwrap(),
        access: http_access(),
    })
    .await
    .unwrap();
    let url = format!("http://{}/v1/providers/alpha", service.address);
    let client = reqwest::Client::builder()
        .no_proxy()
        .retry(reqwest::retry::never())
        .build()
        .unwrap();
    let response = client
        .delete(&url)
        .bearer_auth(API_TOKEN)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 409);
    let rejection: serde_json::Value = response.json().await.unwrap();
    assert_eq!(rejection["code"], "provider_in_use");
    assert_eq!(rejection["delivery"], "rejected");
    for body in [
        serde_json::json!({"stopRunning":"yes"}),
        serde_json::json!({"force":true}),
    ] {
        assert_eq!(
            client
                .delete(&url)
                .bearer_auth(API_TOKEN)
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    assert_eq!(
        client
            .delete(&url)
            .json(&serde_json::json!({"stopRunning":true}))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(a.writes.load(Ordering::SeqCst), 0);
    assert!(c.busy());
    assert_eq!(
        client
            .delete(&url)
            .bearer_auth(API_TOKEN)
            .json(&serde_json::json!({"stopRunning":true}))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert!(manager.get(&c.id).is_ok());
    assert_eq!(a.writes.load(Ordering::SeqCst), 1);
    service.close().await.unwrap();
}

#[tokio::test]
async fn removal_cancels_wait_tools_without_resuming_inference() {
    let a = Account::new("alpha", vec![response(vec![ProviderEvent::ToolCall(ToolCall {
        id: "wait-call".into(), name: "wait".into(), arguments: serde_json::json!({"duration_seconds":3600,"description":"Waiting","wake_prompt":"Continue only after waiting"}).as_object().unwrap().clone(),
    }), ProviderEvent::Done])]);
    a.release.cancel();
    let provider = registry(a.clone(), Account::new("beta", vec![]));
    let manager = Arc::new(AgentManager::default());
    let c = create(
        &manager,
        provider.clone(),
        "alpha/chat",
        "/tmp",
        vec![exec_agent::tools::create_wait_tool()],
    )
    .await;
    // Wait is a safe, approval-free tool.
    let run = c.submit("wait".into()).unwrap();
    until(&c, |s| s.active_tool_name.as_deref() == Some("wait")).await;
    manager
        .disconnect_provider(provider, "alpha", true)
        .await
        .unwrap();
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(outcomes(&c), vec![ToolOutcome::Interrupted]);
    assert_eq!(a.inference.count(), 1);
    assert!(!c.snapshot().messages.is_empty());
    manager.close().await.unwrap();
}

#[tokio::test]
async fn removal_settles_delegation_and_preserves_parent_and_child_records() {
    let workspace = directory();
    let entered = CancellationToken::new();
    let a = Account::new(
        "alpha",
        vec![
            response(vec![
                ProviderEvent::ToolCall(ToolCall {
                    id: "delegate-call".into(),
                    name: "delegate".into(),
                    arguments:
                        serde_json::json!({"task":"Wait for cancellation", "title":"Child task"})
                            .as_object()
                            .unwrap()
                            .clone(),
                }),
                ProviderEvent::Done,
            ]),
            waiting(entered.clone()),
        ],
    );
    a.release.cancel();
    let provider = registry(a.clone(), Account::new("beta", vec![]));
    let manager = Arc::new(AgentManager::default());
    let parent = manager
        .create_session(
            provider.clone(),
            vec![],
            Some("alpha/chat".into()),
            workspace.path().to_str().unwrap().into(),
            None,
            None,
        )
        .await
        .unwrap();
    let run = parent.submit("delegate".into()).unwrap();
    signal(&entered).await;
    let child = manager
        .list()
        .unwrap()
        .into_iter()
        .find(|s| s.metadata.parent.is_some())
        .unwrap()
        .id;
    manager
        .disconnect_provider(provider, "alpha", true)
        .await
        .unwrap();
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(
        manager
            .get(&child)
            .unwrap()
            .snapshot()
            .operation
            .unwrap()
            .state,
        OperationState::Interrupted
    );
    assert_eq!(manager.list().unwrap().len(), 2);
    assert_eq!(a.inference.count(), 2);
    assert!(!parent.snapshot().messages.is_empty());
    manager.close().await.unwrap();
}

#[tokio::test]
async fn removal_cancels_compaction_and_configured_cross_provider_search_sessions() {
    let a = Account::new("alpha", vec![answer()]);
    a.release.cancel();
    let entered = CancellationToken::new();
    let b = Account::new("beta", vec![waiting(entered.clone())]);
    let provider = registry(a.clone(), b);
    let manager = Arc::new(AgentManager::default());
    let c = create(&manager, provider.clone(), "alpha/chat", "/tmp", vec![]).await;
    complete(c.submit("seed".into()).unwrap()).await;
    let compacting = manager.compact(&c.id).unwrap();
    signal(&a.compacting).await;
    let mut options = ConversationOptions::new(provider.clone(), "beta/chat", "/tmp");
    options.settings.search_model = Some("alpha/search".into());
    options.tools = exec_agent::tools::create_provider_tools(provider.clone());
    let search = manager.create(options).await.unwrap();
    let run = search.submit("search-capable session".into()).unwrap();
    signal(&entered).await;
    manager
        .disconnect_provider(provider, "alpha", true)
        .await
        .unwrap();
    assert_eq!(
        complete(compacting).await.state,
        OperationState::Interrupted
    );
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(a.inference.count(), 1);
    assert!(!c.snapshot().messages.is_empty());
    manager.close().await.unwrap();
}

#[tokio::test]
async fn failed_final_checkpoint_prevents_credential_deletion_without_replaying_work() {
    let entered = CancellationToken::new();
    let a = Account::new("alpha", vec![waiting(entered.clone())]);
    a.release.cancel();
    let provider = registry(a.clone(), Account::new("beta", vec![]));
    let manager = Arc::new(AgentManager::default());
    let mut options = ConversationOptions::new(provider.clone(), "alpha/chat", "/tmp");
    options.checkpoint = Some(checkpoint(|record| async move {
        if record.operation.is_some_and(|op| !op.state.active()) {
            Err(Error::Storage)
        } else {
            Ok(())
        }
    }));
    let c = manager.create(options).await.unwrap();
    let run = c.submit("preserve this session".into()).unwrap();
    signal(&entered).await;
    assert_eq!(
        manager
            .disconnect_provider(provider, "alpha", true)
            .await
            .unwrap_err(),
        Error::Storage
    );
    assert_eq!(complete(run).await.state, OperationState::Failed);
    assert!(c.snapshot().storage_error.is_some());
    assert!(manager.get(&c.id).is_ok());
    assert_eq!(a.writes.load(Ordering::SeqCst), 0);
    assert!(a.connected.load(Ordering::SeqCst));
    assert_eq!(a.inference.count(), 1);
    manager.close().await.unwrap();
}
