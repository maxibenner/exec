#[path = "support/gated_store.rs"]
#[allow(dead_code)] // Shared write counters; this read-only suite does not use its gates.
mod gated_store;
mod support;

use async_trait::async_trait;
use exec_agent::{
    Error, Result,
    core::*,
    images::ImageStore,
    manager::AgentManager,
    native::{DesktopPermission, NativeEvent},
    providers::ProviderRegistry,
    service::{Service, ServiceOptions, start_service},
    storage::JsonConversationStore,
    tools::{create_image_tools, create_provider_tools, create_screenshot_tool},
};
use futures_util::{StreamExt, stream::BoxStream};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use support::{FakeProvider, client::AgentClient};
use tokio_util::sync::CancellationToken;

const ROUTE: &str = "/v1/tools/availability";
const NAMES: &[&str] = &[
    "delegate",
    "generate_image",
    "take_screenshot",
    "web_search",
    "Missing-tool_9",
];

struct LocalProvider {
    id: &'static str,
    search: bool,
    images: bool,
    connected: AtomicBool,
    inference: Arc<FakeProvider>,
}
impl LocalProvider {
    fn new(
        id: &'static str,
        search: bool,
        images: bool,
        scripts: Vec<support::Script>,
    ) -> Arc<Self> {
        Arc::new(Self {
            id,
            search,
            images,
            connected: AtomicBool::new(true),
            inference: FakeProvider::new(scripts),
        })
    }
}
#[async_trait]
impl ChatProvider for LocalProvider {
    fn supports_web_search(&self) -> bool {
        self.search
    }
    fn supports_image_generation(&self) -> bool {
        self.images
    }
    fn connections(&self) -> Vec<ProviderConnection> {
        vec![ProviderConnection {
            id: self.id.into(),
            name: "Local fake".into(),
            connected: self.connected.load(Ordering::SeqCst),
            email: None,
            source: "fake".into(),
            manageable: false,
            blocked: false,
        }]
    }
    fn stream(&self, request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        self.inference.stream(request)
    }
    async fn models(&self, _: CancellationToken) -> Result<Vec<ChatModel>> {
        panic!("Availability must not discover models")
    }
    async fn accepts_images(&self, _: &str, _: CancellationToken) -> Result<bool> {
        panic!("Availability must not probe chat vision")
    }
    async fn search_web(
        &self,
        _: &str,
        _: String,
        _: CancellationToken,
    ) -> Result<WebSearchResult> {
        panic!("Availability must not perform search")
    }
    async fn generate_image(
        &self,
        _: ImageGeneration,
        _: CancellationToken,
    ) -> Result<GeneratedImage> {
        panic!("Availability must not generate images")
    }
}

