#![allow(dead_code)]
use async_trait::async_trait;
use exec_agent::{Error, Result, core::*};
use futures_util::{
    future::BoxFuture,
    stream::{self, BoxStream},
};
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio_util::sync::CancellationToken;
pub type Script =
    Box<dyn FnOnce(ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> + Send>;
#[derive(Default)]
pub struct FakeProvider {
    pub requests: Mutex<Vec<ProviderRequest>>,
    scripts: Mutex<VecDeque<Script>>,
}
impl FakeProvider {
    pub fn new(scripts: Vec<Script>) -> Arc<Self> {
        Arc::new(Self {
            requests: Mutex::new(vec![]),
            scripts: Mutex::new(scripts.into()),
        })
    }
    pub fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}
#[async_trait]
impl ChatProvider for FakeProvider {
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        self.requests.lock().unwrap().push(request.clone());
        self.scripts
            .lock()
            .unwrap()
            .pop_front()
            .expect("Unexpected inference (possible retry)")(request)
    }
}
pub fn response(events: Vec<ProviderEvent>) -> Script {
    Box::new(move |_| Box::pin(stream::iter(events.into_iter().map(Ok))))
}
pub fn answer() -> Script {
    response(vec![
        ProviderEvent::Text("Completed answer".into()),
        ProviderEvent::Done,
    ])
}
pub fn call(id: &str) -> ProviderEvent {
    ProviderEvent::ToolCall(ToolCall {
        id: id.into(),
        name: "change".into(),
        arguments: serde_json::json!({"value":"exact action"})
            .as_object()
            .unwrap()
            .clone(),
    })
}
pub fn script(
    f: impl FnOnce(ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> + Send + 'static,
) -> Script {
    Box::new(f)
}
pub fn waiting(entered: CancellationToken) -> Script {
    script(move |r| {
        Box::pin(
            async_stream::try_stream! {entered.cancel();r.cancel.cancelled().await;Err(Error::Cancelled)?;yield ProviderEvent::Done;},
        )
    })
}
pub type Executor = Arc<dyn Fn(ToolContext) -> BoxFuture<'static, Result<String>> + Send + Sync>;
pub struct TestTool {
    pub approval: Option<String>,
    pub executor: Executor,
    pub fail_preparation: bool,
}
struct Prepared {
    approval: Option<String>,
    executor: Executor,
    context: ToolContext,
}
#[async_trait]
impl PreparedTool for Prepared {
    fn approval(&self) -> Option<&str> {
        self.approval.as_deref()
    }
    async fn execute(self: Box<Self>) -> Result<String> {
        (self.executor)(self.context).await
    }
}
#[async_trait]
impl Tool for TestTool {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: "change".into(),
            description: "Test effect".into(),
            parameters: serde_json::json!({"type":"object"})
                .as_object()
                .unwrap()
                .clone(),
        }
    }
    async fn prepare(&self, _: Arguments, context: ToolContext) -> Result<Box<dyn PreparedTool>> {
        if self.fail_preparation {
            return Err(Error::Internal);
        }
        Ok(Box::new(Prepared {
            approval: self.approval.clone(),
            executor: self.executor.clone(),
            context,
        }))
    }
}
pub fn tool<F, Fut>(approval: Option<&str>, execute: F) -> Arc<dyn Tool>
where
    F: Fn(ToolContext) -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = Result<String>> + Send + 'static,
{
    Arc::new(TestTool {
        approval: approval.map(str::to_owned),
        executor: Arc::new(move |c| Box::pin(execute(c))),
        fail_preparation: false,
    })
}
pub fn options(provider: Arc<dyn ChatProvider>, tools: Vec<Arc<dyn Tool>>) -> ConversationOptions {
    let mut options = ConversationOptions::new(provider, "fake", "/isolated-test-workspace");
    options.tools = tools;
    options.settings.auto_approve = false; // Approval tests explicitly opt into manual mode.
    options
}
pub fn conversation(
    provider: Arc<dyn ChatProvider>,
    tools: Vec<Arc<dyn Tool>>,
) -> Arc<Conversation> {
    Conversation::new(options(provider, tools), None).unwrap()
}
pub async fn until(
    conversation: &Conversation,
    predicate: impl Fn(&ConversationSnapshot) -> bool,
) -> ConversationSnapshot {
    let (snapshot, mut events) = conversation.subscribe();
    if predicate(&snapshot) {
        return snapshot;
    }
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let _ = events.recv().await;
            let snapshot = conversation.snapshot();
            if predicate(&snapshot) {
                return snapshot;
            }
        }
    })
    .await
    .expect("State transition timed out")
}
pub async fn approval(c: &Conversation) -> Approval {
    until(c, |s| s.approval.is_some()).await.approval.unwrap()
}
pub async fn complete(run: Submission) -> Operation {
    tokio::time::timeout(Duration::from_secs(8), run.completion)
        .await
        .expect("Run timed out")
        .unwrap()
}
pub fn outcomes(c: &Conversation) -> Vec<ToolOutcome> {
    c.snapshot()
        .messages
        .iter()
        .filter_map(|m| {
            if let Message::Tool { outcome, .. } = m {
                Some(*outcome)
            } else {
                None
            }
        })
        .collect()
}
pub fn directory() -> tempfile::TempDir {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::Builder::new()
        .prefix("ear-")
        .tempdir_in("/tmp")
        .unwrap();
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}
pub struct SaveHook(
    pub Arc<dyn Fn(ConversationRecord) -> BoxFuture<'static, Result<()>> + Send + Sync>,
);
#[async_trait]
impl Checkpoint for SaveHook {
    async fn save(&self, r: ConversationRecord) -> Result<()> {
        (self.0)(r).await
    }
}
pub fn checkpoint<F, Fut>(f: F) -> Arc<dyn Checkpoint>
where
    F: Fn(ConversationRecord) -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = Result<()>> + Send + 'static,
{
    Arc::new(SaveHook(Arc::new(move |r| Box::pin(f(r)))))
}
pub async fn wait_file(path: &std::path::Path) -> String {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if let Ok(s) = tokio::fs::read_to_string(path).await {
                return s;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap()
}
pub fn event_kinds(receiver: &mut EventReceiver) -> Vec<EventKind> {
    let mut kinds = vec![];
    while let Ok(frame) = receiver.try_recv() {
        if let ServiceEvent::Runtime { event, .. } = frame.as_ref() {
            kinds.push(event.kind.clone());
        }
    }
    kinds
}