struct Fixture {
    _profile: tempfile::TempDir,
    workspace: tempfile::TempDir,
    store: Arc<gated_store::GatedStore>,
    manager: Arc<AgentManager>,
    provider: Arc<ProviderRegistry>,
    chat: Arc<LocalProvider>,
    search: Arc<LocalProvider>,
    images: Arc<LocalProvider>,
    tools: Vec<Arc<dyn Tool>>,
    service: Service,
    client: AgentClient,
}
impl Fixture {
    async fn new(scripts: Vec<support::Script>) -> Self {
        let profile = support::directory();
        let workspace = support::directory();
        let chat = LocalProvider::new("chat", false, false, scripts);
        let search = LocalProvider::new("search", true, false, vec![]);
        let images = LocalProvider::new("images", false, true, vec![]);
        let provider = Arc::new(
            ProviderRegistry::new(
                "chat",
                vec![
                    ("chat".into(), chat.clone()),
                    ("search".into(), search.clone()),
                    ("images".into(), images.clone()),
                ],
            )
            .unwrap(),
        );
        let store = gated_store::GatedStore::new(
            JsonConversationStore::open(profile.path().join("conversations"))
                .await
                .unwrap(),
        );
        let manager = AgentManager::open(store.clone(), |_| (provider.clone(), vec![]))
            .await
            .unwrap();
        let image_store = ImageStore::open(profile.path().join("images"))
            .await
            .unwrap();
        let mut tools = create_provider_tools(provider.clone());
        tools.extend(create_image_tools(provider.clone(), image_store.clone()));
        tools.push(create_screenshot_tool(manager.native(), image_store));
        let mut library = manager.library_configuration().unwrap();
        library.automatic_titles = false;
        manager.update_library(library).await.unwrap();
        let service = start_service(ServiceOptions {
            manager: manager.clone(),
            provider: provider.clone(),
            tools: tools.clone(),
            address: "127.0.0.1:0".parse().unwrap(),
            access: support::http_access(),
        })
        .await
        .unwrap();
        let client = AgentClient::new(service.address).unwrap();
        Self {
            _profile: profile,
            workspace,
            store,
            manager,
            provider,
            chat,
            search,
            images,
            tools,
            service,
            client,
        }
    }
    async fn create(&self) -> ConversationSnapshot {
        self.client
            .create("chat/main", self.workspace.path().to_str().unwrap())
            .await
            .unwrap()
    }
    async fn availability(&self, id: Option<&str>, model: &str, search: Option<&str>) -> Value {
        let mut body = json!({"names":NAMES,"model":model,"searchModel":search});
        if let Some(id) = id {
            body["conversationID"] = json!(id);
        }
        self.client.call("POST", ROUTE, Some(body)).await.unwrap()
    }
    // Whole records include settings, transcript, metadata and availability history.
    // Write counters also catch a read that saves an identical record or library.
    fn read_state(&self) -> Value {
        let records: Vec<_> = self
            .manager
            .list()
            .unwrap()
            .iter()
            .map(|s| self.manager.get(&s.id).unwrap().record())
            .collect();
        json!({
            "records":records,
            "library":self.manager.library_configuration().unwrap(),
            "recordWrites":self.store.record_attempts.load(Ordering::SeqCst),
            "libraryWrites":self.store.library_attempts.load(Ordering::SeqCst),
            "inference":[self.chat.inference.count(),self.search.inference.count(),self.images.inference.count()],
            "changes":self.manager.subscribe_changes().borrow().clone(),
        })
    }
}
fn available() -> Value {
    json!({"available":true})
}
fn unavailable(reason: &str) -> Value {
    json!({"available":false,"reason":reason})
}

#[tokio::test]
async fn reads_ignore_selection_do_not_mutate_and_match_the_next_request_catalog() {
    let entered = CancellationToken::new();
    let f = Fixture::new(vec![
        support::answer(),
        support::answer(),
        support::answer(),
        support::waiting(entered.clone()),
    ])
    .await;
    let snapshot = f.create().await;
    let c = f.manager.get(&snapshot.id).unwrap();
    let mut settings = snapshot.configuration.settings;
    settings.auto_approve = false;
    settings.search_model = Some("search/selected".into());
    f.client.update_settings(&c.id, settings).await.unwrap();
    let mut library = f.client.library().await.unwrap();
    library.default_disabled_tools = vec!["delegate".into(), "generate_image".into()];
    f.client.update_library(library).await.unwrap();

    for (disabled, connected) in [
        (vec!["delegate", "generate_image"], true),
        (vec![], true),
        (vec![], false),
    ] {
        f.client
            .call(
                "PATCH",
                &format!("/v1/conversations/{}", c.id),
                Some(json!({"disabledTools":disabled})),
            )
            .await
            .unwrap();
        f.images.connected.store(connected, Ordering::SeqCst);
        f.search.connected.store(connected, Ordering::SeqCst);
        let before = f.read_state();
        let status = f
            .availability(Some(&c.id), "chat/main", Some("search/selected"))
            .await;
        let defaults = f
            .availability(None, "chat/main", Some("search/selected"))
            .await;
        assert_eq!(status["delegate"], available());
        assert_eq!(defaults["delegate"], available());
        assert_eq!(status["generate_image"], defaults["generate_image"]);
        assert_eq!(status["web_search"], defaults["web_search"]);
        assert_eq!(status["generate_image"]["available"], connected);
        assert_eq!(status["web_search"]["available"], connected);
        assert_eq!(
            status["Missing-tool_9"],
            unavailable("Not provided by this backend.")
        );
        // A preview uses its supplied model/search route, not saved session settings.
        let preview = f.availability(Some(&c.id), "", None).await;
        assert_eq!(preview["web_search"], unavailable("Select a model."));
        assert_eq!(preview["generate_image"], status["generate_image"]);
        assert_eq!(f.read_state(), before);

        assert_eq!(
            support::complete(c.submit("Continue locally".into()).unwrap())
                .await
                .state,
            OperationState::Completed
        );
        let expected: Vec<_> = NAMES
            .iter()
            .copied()
            .filter(|name| status[*name]["available"] == true && !disabled.contains(name))
            .collect();
        let requests = f.chat.inference.requests.lock().unwrap();
        let request = requests.last().unwrap();
        assert_eq!(
            request
                .tools
                .iter()
                .map(|t| t.name.as_str())
                .collect::<Vec<_>>(),
            expected
        );
        assert!(
            matches!(request.messages.last(), Some(ContextMessage::ToolAvailability { enabled }) if enabled == &expected)
        );
    }
    // Capability reads remain available while a turn owns the session.
    let run = c.submit("Hold locally".into()).unwrap();
    tokio::time::timeout(Duration::from_secs(5), entered.cancelled())
        .await
        .unwrap();
    let before = f.read_state();
    assert_eq!(
        f.availability(Some(&c.id), "chat/main", None).await["delegate"],
        available()
    );
    assert_eq!(f.read_state(), before);
    c.cancel(&run.operation_id);
    assert_eq!(
        support::complete(run).await.state,
        OperationState::Interrupted
    );
    assert_eq!(f.chat.inference.count(), 4);
    assert_eq!(f.search.inference.count(), 0);
    assert_eq!(f.images.inference.count(), 0);
    c.record().validate().unwrap();

    // Even with a service-wide executor, an individual session may not own it.
    let bare = f
        .manager
        .create(support::options(f.provider.clone(), vec![]))
        .await
        .unwrap();
    f.images.connected.store(true, Ordering::SeqCst);
    let before = f.read_state();
    let status = f.availability(Some(&bare.id), "chat/main", None).await;
    assert_eq!(
        status["generate_image"],
        unavailable("Not provided by this backend.")
    );
    assert_eq!(
        status["delegate"],
        unavailable("Not provided by this backend.")
    );
    assert_eq!(
        f.availability(None, "chat/main", None).await["generate_image"],
        available()
    );
    assert_eq!(f.read_state(), before);
    f.service.close().await.unwrap();
}

#[tokio::test]
async fn provider_status_uses_the_selected_local_route_and_independent_image_connection() {
    let f = Fixture::new(vec![]).await;
    let c = f.create().await;
    let before = f.read_state();
    for (model, search, connected, reason) in [
        (
            "chat/main",
            None,
            true,
            Some("Search is not supported by the selected provider."),
        ),
        ("chat/main", Some("search/other"), true, None),
        ("search/main", None, true, None),
        ("", Some("search/other"), true, None),
        (
            "search/main",
            Some("chat/other"),
            true,
            Some("Search is not supported by the selected provider."),
        ),
        (
            "chat/main",
            Some("unknown/model"),
            true,
            Some("Search is not supported by the selected provider."),
        ),
        (
            "chat/main",
            Some("search/other"),
            false,
            Some("Connect the selected search provider."),
        ),
        (
            "search/main",
            None,
            false,
            Some("Connect the selected search provider."),
        ),
        ("", None, true, Some("Select a model.")),
    ] {
        f.search.connected.store(connected, Ordering::SeqCst);
        for id in [None, Some(c.id.as_str())] {
            let status = f.availability(id, model, search).await;
            assert_eq!(
                status["web_search"],
                reason.map_or_else(available, unavailable),
                "{model} / {search:?}"
            );
            assert_eq!(status["generate_image"], available());
        }
    }
    // The selected chat provider is text-only and can itself be disconnected.
    f.chat.connected.store(false, Ordering::SeqCst);
    for connected in [false, true] {
        f.images.connected.store(connected, Ordering::SeqCst);
        let expected = if connected {
            available()
        } else {
            unavailable("Connect an image provider.")
        };
        for id in [None, Some(c.id.as_str())] {
            assert_eq!(
                f.availability(id, "chat/main", Some("search/other")).await["generate_image"],
                expected
            );
        }
    }
    assert_eq!(f.read_state(), before);
    f.service.close().await.unwrap();
}

#[tokio::test]
async fn availability_rejects_invalid_unbounded_and_unauthorized_requests() {
    let f = Fixture::new(vec![]).await;
    let before = f.read_state();
    for body in [
        json!({}),
        json!({"model":""}),
        json!({"names":[]}),
        json!({"model":null,"names":[]}),
        json!({"model":"","names":null}),
        json!({"model":"","names":[1]}),
        json!({"model":"","names":[],"extra":true}),
        json!({"model":"","names":[],"conversationID":null}),
        json!({"model":"","names":[],"conversationID":""}),
        json!({"model":"","names":[],"conversationID":"../bad"}),
        json!({"model":"","names":[],"searchModel":42}),
        json!({"model":"","names":[],"searchModel":""}),
        json!({"model":"bad\nmodel","names":[]}),
        json!({"model":"   ","names":[]}),
        json!({"model":"x".repeat(129),"names":[]}),
        json!({"model":"😀".repeat(65),"names":[]}),
        json!({"model":"","names":[],"searchModel":"bad\0model"}),
        json!({"model":"","names":[],"searchModel":"x".repeat(129)}),
        json!({"model":"","names":[""]}),
        json!({"model":"","names":["web_search","web_search"]}),
        json!({"model":"","names":["bad name"]}),
        json!({"model":"","names":["bad/name"]}),
        json!({"model":"","names":["bad.name"]}),
        json!({"model":"","names":["é"]}),
        json!({"model":"","names":["x".repeat(129)]}),
        json!({"model":"","names":(0..129).map(|n| format!("tool_{n}")).collect::<Vec<_>>()}),
    ] {
        assert_eq!(
            f.client
                .call("POST", ROUTE, Some(body.clone()))
                .await
                .unwrap_err(),
            Error::Api(400),
            "{body}"
        );
    }
    assert_eq!(
        f.client
            .call(
                "POST",
                ROUTE,
                Some(json!({"model":"","names":[],"conversationID":new_id()}))
            )
            .await
            .unwrap_err(),
        Error::Api(404)
    );
    for body in [
        json!({"model":"","names":[],"searchModel":null}),
        json!({"model":"chat/model:1.2","names":[]}),
    ] {
        assert_eq!(
            f.client.call("POST", ROUTE, Some(body)).await.unwrap(),
            json!({})
        );
    }
    let names: Vec<_> = (0..127)
        .map(|n| format!("tool_{n}"))
        .chain(["x".repeat(128)])
        .collect();
    let statuses = f
        .client
        .call("POST", ROUTE, Some(json!({"model":"","names":names})))
        .await
        .unwrap();
    assert_eq!(statuses.as_object().unwrap().len(), 128);
    assert!(
        statuses
            .as_object()
            .unwrap()
            .values()
            .all(|s| *s == unavailable("Not provided by this backend."))
    );
    let status = f
        .client
        .call(
            "POST",
            ROUTE,
            Some(json!({
                "model":"chat/模型:1.2", "names":["0","_","-","Upper_CASE-9"]
            })),
        )
        .await
        .unwrap();
    assert_eq!(status.as_object().unwrap().len(), 4);
    assert!(
        status
            .as_object()
            .unwrap()
            .values()
            .all(|s| *s == unavailable("Not provided by this backend."))
    );

    let http = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();
    for (token, body, expected) in [
        (None, "{", 401),
        (Some("invalid-synthetic-token"), "{", 401),
        (Some(support::API_TOKEN), "{", 400),
    ] {
        let mut request = http
            .post(format!("http://{}{ROUTE}", f.service.address))
            .header("Content-Type", "application/json")
            .body(body);
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        let response = request.send().await.unwrap();
        assert_eq!(response.status().as_u16(), expected);
        assert!(response.bytes().await.unwrap().len() < 512);
    }
    assert_eq!(f.read_state(), before);
    f.service.close().await.unwrap();
}

async fn register(client: &AgentClient) -> (String, BoxStream<'static, Result<NativeEvent>>) {
    let mut events = client.native_events(false, CancellationToken::new());
    let event = tokio::time::timeout(Duration::from_secs(5), events.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let NativeEvent::Registered { frontend_id } = event else {
        panic!("Missing registration")
    };
    (frontend_id, events)
}

#[tokio::test]
async fn screenshot_reads_preserve_consent_and_binding_and_native_changes_invalidate_catalog() {
    let f = Fixture::new(vec![]).await;
    let c = f.create().await;
    let native = f.manager.native();
    let disconnected = unavailable("Capture frontend disconnected.");
    let unbound = unavailable("Screen access is not enabled for this session.");
    assert_eq!(
        f.availability(None, "chat/main", None).await["take_screenshot"],
        disconnected
    );
    assert_eq!(
        f.availability(Some(&c.id), "chat/main", None).await["take_screenshot"],
        unbound
    );
    let mut changes = f.manager.subscribe_changes();
    let initial = changes.borrow_and_update().catalog.clone();
    let (frontend, mut events) = register(&f.client).await;
    assert_ne!(changes.borrow_and_update().catalog, initial);
    let before = f.read_state();
    assert_eq!(
        f.availability(None, "", None).await["take_screenshot"],
        available()
    );
    assert_eq!(
        f.availability(Some(&c.id), "", None).await["take_screenshot"],
        unbound
    );
    assert_eq!(
        native.permission(&c.id),
        DesktopPermission {
            frontend_id: None,
            enabled: false
        }
    );
    assert!(!native.approved(&c.id));
    assert_eq!(f.read_state(), before);

    let permission = DesktopPermission {
        frontend_id: Some(frontend.clone()),
        enabled: true,
    };
    let previous = changes.borrow_and_update().catalog.clone();
    f.client
        .set_desktop_permission(&c.id, &permission)
        .await
        .unwrap();
    assert_ne!(changes.borrow_and_update().catalog, previous);
    let before = f.read_state();
    for _ in 0..2 {
        // Registration explicitly reported OS permission false; it is not a prerequisite.
        assert_eq!(
            f.availability(Some(&c.id), "", None).await["take_screenshot"],
            available()
        );
        assert_eq!(native.permission(&c.id), permission);
        assert!(!native.approved(&c.id));
    }
    assert!(
        tokio::time::timeout(Duration::from_millis(25), events.next())
            .await
            .is_err()
    );
    assert_eq!(f.read_state(), before);

    let fork = f.client.fork(&c.id).await.unwrap();
    assert_eq!(
        f.availability(Some(&fork.id), "chat/main", None).await["take_screenshot"],
        unbound
    );
    assert!(!native.permission(&fork.id).enabled);
    // A real child owns neither image generation nor capture executors.
    let mut child_options = support::options(f.provider.clone(), f.tools.clone());
    child_options.metadata.parent = Some(SessionParent {
        session_id: c.id.clone(),
        operation_id: new_id(),
        tool_call_id: "delegate".into(),
    });
    let child = f.manager.create(child_options).await.unwrap();
    let status = f.availability(Some(&child.id), "search/main", None).await;
    for name in ["delegate", "generate_image", "take_screenshot"] {
        assert_eq!(status[name], unavailable("Not provided by this backend."));
    }
    assert_eq!(status["web_search"], available());

    // Another live frontend must not silently replace the session's bound one.
    let (_, other_events) = register(&f.client).await;
    let previous = changes.borrow_and_update().catalog.clone();
    drop(events);
    tokio::time::timeout(Duration::from_secs(5), changes.changed())
        .await
        .unwrap()
        .unwrap();
    assert_ne!(changes.borrow_and_update().catalog, previous);
    assert_eq!(
        f.availability(Some(&c.id), "chat/main", None).await["take_screenshot"],
        unbound
    );
    assert_eq!(
        f.availability(None, "chat/main", None).await["take_screenshot"],
        available()
    );
    assert!(!native.permission(&c.id).enabled);
    let previous = changes.borrow_and_update().catalog.clone();
    drop(other_events);
    tokio::time::timeout(Duration::from_secs(5), changes.changed())
        .await
        .unwrap()
        .unwrap();
    assert_ne!(changes.borrow_and_update().catalog, previous);
    assert_eq!(
        f.availability(None, "chat/main", None).await["take_screenshot"],
        disconnected
    );
    assert_eq!(f.chat.inference.count(), 0);
    f.service.close().await.unwrap();
}
