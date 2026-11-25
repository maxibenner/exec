use crate::{Error, Result, core::*, manager::AgentManager, storage::JsonConversationStore};
use axum::{
    body::{Body, to_bytes},
    http::{Request, Response, StatusCode},
};
use serde::Deserialize;
use serde_json::json;
use std::{
    fs,
    net::SocketAddr,
    os::unix::fs::{DirBuilderExt, MetadataExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio_util::sync::CancellationToken;

pub async fn private_directory(path: &Path) -> Result<PathBuf> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || {
        if !path.is_absolute() {
            return Err(Error::Invalid("An absolute profile path is required."));
        }
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&path)?;
        let info = fs::symlink_metadata(&path)?;
        // SAFETY: getuid has no memory-safety preconditions.
        if !info.is_dir() || info.uid() != unsafe { libc::getuid() } || info.mode() & 0o077 != 0 {
            return Err(Error::Invalid(
                "Profile must be an owned, private directory (mode 0700).",
            ));
        }
        Ok(fs::canonicalize(path)?)
    })
    .await
    .map_err(|_| Error::Internal)?
}
pub use crate::service_auth::HttpAccess;
pub const DEFAULT_ADDRESS: &str = "127.0.0.1:8765";
pub struct ServiceOptions {
    pub manager: Arc<AgentManager>,
    pub provider: Arc<dyn ChatProvider>,
    pub tools: Vec<Arc<dyn Tool>>,
    pub address: SocketAddr,
    pub access: HttpAccess,
}
pub(crate) struct Host {
    remote: Option<Arc<crate::remote::RemoteAccess>>,
    options: ServiceOptions,
    stop: CancellationToken,
    handlers: tokio_util::task::TaskTracker,
    // Independent of TCP/tunnel lifetimes: accepted writes own their capacity.
    mutations: Arc<tokio::sync::Semaphore>,
}
impl Host {
    pub(crate) fn subscribe_changes(&self) -> tokio::sync::watch::Receiver<ChangeNotification> {
        self.options.manager.subscribe_changes()
    }
}
pub struct Service {
    pub address: SocketAddr,
    stop: CancellationToken,
    task: Option<tokio::task::JoinHandle<Result<()>>>,
}
impl Service {
    pub async fn close(mut self) -> Result<()> {
        self.stop.cancel();
        self.task
            .take()
            .unwrap()
            .await
            .map_err(|_| Error::Internal)?
    }
}
impl Drop for Service {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}
pub async fn start_persistent_service(
    profile: &Path,
    provider: Arc<dyn ChatProvider>,
    workspace_tools: bool,
    address: SocketAddr,
    access: HttpAccess,
) -> Result<Service> {
    start_persistent_service_with_native(
        profile,
        provider,
        workspace_tools,
        address,
        Arc::new(crate::native::NativeHub::default()),
        access,
    )
    .await
}
pub async fn start_persistent_service_with_native(
    profile: &Path,
    provider: Arc<dyn ChatProvider>,
    workspace_tools: bool,
    address: SocketAddr,
    native: Arc<crate::native::NativeHub>,
    access: HttpAccess,
) -> Result<Service> {
    let profile = private_directory(profile).await?;
    let remote = crate::remote::RemoteAccess::load(&profile).await?;
    let images = crate::images::ImageStore::open(profile.join("images")).await?;
    let files = crate::files::FileStore::open(profile.join("session-files")).await?;
    let logs = crate::shell_logs::ShellLogStore::open(profile.join("shell-logs")).await?;
    let mut tools = if workspace_tools {
        let mut tools = crate::tools::create_file_tools();
        tools.push(crate::tools::create_logged_shell_tool(logs.clone()));
        tools
    } else {
        vec![]
    };
    tools.extend(crate::tools::create_provider_tools(provider.clone()));
    tools.push(crate::tools::create_fetch_tool());
    tools.push(crate::tools::create_wait_tool());
    tools.extend(crate::tools::create_image_tools(
        provider.clone(),
        images.clone(),
    ));
    tools.push(crate::tools::create_screenshot_tool(
        native.clone(),
        images.clone(),
    ));
    let store = JsonConversationStore::open(profile.join("conversations")).await?;
    let manager = AgentManager::open(store, |_| (provider.clone(), tools.clone())).await?;
    manager.attach_logs(logs);
    manager.attach_images(images);
    manager.attach_files(files);
    manager.attach_native(native);
    match start_service_with_remote(
        ServiceOptions {
            manager: manager.clone(),
            provider,
            tools,
            address,
            access,
        },
        Some(remote),
    )
    .await
    {
        Ok(service) => Ok(service),
        Err(error) => {
            let _ = manager.close().await;
            Err(error)
        }
    }
}
pub async fn start_service(options: ServiceOptions) -> Result<Service> {
    start_service_with_remote(options, None).await
}
async fn start_service_with_remote(
    options: ServiceOptions,
    remote: Option<Arc<crate::remote::RemoteAccess>>,
) -> Result<Service> {
    let listener = tokio::net::TcpListener::bind(options.address).await?;
    let address = listener.local_addr()?;
    let stop = CancellationToken::new();
    let host = Arc::new(Host {
        remote,
        options,
        stop: stop.clone(),
        handlers: tokio_util::task::TaskTracker::new(),
        mutations: Arc::new(tokio::sync::Semaphore::new(64)),
    });
    let task = tokio::spawn(async move {
        let remote_task = host.remote.as_ref().map(|remote| {
            tokio::spawn(remote.clone().run(Arc::downgrade(&host), host.stop.clone()))
        });
        let mut connections = tokio::task::JoinSet::new();
        let capacity = Arc::new(tokio::sync::Semaphore::new(64));
        loop {
            tokio::select! {biased;
                _=host.stop.cancelled()=>break,
                Some(_)=connections.join_next()=>{},
                accepted=listener.accept()=>{
                    let (socket, _) = match accepted {
                        Ok(value) => value,
                        Err(_) => { host.stop.cancel(); break; }
                    };
                    let Ok(permit) = capacity.clone().try_acquire_owned() else { continue; };
                    connections.spawn(serve_connection(host.clone(), socket, permit));
                }
            }
        }
        drop(listener);
        if let Some(task) = remote_task {
            let _ = task.await;
        }
        // Handlers finish their catalog mutations before shutdown takes ownership.
        while connections.join_next().await.is_some() {}
        host.handlers.close();
        host.handlers.wait().await;
        host.options.manager.cancel_and_wait().await?;
        host.options.provider.settle().await;
        host.options.manager.close().await
    });
    Ok(Service {
        address,
        stop,
        task: Some(task),
    })
}
async fn serve_connection(
    host: Arc<Host>,
    socket: tokio::net::TcpStream,
    _permit: tokio::sync::OwnedSemaphorePermit,
) {
    let handler_host = host.clone();
    let handler = hyper::service::service_fn(move |request: Request<hyper::body::Incoming>| {
        let host = handler_host.clone();
        let handlers = host.handlers.clone();
        let cancel = host.stop.child_token();
        let changes_stream = request.method() == "GET" && request.uri().path() == "/v1/changes";
        async move {
            // Cancel discovery when the caller disconnects, but let accepted
            // catalog mutations finish instead of dropping a durable write.
            let guard = cancel.clone().drop_guard();
            let response = handlers
                .spawn(async move { dispatch(host, request.map(Body::new), cancel).await })
                .await
                .unwrap_or_else(|_| json_response(500, json!({"error":"Service request failed."})));
            // A streaming request lives until its body is dropped, not merely
            // until its response headers have been produced.
            let response = if changes_stream {
                hold_response_cancel(response, guard)
            } else {
                response
            };
            Ok::<_, std::convert::Infallible>(response)
        }
    });
    let mut builder = hyper::server::conn::http1::Builder::new();
    builder
        .timer(hyper_util::rt::TokioTimer::new())
        .header_read_timeout(Duration::from_secs(10))
        .max_buf_size(8192);
    let connection = builder.serve_connection(hyper_util::rt::TokioIo::new(socket), handler);
    tokio::pin!(connection);
    tokio::select! { biased; _ = host.stop.cancelled() => {}, _ = connection.as_mut() => {} }
}
#[derive(Debug)]
struct ApiError {
    status: u16,
    message: String,
    rejected: bool,
    code: Option<&'static str>,
}
type ApiResult<T> = std::result::Result<T, ApiError>;
impl ApiError {
    // Use only at a boundary which proves this request produced no effects.
    fn rejected(status: u16, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
            rejected: true,
            code: None,
        }
    }
    fn uncertain(status: u16, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
            rejected: false,
            code: None,
        }
    }
    fn response(self) -> Response<Body> {
        let mut body = json!({"error": self.message});
        if self.rejected {
            body["delivery"] = json!("rejected");
        }
        if let Some(code) = self.code {
            body["code"] = json!(code);
        }
        json_response(self.status, body)
    }
}
impl From<Error> for ApiError {
    fn from(error: Error) -> Self {
        // Runtime errors can follow durable writes, cancellation or provider I/O.
        // Do not derive no-effect evidence from an error category or HTTP status.
        match error {
            Error::ConversationNotFound => Self::uncertain(404, "Conversation not found."),
            Error::Closed | Error::Invalid("Agent manager is closed.") => {
                Self::uncertain(503, "Service is closed.")
            }
            Error::Busy => Self::uncertain(409, "Conversation is busy."),
            Error::WorkspaceLocked => Self::uncertain(
                409,
                "Workspace cannot be changed after the first accepted turn.",
            ),
            Error::Invalid(message) => Self::uncertain(400, message),
            Error::Storage | Error::Provider(_) | Error::ProviderDetailed { .. } => {
                Self::uncertain(500, error.to_string())
            }
            _ => Self::uncertain(
                500,
                "Service request failed. Inspect conversation state before continuing.",
            ),
        }
    }
}
fn json_response(status: u16, value: impl serde::Serialize) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .header("Cache-Control", "no-store")
        .body(Body::from(serde_json::to_vec(&value).unwrap()))
        .unwrap()
}
async fn dispatch(
    host: Arc<Host>,
    request: Request<Body>,
    cancel: CancellationToken,
) -> Response<Body> {
    match handle(host, request, cancel, false).await {
        Ok(response) => response,
        Err(error) => {
            let status = error.status;
            let mut response = error.response();
            if status == 401 || status == 403 {
                response
                    .headers_mut()
                    .insert("connection", "close".parse().unwrap());
            }
            if status == 401 {
                response
                    .headers_mut()
                    .insert("www-authenticate", "Bearer".parse().unwrap());
            }
            response
        }
    }
}
async fn body<T: serde::de::DeserializeOwned>(
    request: Request<Body>,
    cancel: &CancellationToken,
) -> ApiResult<T> {
    if request
        .headers()
        .get("content-type")
        .and_then(|h| h.to_str().ok())
        != Some("application/json")
    {
        return Err(ApiError::rejected(415, "Use application/json."));
    }
    // Reading/validating an incomplete body is not an accepted mutation. Stop
    // promptly on disconnect/shutdown; never cancel the subsequent durable write.
    let bytes = tokio::select! { biased;
        _ = cancel.cancelled() => return Err(ApiError::rejected(408, "Request interrupted.")),
        result = tokio::time::timeout(
            Duration::from_secs(15),
            to_bytes(request.into_body(), 12 * 1024 * 1024),
        ) => result
            .map_err(|_| ApiError::rejected(408, "Request timed out."))?
            .map_err(|_| ApiError::rejected(413, "Request is too large."))?,
    };
    serde_json::from_slice(&bytes)
        .map_err(|_| ApiError::rejected(400, "Invalid JSON or request fields."))
}
fn identifier(id: &str) -> ApiResult<()> {
    if valid_id(id) {
        Ok(())
    } else {
        Err(ApiError::rejected(400, "Invalid identifier."))
    }
}
fn text(value: &str, max: usize) -> ApiResult<()> {
    if value.trim().is_empty() || value.encode_utf16().count() > max || value.contains('\0') {
        Err(ApiError::rejected(400, "Invalid string field."))
    } else {
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Create {
    model: Option<String>,
    workspace: String,
    settings: Option<SessionSettings>,
    #[serde(default, deserialize_with = "deserialize_disabled_tools")]
    disabled_tools: Option<Vec<String>>,
}
// Omission inherits library defaults; a present value must be an array, not null.
fn deserialize_disabled_tools<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<Vec<String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Vec::<String>::deserialize(deserializer).map(Some)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ToolAvailabilityQuery {
    names: Vec<String>,
    #[serde(
        default,
        rename = "conversationID",
        deserialize_with = "deserialize_availability_conversation"
    )]
    conversation_id: Option<String>,
    #[serde(rename = "captureFrontendID")]
    capture_frontend_id: Option<String>,
    model: String,
    search_model: Option<String>,
}
// The conversation ID may be omitted but cannot be null; preview options accept null.
fn deserialize_availability_conversation<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    String::deserialize(deserializer).map(Some)
}
impl ToolAvailabilityQuery {
    fn validate(&self) -> ApiResult<()> {
        if let Some(id) = &self.conversation_id {
            identifier(id)?;
        }
        if let Some(id) = &self.capture_frontend_id {
            identifier(id)?;
        }
        if (!self.model.is_empty() && !valid_model_id(&self.model))
            || self
                .search_model
                .as_ref()
                .is_some_and(|model| !valid_model_id(model))
        {
            return Err(ApiError::rejected(400, "Invalid model."));
        }
        let mut names = std::collections::HashSet::new();
        if self.names.len() > 128
            || self.names.iter().any(|name| {
                name.is_empty()
                    || name.len() > 128
                    || !name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
                    || !names.insert(name)
            })
        {
            return Err(ApiError::rejected(400, "Invalid tool names."));
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct PatchSession {
    disabled_tools: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ReadLog {
    offset: u64,
    #[serde(rename = "maxBytes")]
    max_bytes: usize,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Fetch {
    url: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Search {
    model: String,
    query: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Connect {
    api_key: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Empty {}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Disconnect {
    #[serde(default)]
    stop_running: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rename {
    title: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SelectWorkspace {
    workspace: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SelectModel {
    model: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UploadAsset {
    name: String,
    base64: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Submit {
    text: String,
    #[serde(default)]
    images: Vec<ImageRef>,
    #[serde(default)]
    files: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Steer {
    #[serde(rename = "operationID")]
    operation_id: String,
    text: String,
    #[serde(default)]
    images: Vec<ImageRef>,
    #[serde(default)]
    files: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cancel {
    #[serde(rename = "operationID")]
    operation_id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Resolve {
    #[serde(rename = "operationID")]
    operation_id: String,
    #[serde(rename = "approvalID")]
    approval_id: String,
    approved: bool,
}
fn sync_cursor(query: Option<&str>) -> ApiResult<SyncCursor<'_>> {
    match query {
        None => Ok(SyncCursor::Latest),
        Some(query) if query.starts_with("before=") => {
            let anchor = &query["before=".len()..];
            identifier(anchor)?;
            Ok(SyncCursor::Before(anchor))
        }
        Some(query) if query.starts_with("after=") => {
            let (anchor, prefix) = query["after=".len()..]
                .split_once("&prefix=")
                .ok_or(ApiError::rejected(400, "Invalid sync cursor."))?;
            identifier(anchor)?;
            if prefix.len() != 64 || !prefix.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(ApiError::rejected(400, "Invalid sync cursor."));
            }
            Ok(SyncCursor::After { anchor, prefix })
        }
        _ => Err(ApiError::rejected(400, "Invalid sync cursor.")),
    }
}

fn hold_response_cancel(
    response: Response<Body>,
    guard: tokio_util::sync::DropGuard,
) -> Response<Body> {
    use futures_util::StreamExt;
    let (parts, body) = response.into_parts();
    let stream = async_stream::stream! {
        let _guard = guard;
        let mut chunks = body.into_data_stream();
        while let Some(chunk) = chunks.next().await { yield chunk; }
    };
    Response::from_parts(parts, Body::from_stream(stream))
}

fn change_frames(
    mut changes: tokio::sync::watch::Receiver<ChangeNotification>,
    stop: CancellationToken,
    cancel: CancellationToken,
) -> impl futures_util::Stream<Item = std::io::Result<String>> + Send {
    async_stream::stream! {
        if stop.is_cancelled() || cancel.is_cancelled() { return; }
        let initial = changes.borrow_and_update().clone();
        let mut sent = tokio::time::Instant::now();
        yield Ok(format!("{}\n", serde_json::to_string(&initial).unwrap()));
        loop {
            tokio::select! { biased;
                _ = stop.cancelled() => break,
                _ = cancel.cancelled() => break,
                changed = changes.changed() => {
                    if changed.is_err() { break; }
                    tokio::select! { biased;
                        _ = stop.cancelled() => break,
                        _ = cancel.cancelled() => break,
                        _ = tokio::time::sleep_until(sent + Duration::from_millis(200)) => {}
                    }
                    // Release the watch read lock before yielding or doing any I/O.
                    let latest = changes.borrow_and_update().clone();
                    sent = tokio::time::Instant::now();
                    yield Ok(format!("{}\n", serde_json::to_string(&latest).unwrap()));
                }
                _ = tokio::time::sleep_until(sent + Duration::from_secs(20)) => {
                    sent = tokio::time::Instant::now();
                    yield Ok("\n".into());
                }
            }
        }
    }
}

async fn handle(
    host: Arc<Host>,
    request: Request<Body>,
    request_cancel: CancellationToken,
    remote_client: bool,
) -> ApiResult<Response<Body>> {
    if request.headers().contains_key("origin") || request.headers().contains_key("sec-fetch-site")
    {
        return Err(ApiError::rejected(
            403,
            "Browser requests are not supported.",
        ));
    }
    let native = request.uri().path().starts_with("/v1/native/")
        || (request.method() == "PUT"
            && request.uri().path().starts_with("/v1/conversations/")
            && request.uri().path().ends_with("/desktop"));
    if remote_client {
        let path = request
            .uri()
            .path_and_query()
            .map(|p| p.as_str())
            .unwrap_or("");
        if !crate::remote::permits(request.method().as_str(), path) {
            return Err(ApiError::rejected(
                403,
                "This operation is unavailable to remote devices.",
            ));
        }
    } else {
        host.options
            .access
            .authorize(request.headers(), native)
            .map_err(|(status, message)| ApiError::rejected(status, message))?;
    }
    if host.stop.is_cancelled() {
        return Err(ApiError::rejected(503, "Service is stopping."));
    }
    // Acquire inside the tracked handler, after authorization and before body
    // allocation or effects. Disconnects cannot release an accepted write's slot.
    // All non-GET commands share this budget across local and remote transports.
    let _mutation_permit = if request.method() == "GET" {
        None
    } else {
        Some(host.mutations.clone().try_acquire_owned().map_err(|_| {
            ApiError::rejected(
                503,
                "Service mutation capacity is full. No work was accepted.",
            )
        })?)
    };
    let route = request.uri().path().to_owned();
    if request.uri().query().is_some() && !route.ends_with("/sync") {
        return Err(ApiError::rejected(404, "Route not found."));
    }
    let method = request.method().as_str().to_owned();
    if route.starts_with("/v1/remote") {
        let remote = host.remote.as_ref().ok_or(ApiError::rejected(
            404,
            "Remote access requires a persistent profile.",
        ))?;
        match (method.as_str(), route.as_str()) {
            ("GET", "/v1/remote") => return Ok(json_response(200, remote.status().await)),
            ("PUT", "/v1/remote") => {
                remote
                    .configure(body(request, &request_cancel).await?)
                    .await?;
                return Ok(json_response(200, remote.status().await));
            }
            ("POST", "/v1/remote/invitations") => {
                let _: Empty = body(request, &request_cancel).await?;
                return Ok(json_response(200, remote.invite().await?));
            }
            ("DELETE", path) if path.starts_with("/v1/remote/devices/") => {
                let id = &path["/v1/remote/devices/".len()..];
                identifier(id)?;
                remote.revoke(id).await?;
                return Ok(json_response(200, remote.status().await));
            }
            _ => return Err(ApiError::rejected(404, "Route not found.")),
        }
    }
    if method == "GET" && route == "/v1/changes" {
        return Ok(Response::builder()
            .status(200)
            .header("Content-Type", "application/x-ndjson")
            .header("Cache-Control", "no-store")
            .header("X-Content-Type-Options", "nosniff")
            .body(Body::from_stream(change_frames(
                host.subscribe_changes(),
                host.stop.clone(),
                request_cancel,
            )))
            .unwrap());
    }
    let options = &host.options;
    if method == "POST" && route == "/v1/tools/availability" {
        let input: ToolAvailabilityQuery = body(request, &request_cancel).await?;
        input.validate()?;
        let capture_preview = if remote_client {
            if input.capture_frontend_id.is_some() {
                return Err(ApiError::rejected(
                    400,
                    "Remote previews cannot select a local capture frontend.",
                ));
            }
            Some(CapturePreview::Remote)
        } else {
            input.capture_frontend_id.map(CapturePreview::Frontend)
        };
        let availability = if let Some(id) = &input.conversation_id {
            options.manager.tool_availability(
                id,
                &input.names,
                &input.model,
                input.search_model.as_deref(),
                capture_preview,
            )?
        } else {
            options.manager.default_tool_availability(
                options.provider.clone(),
                options.tools.clone(),
                &input.names,
                &input.model,
                input.search_model.as_deref(),
                capture_preview,
            )?
        };
        return Ok(json_response(200, availability));
    }
    if method == "POST" && route == "/v1/workspaces/browse" {
        let input: crate::workspace_picker::Browse = body(request, &request_cancel).await?;
        return Ok(json_response(
            200,
            crate::workspace_picker::browse(input, request_cancel).await?,
        ));
    }
    if method == "POST" && route == "/v1/native/events" {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Register {
            os_screen_permission: bool,
            #[serde(default)]
            accepts_remote_conversations: bool,
        }
        let input: Register = body(request, &request_cancel).await?;
        let mut connection = options.manager.native().register(
            input.os_screen_permission,
            input.accepts_remote_conversations,
        )?;
        let stop = host.stop.clone();
        let frames = async_stream::stream! {
            let line=serde_json::to_vec(&crate::native::NativeEvent::Registered{frontend_id:connection.id.clone()}).unwrap();yield Ok::<_,std::io::Error>(bytes::Bytes::from([line,b"\n".to_vec()].concat()));
            let mut interval=tokio::time::interval(Duration::from_secs(15));interval.tick().await;
            loop{let event=tokio::select!{biased;_=stop.cancelled()=>break,request=connection.requests.recv()=>{let Some(request)=request else{break;};request},_=interval.tick()=>crate::native::NativeEvent::Ping};let mut line=serde_json::to_vec(&event).unwrap();line.push(b'\n');yield Ok(bytes::Bytes::from(line));}
        };
        return Ok(Response::builder()
            .status(200)
            .header("Content-Type", "application/x-ndjson")
            .header("Cache-Control", "no-store")
            .body(Body::from_stream(frames))
            .unwrap());
    }
    if method == "PUT" && route == "/v1/native/permission" {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Permission {
            #[serde(rename = "frontendID")]
            frontend_id: String,
            granted: bool,
        }
        let input: Permission = body(request, &request_cancel).await?;
        options
            .manager
            .native()
            .update_os_permission(&input.frontend_id, input.granted)?;
        return Ok(json_response(200, json!({"accepted":true})));
    }
    if method == "POST" && route == "/v1/native/results" {
        let input: crate::native::NativeReply = body(request, &request_cancel).await?;
        options.manager.native().reply(input).map_err(|_| {
            ApiError::uncertain(
                409,
                "Native request is no longer active or does not match this request and action.",
            )
        })?;
        return Ok(json_response(200, json!({"accepted":true})));
    }
    if method == "GET" && route == "/v1/health" {
        return Ok(json_response(
            200,
            json!({"version":1,"toolsEnabled":options.tools.iter().any(|tool| !["web_search", "fetch_content","generate_image","take_screenshot","wait"].contains(&tool.definition().name.as_str()))}),
        ));
    }
    if method == "GET" && route == "/v1/metadata" {
        return Ok(json_response(200, options.provider.metadata_freshness()));
    }
    if method == "GET" && route == "/v1/model-warnings" {
        return Ok(json_response(200, options.provider.model_warnings()));
    }
    if method == "GET" && route == "/v1/models" {
        let cancel = request_cancel.child_token();
        let _guard = cancel.clone().drop_guard();
        let models = tokio::select! {biased;_=cancel.cancelled()=>return Err(ApiError::uncertain(503,"Service is stopping.")),value=tokio::time::timeout(Duration::from_secs(120),options.manager.discover_models(options.provider.clone(), cancel.clone()))=>value.map_err(|_|ApiError::uncertain(500,"Model discovery failed."))??};
        return Ok(json_response(200, models));
    }
    if method == "GET"
        && let Some(id) = route.strip_prefix("/v1/images/")
    {
        identifier(id)?;
        return Ok(json_response(200, options.manager.read_image(id).await?));
    }
    if method == "POST"
        && let Some(id) = route.strip_prefix("/v1/logs/")
    {
        identifier(id)?;
        let input: ReadLog = body(request, &request_cancel).await?;
        if input.max_bytes == 0 || input.max_bytes > 32768 {
            return Err(ApiError::rejected(400, "Read 1–32768 log bytes."));
        }
        let chunk = options
            .manager
            .read_log(id, input.offset, input.max_bytes)
            .await
            .map_err(|error| match error {
                Error::Invalid("Log is not referenced by an available conversation.") => {
                    ApiError::uncertain(404, "Log not found.")
                }
                Error::Invalid(message) => ApiError::uncertain(400, message),
                other => ApiError::from(other),
            })?;
        return Ok(json_response(200, chunk));
    }
    if method == "POST" && route == "/v1/fetch" {
        let input: Fetch = body(request, &request_cancel).await?;
        crate::content_fetch::public_url(&input.url).map_err(|_| {
            ApiError::rejected(
                400,
                "Use a public HTTPS URL without credentials on port 443.",
            )
        })?;
        let result = options
            .manager
            .fetch_content(&input.url, request_cancel)
            .await?;
        return Ok(json_response(200, result));
    }
    if method == "POST" && route == "/v1/search" {
        let search: Search = body(request, &request_cancel).await?;
        text(&search.model, 128)?;
        search_query(&search.query)
            .map_err(|_| ApiError::rejected(400, "Invalid search query."))?;
        return Ok(json_response(
            200,
            options
                .manager
                .search_web(
                    options.provider.clone(),
                    &search.model,
                    search.query,
                    request_cancel,
                )
                .await?,
        ));
    }
    if method == "GET"
        && let Some(id) = route
            .strip_prefix("/v1/providers/")
            .and_then(|s| s.strip_suffix("/balance"))
    {
        if id.is_empty() || id.contains('/') {
            return Err(ApiError::rejected(404, "Provider not found."));
        }
        return Ok(json_response(
            200,
            options
                .manager
                .account_balances(options.provider.clone(), id, request_cancel)
                .await?,
        ));
    }
    if method == "GET" && route == "/v1/connection-attempt" {
        return Ok(json_response(200, options.manager.connection_attempt()));
    }
    if method == "POST" && route == "/v1/connection-attempt/cancel" {
        let input: Cancel = body(request, &request_cancel).await?;
        identifier(&input.operation_id)?;
        options.manager.cancel_connection(&input.operation_id)?;
        return Ok(json_response(202, json!({"accepted":true})));
    }
    if method == "POST"
        && let Some(id) = route
            .strip_prefix("/v1/providers/")
            .and_then(|s| s.strip_suffix("/connect"))
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Authenticate {
            #[serde(default)]
            method: ConnectionMethod,
        }
        let input: Authenticate = body(request, &request_cancel).await?;
        return Ok(json_response(
            202,
            options
                .manager
                .connect_with_method(options.provider.clone(), id, input.method)
                .await?,
        ));
    }
    if method == "GET"
        && let Some(id) = route
            .strip_prefix("/v1/providers/")
            .and_then(|s| s.strip_suffix("/usage"))
    {
        return Ok(json_response(
            200,
            options
                .manager
                .account_usage(options.provider.clone(), id, request_cancel)
                .await?,
        ));
    }
    if method == "GET" && route == "/v1/providers" {
        return Ok(json_response(
            200,
            options.manager.connections(options.provider.as_ref()),
        ));
    }
    if let Some(id) = route.strip_prefix("/v1/providers/") {
        if id.is_empty() || id.contains('/') {
            return Err(ApiError::rejected(404, "Provider not found."));
        }
        let result = match method.as_str() {
            "PUT" => {
                let credential = body::<Connect>(request, &request_cancel).await?.api_key;
                options
                    .manager
                    .set_credential(options.provider.clone(), id, Some(credential))
                    .await
            }
            "DELETE" => {
                // Legacy bodyless DELETE remains safe: active work requires explicit consent.
                let has_body = request.headers().contains_key("content-type")
                    || request.headers().contains_key("transfer-encoding")
                    || request
                        .headers()
                        .get("content-length")
                        .is_some_and(|v| v != "0");
                let input = if has_body {
                    body::<Disconnect>(request, &request_cancel).await?
                } else {
                    Disconnect::default()
                };
                options
                    .manager
                    .disconnect_provider(options.provider.clone(), id, input.stop_running)
                    .await
            }
            _ => return Err(ApiError::rejected(404, "Route not found.")),
        };
        let connections = result.map_err(|error| match error {
            Error::ProviderInUse => {
                // This gate runs under the catalog lock, before cancellation or any write.
                let mut error = ApiError::rejected(409, error.to_string());
                error.code = Some("provider_in_use");
                error
            }
            other => ApiError::from(other),
        })?;
        return Ok(json_response(200, connections));
    }
    if route == "/v1/library" {
        return match method.as_str() {
            "GET" => Ok(json_response(200, options.manager.library_configuration()?)),
            "PATCH" => {
                let patch: serde_json::Value = body(request, &request_cancel).await?;
                Ok(json_response(
                    200,
                    options.manager.patch_library(patch).await?,
                ))
            }
            "PUT" => {
                let config: LibraryConfiguration = body(request, &request_cancel).await?;
                config
                    .validate()
                    .map_err(|_| ApiError::rejected(400, "Invalid library configuration."))?;
                Ok(json_response(
                    200,
                    options.manager.update_library(config).await?,
                ))
            }
            _ => Err(ApiError::rejected(404, "Route not found.")),
        };
    }
    if route == "/v1/conversations" {
        if method == "GET" {
            let mut summaries: Vec<_> = options
                .manager
                .summaries()?
                .into_iter()
                .map(|s| serde_json::to_value(s).unwrap())
                .collect();
            summaries.extend(
                options
                    .manager
                    .unreadable_sessions()
                    .into_iter()
                    .map(|id| json!({"id":id,"unreadable":true,"title":"Unreadable conversation"})),
            );
            if let Ok(library) = options.manager.library_configuration() {
                summaries.sort_by_key(|value| {
                    library
                        .order
                        .iter()
                        .position(|id| value["id"].as_str() == Some(id))
                        .unwrap_or(usize::MAX)
                });
            }
            return Ok(json_response(200, summaries));
        }
        if method == "POST" {
            let create: Create = body(request, &request_cancel).await?;
            if let Some(model) = &create.model {
                text(model, 128)?;
            }
            text(&create.workspace, 4096)?;
            let created = options
                .manager
                .create_session(
                    options.provider.clone(),
                    options.tools.clone(),
                    create.model,
                    create.workspace,
                    create.settings,
                    create.disabled_tools,
                )
                .await
                .map_err(|error| match error {
                    Error::Invalid(message) => ApiError::uncertain(400, message),
                    other => ApiError::from(other),
                })?;
            return Ok(json_response(201, created.snapshot()));
        }
    }
    let Some(tail) = route.strip_prefix("/v1/conversations/") else {
        return Err(ApiError::rejected(404, "Route not found."));
    };
    let parts: Vec<_> = tail.split('/').collect();
    if method == "DELETE" && parts.len() == 3 && parts[1] == "images" {
        identifier(parts[0])?;
        identifier(parts[2])?;
        options
            .manager
            .release_image(parts[0], parts[2])
            .await
            .map_err(|e| match e {
                Error::Invalid(message) => ApiError::uncertain(409, message),
                other => other.into(),
            })?;
        return Ok(json_response(200, json!({"released":true})));
    }

    if parts.is_empty()
        || parts.len() > 2
        || parts.get(1).is_some_and(|s| {
            ![
                "events",
                "sync",
                "turns",
                "cancel",
                "approvals",
                "settings",
                "steer",
                "title",
                "model",
                "workspace",
                "fork",
                "clear",
                "compact",
                "images",
                "files",
                "desktop",
            ]
            .contains(s)
        })
    {
        return Err(ApiError::rejected(404, "Route not found."));
    }
    identifier(parts[0])?;
    if options
        .manager
        .unreadable_sessions()
        .iter()
        .any(|id| id == parts[0])
    {
        if method == "DELETE" && parts.len() == 1 {
            options.manager.delete(parts[0]).await?;
            return Ok(json_response(200, json!({"deleted":true})));
        }
        return Err(ApiError::rejected(
            409,
            "Conversation is unreadable. Its file is preserved; inspect it before explicit deletion.",
        ));
    }
    let action = parts.get(1).copied();
    if method == "GET" && action == Some("sync") {
        let page = options
            .manager
            .sync(parts[0], sync_cursor(request.uri().query())?)
            .map_err(|error| match error {
                Error::Invalid(message) => ApiError::uncertain(409, message),
                other => other.into(),
            })?;
        return Ok(json_response(200, page));
    }
    if method == "GET" && action.is_none() {
        return Ok(json_response(200, options.manager.snapshot(parts[0])?));
    }
    if method == "GET" && action == Some("events") {
        let (snapshot, mut receiver) = options.manager.observe(parts[0])?;
        let stop = host.stop.clone();
        let frames = async_stream::stream! {
            yield Ok::<_,std::io::Error>(format!("{}\n",serde_json::to_string(&ServiceEvent::Snapshot{snapshot}).unwrap()));
            loop {
                let frame=tokio::select!{biased;_=stop.cancelled()=>break,value=receiver.recv()=>value};
                match frame {
                    Ok(frame)=>yield Ok(format!("{}\n",serde_json::to_string(frame.as_ref()).unwrap())),
                    Err(_)=>{yield Err(std::io::Error::other("Observer disconnected; reconnect for a snapshot."));break;}
                }
            }
        };
        return Ok(Response::builder()
            .status(StatusCode::OK)
            .header("Content-Type", "application/x-ndjson")
            .header("Cache-Control", "no-store")
            .header("X-Content-Type-Options", "nosniff")
            .body(Body::from_stream(frames))
            .unwrap());
    }
    if method == "POST" && action == Some("clear") {
        let _: Empty = body(request, &request_cancel).await?;
        if host.stop.is_cancelled() {
            return Err(ApiError::rejected(503, "Service is stopping."));
        }
        let snapshot = options
            .manager
            .clear(parts[0])
            .await
            .map_err(|error| match error {
                Error::Invalid("Conversation not found.") => {
                    ApiError::uncertain(404, "Conversation not found.")
                }
                Error::Storage => {
                    ApiError::uncertain(409, "Conversation requires storage recovery.")
                }
                other => ApiError::from(other),
            })?;
        return Ok(json_response(200, snapshot));
    }
    let conversation = options.manager.get(parts[0])?;
    match (method.as_str(), action) {
        ("PATCH", None) => {
            let patch: PatchSession = body(request, &request_cancel).await?;
            if host.stop.is_cancelled() {
                return Err(ApiError::rejected(503, "Service is stopping."));
            }
            Ok(json_response(
                200,
                conversation
                    .update_disabled_tools(patch.disabled_tools)
                    .await?,
            ))
        }
        ("DELETE", None) => {
            if host.stop.is_cancelled() {
                return Err(ApiError::rejected(503, "Service is stopping."));
            }
            options.manager.delete(parts[0]).await?;
            Ok(json_response(200, json!({"deleted":true})))
        }
        ("PUT", Some("title")) => {
            let input: Rename = body(request, &request_cancel).await?;
            let metadata = SessionMetadata {
                title: Some(input.title.clone()),
                manually_named: true,
                activity_at: 0,
                ..SessionMetadata::default()
            };
            metadata
                .validate()
                .map_err(|_| ApiError::rejected(400, "Invalid title."))?;
            Ok(json_response(
                200,
                options.manager.rename(parts[0], input.title).await?,
            ))
        }
        ("PUT", Some("model")) => {
            let input: SelectModel = body(request, &request_cancel).await?;
            text(&input.model, 128)?;
            Ok(json_response(
                200,
                options.manager.select_model(parts[0], input.model).await?,
            ))
        }
        ("PUT", Some("workspace")) => {
            let input: SelectWorkspace = body(request, &request_cancel).await?;
            text(&input.workspace, 4096)?;
            if host.stop.is_cancelled() {
                return Err(ApiError::rejected(503, "Service is stopping."));
            }
            Ok(json_response(
                200,
                options
                    .manager
                    .select_workspace(parts[0], input.workspace)
                    .await?,
            ))
        }
        ("POST", Some("fork")) => {
            let _: Empty = body(request, &request_cancel).await?;
            Ok(json_response(
                201,
                options
                    .manager
                    .fork(parts[0], options.provider.clone(), options.tools.clone())
                    .await?
                    .snapshot(),
            ))
        }
        ("PUT", Some("settings")) => {
            let settings: SessionSettings = body(request, &request_cancel).await?;
            settings
                .validate()
                .map_err(|_| ApiError::rejected(400, "Invalid session settings."))?;
            if host.stop.is_cancelled() {
                return Err(ApiError::rejected(503, "Service is stopping."));
            }
            Ok(json_response(
                200,
                options.manager.update_settings(parts[0], settings).await?,
            ))
        }
        ("POST", Some("turns")) => {
            let submit: Submit = body(request, &request_cancel).await?;
            if submit.images.is_empty() && submit.files.is_empty() {
                text(&submit.text, 128 * 1024)?;
            } else if submit.text.len() > 128 * 1024 || submit.text.contains('\0') {
                return Err(ApiError::rejected(400, "Invalid message."));
            }
            if host.stop.is_cancelled() {
                return Err(ApiError::rejected(503, "Service is stopping."));
            }
            if remote_client {
                options.manager.bind_remote_desktop(parts[0])?;
            }
            let run = options
                .manager
                .submit_attachments(parts[0], submit.text, submit.images, submit.files)
                .await
                .map_err(|error| match error {
                    Error::Invalid(message) => ApiError::uncertain(400, message),
                    Error::Storage => {
                        ApiError::uncertain(409, "Conversation requires storage recovery.")
                    }
                    other => ApiError::from(other),
                })?;
            Ok(json_response(202, json!({"operationID":run.operation_id})))
        }
        ("POST", Some("compact")) => {
            let _: Empty = body(request, &request_cancel).await?;
            let run = options.manager.compact(parts[0])?;
            Ok(json_response(202, json!({"operationID":run.operation_id})))
        }
        ("GET", Some("desktop")) => Ok(json_response(
            200,
            options.manager.desktop_permission(parts[0])?,
        )),
        ("PUT", Some("desktop")) => {
            let input: crate::native::DesktopPermission = body(request, &request_cancel).await?;
            Ok(json_response(
                200,
                options.manager.set_desktop_permission(parts[0], input)?,
            ))
        }
        ("POST", Some("files")) => {
            let input: UploadAsset = body(request, &request_cancel).await?;
            use base64::Engine;
            if input.base64.len() > MAX_FILE_BYTES.div_ceil(3) * 4 {
                return Err(ApiError::rejected(400, "File exceeds 8 MiB."));
            }
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(&input.base64)
                .map_err(|_| ApiError::rejected(400, "Invalid file data."))?;
            let file = options
                .manager
                .upload_file(parts[0], input.name, bytes)
                .await?;
            Ok(json_response(201, file))
        }
        ("POST", Some("images")) => {
            let input: UploadAsset = body(request, &request_cancel).await?;
            let bytes = crate::images::decode_base64(&input.base64)
                .map_err(|_| ApiError::rejected(400, "Invalid image data."))?;
            let image = options
                .manager
                .upload_image(parts[0], input.name, bytes)
                .await?;
            Ok(json_response(201, image))
        }
        ("POST", Some("steer")) => {
            let input: Steer = body(request, &request_cancel).await?;
            identifier(&input.operation_id)?;
            let id = options
                .manager
                .steer_attachments(
                    parts[0],
                    &input.operation_id,
                    input.text,
                    input.images,
                    input.files,
                )
                .await?;
            Ok(json_response(
                202,
                json!({"operationID":input.operation_id,"messageID":id}),
            ))
        }
        ("POST", Some("cancel")) => {
            let cancel: Cancel = body(request, &request_cancel).await?;
            identifier(&cancel.operation_id)?;
            if !conversation.cancel(&cancel.operation_id) {
                return Err(ApiError::uncertain(
                    409,
                    "Operation is no longer cancellable.",
                ));
            }
            Ok(json_response(
                202,
                json!({"accepted":true,"operationID":cancel.operation_id}),
            ))
        }
        ("POST", Some("approvals")) => {
            let resolve: Resolve = body(request, &request_cancel).await?;
            identifier(&resolve.operation_id)?;
            identifier(&resolve.approval_id)?;
            if !conversation.resolve_approval(
                &resolve.operation_id,
                &resolve.approval_id,
                resolve.approved,
            ) {
                return Err(ApiError::uncertain(
                    409,
                    "Approval is stale or already resolved.",
                ));
            }
            Ok(json_response(200, json!({"resolved":true})))
        }
        _ => Err(ApiError::rejected(405, "Method not allowed.")),
    }
}

/// Accepted catalog writes outlive the tunnel task; service shutdown awaits them.
pub(crate) async fn remote_request(host: Arc<Host>, request: Request<Body>) -> Response<Body> {
    let handlers = host.handlers.clone();
    let cancel = host.stop.child_token();
    let changes_stream = request.method() == "GET" && request.uri().path() == "/v1/changes";
    let guard = cancel.clone().drop_guard();
    let response = handlers
        .spawn(async move {
            match handle(host, request, cancel, true).await {
                Ok(response) => response,
                Err(error) => error.response(),
            }
        })
        .await
        .unwrap_or_else(|_| json_response(500, json!({"error":"Remote request failed."})));
    if changes_stream {
        hold_response_cancel(response, guard)
    } else {
        response
    }
}

#[cfg(test)]
mod change_tests {
    use super::*;
    use futures_util::{FutureExt, StreamExt};

    #[tokio::test(start_paused = true)]
    async fn initial_coalescing_heartbeat_and_cancellation() {
        let hub = Arc::new(ChangeHub::default());
        let stop = CancellationToken::new();
        let cancel = CancellationToken::new();
        let mut frames = Box::pin(change_frames(hub.subscribe(), stop, cancel.clone()));
        let initial = frames.next().await.unwrap().unwrap();
        assert!(
            serde_json::from_str::<serde_json::Value>(&initial).unwrap()["catalog"].is_string()
        );
        assert!(frames.next().now_or_never().is_none());
        hub.catalog_changed();
        assert!(frames.next().now_or_never().is_none());
        tokio::time::advance(Duration::from_millis(199)).await;
        for _ in 0..100 {
            hub.catalog_changed();
        }
        assert!(frames.next().now_or_never().is_none());
        tokio::time::advance(Duration::from_millis(1)).await;
        let next = frames.next().await.unwrap().unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&next).unwrap()["catalog"],
            "101"
        );
        assert!(frames.next().now_or_never().is_none());
        tokio::time::advance(Duration::from_secs(20)).await;
        assert_eq!(frames.next().await.unwrap().unwrap(), "\n");
        cancel.cancel();
        assert!(frames.next().await.is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn shutdown_interrupts_pending_coalescing_and_subscription_catches_early_change() {
        let hub = Arc::new(ChangeHub::default());
        let rx = hub.subscribe();
        hub.catalog_changed();
        let stop = CancellationToken::new();
        let mut frames = Box::pin(change_frames(rx, stop.clone(), CancellationToken::new()));
        assert!(
            frames
                .next()
                .await
                .unwrap()
                .unwrap()
                .contains("\"catalog\":\"1\"")
        );
        hub.catalog_changed();
        assert!(frames.next().now_or_never().is_none());
        stop.cancel();
        assert!(frames.next().await.is_none());
    }

    #[tokio::test]
    async fn closed_lookups_are_unavailable_and_internal_errors_are_not_absence() {
        let manager = Arc::new(AgentManager::default());
        manager.close().await.unwrap();
        let host = Arc::new(Host {
            options: ServiceOptions {
                manager,
                provider: Arc::new(NoInference),
                tools: vec![],
                address: "127.0.0.1:0".parse().unwrap(),
                access: HttpAccess::externally_secured(None).unwrap(),
            },
            remote: None,
            stop: CancellationToken::new(),
            handlers: tokio_util::task::TaskTracker::new(),
            mutations: Arc::new(tokio::sync::Semaphore::new(64)),
        });
        for (method, suffix) in [
            ("GET", ""),
            ("GET", "/events"),
            ("GET", "/sync"),
            ("PUT", "/title"),
        ] {
            let request = Request::builder()
                .method(method)
                .uri(format!("/v1/conversations/{}{suffix}", new_id()))
                .body(Body::empty())
                .unwrap();
            assert_eq!(
                dispatch(host.clone(), request, CancellationToken::new())
                    .await
                    .status(),
                503
            );
        }
        assert_eq!(ApiError::from(Error::Internal).status, 500);
        assert_eq!(ApiError::from(Error::Storage).status, 500);
    }

    #[tokio::test]
    async fn incomplete_body_cancellation_releases_shared_admission_without_mutation() {
        let manager = Arc::new(AgentManager::default());
        let provider = Arc::new(NoInference);
        let conversation = manager
            .create(ConversationOptions::new(provider.clone(), "test", "/test"))
            .await
            .unwrap();
        let before = conversation.snapshot();
        let host = Arc::new(Host {
            options: ServiceOptions {
                manager: manager.clone(),
                provider,
                tools: vec![],
                address: "127.0.0.1:0".parse().unwrap(),
                access: HttpAccess::externally_secured(None).unwrap(),
            },
            remote: None,
            stop: CancellationToken::new(),
            handlers: tokio_util::task::TaskTracker::new(),
            mutations: Arc::new(tokio::sync::Semaphore::new(1)),
        });
        let route = format!("/v1/conversations/{}/title", conversation.id);
        let (entered, reading) = tokio::sync::oneshot::channel();
        let stream = async_stream::stream! {
            entered.send(()).unwrap();
            std::future::pending::<()>().await;
            yield Ok::<_, std::io::Error>(bytes::Bytes::new());
        };
        let request = Request::builder()
            .method("PUT")
            .uri(&route)
            .header("Content-Type", "application/json")
            .body(Body::from_stream(stream))
            .unwrap();
        let caller = tokio::spawn(remote_request(host.clone(), request));
        tokio::time::timeout(Duration::from_secs(2), reading)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(host.mutations.available_permits(), 0);
        let valid_request = || {
            Request::builder()
                .method("PUT")
                .uri(&route)
                .header("Content-Type", "application/json")
                .body(Body::from(r#"{"title":"accepted"}"#))
                .unwrap()
        };
        for response in [
            dispatch(host.clone(), valid_request(), CancellationToken::new()).await,
            remote_request(host.clone(), valid_request()).await,
        ] {
            assert_eq!(response.status(), 503);
            let body: serde_json::Value =
                serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap())
                    .unwrap();
            assert_eq!(body["delivery"], "rejected");
            assert_eq!(
                body["error"],
                "Service mutation capacity is full. No work was accepted."
            );
        }
        // Only the transport caller is aborted, before a body has been accepted.
        caller.abort();
        assert!(caller.await.unwrap_err().is_cancelled());
        host.handlers.close();
        tokio::time::timeout(Duration::from_secs(2), host.handlers.wait())
            .await
            .unwrap();
        assert_eq!(host.mutations.available_permits(), 1);
        assert_eq!(conversation.snapshot(), before);
        assert_eq!(
            dispatch(host, valid_request(), CancellationToken::new())
                .await
                .status(),
            200
        );
        assert_eq!(
            conversation.snapshot().metadata.title.as_deref(),
            Some("accepted")
        );
        manager.close().await.unwrap();
    }

    #[derive(Default)]
    struct MetadataGate {
        entered: CancellationToken,
        release: CancellationToken,
        calls: std::sync::atomic::AtomicUsize,
    }
    impl MetadataGate {
        async fn hold(&self) {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            self.entered.cancel();
            self.release.cancelled().await;
        }
    }
    #[async_trait::async_trait]
    impl ChatProvider for MetadataGate {
        fn stream(
            &self,
            _: ProviderRequest,
        ) -> futures_util::stream::BoxStream<'static, Result<ProviderEvent>> {
            panic!("metadata tests must not infer")
        }
        async fn models(&self, _: CancellationToken) -> Result<Vec<ChatModel>> {
            self.hold().await;
            Ok(vec![])
        }
        async fn account_balances(
            &self,
            _: &str,
            _: CancellationToken,
        ) -> Result<Vec<AccountBalance>> {
            self.hold().await;
            Ok(vec![])
        }
        async fn account_usage(&self, _: &str, _: CancellationToken) -> Result<AccountUsage> {
            self.hold().await;
            Ok(AccountUsage {
                windows: vec![],
                fetched_at: 0,
                stale: false,
            })
        }
    }

    #[tokio::test]
    async fn provider_reads_report_closed_before_dispatch_and_after_gated_completion() {
        for route in [
            "/v1/models",
            "/v1/providers/fake/balance",
            "/v1/providers/fake/usage",
        ] {
            for close_before in [true, false] {
                let manager = Arc::new(AgentManager::default());
                let provider = Arc::new(MetadataGate::default());
                let host = Arc::new(Host {
                    options: ServiceOptions {
                        manager: manager.clone(),
                        provider: provider.clone(),
                        tools: vec![],
                        address: "127.0.0.1:0".parse().unwrap(),
                        access: HttpAccess::externally_secured(None).unwrap(),
                    },
                    remote: None,
                    stop: CancellationToken::new(),
                    handlers: tokio_util::task::TaskTracker::new(),
                    mutations: Arc::new(tokio::sync::Semaphore::new(64)),
                });
                if close_before {
                    manager.close().await.unwrap();
                }
                let request = Request::builder().uri(route).body(Body::empty()).unwrap();
                let caller = tokio::spawn(dispatch(host, request, CancellationToken::new()));
                if !close_before {
                    tokio::time::timeout(Duration::from_secs(2), provider.entered.cancelled())
                        .await
                        .unwrap();
                    manager.close().await.unwrap();
                    provider.release.cancel();
                }
                let response = tokio::time::timeout(Duration::from_secs(2), caller)
                    .await
                    .unwrap()
                    .unwrap();
                assert_eq!(
                    response.status(),
                    503,
                    "{route}, closed before dispatch: {close_before}"
                );
                let body: serde_json::Value =
                    serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap())
                        .unwrap();
                assert_eq!(body["error"], "Service is closed.");
                assert!(body.get("delivery").is_none());
                assert_eq!(
                    provider.calls.load(std::sync::atomic::Ordering::SeqCst),
                    usize::from(!close_before)
                );
            }
        }
    }

    #[tokio::test]
    async fn runtime_error_serialization_never_claims_no_effects_and_retains_safe_diagnostics() {
        for error in [
            Error::Internal,
            Error::Storage,
            Error::Busy,
            Error::Closed,
            Error::Invalid("Safe runtime validation."),
            Error::Provider(crate::ProviderFailure::Transport),
            Error::ProviderDetailed {
                reason: crate::ProviderFailure::Transport,
                detail: crate::ProviderDiagnostic::HttpStatus { status: 503 },
            },
        ] {
            let expected = match &error {
                Error::Storage | Error::Provider(_) | Error::ProviderDetailed { .. } => {
                    Some(error.to_string())
                }
                _ => None,
            };
            let response = ApiError::from(error).response();
            let body: serde_json::Value =
                serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap())
                    .unwrap();
            assert!(body.get("delivery").is_none());
            if let Some(expected) = expected {
                assert_eq!(body["error"], expected);
            }
        }
    }

    struct NoInference;
    #[async_trait::async_trait]
    impl ChatProvider for NoInference {
        fn stream(
            &self,
            _: ProviderRequest,
        ) -> futures_util::stream::BoxStream<'static, Result<ProviderEvent>> {
            panic!("no inference in read-only tests")
        }
    }
    #[tokio::test]
    async fn http_change_body_outlives_response_headers_and_service_shutdown() {
        let manager = Arc::new(AgentManager::default());
        let service = start_service(ServiceOptions {
            manager: manager.clone(),
            provider: Arc::new(NoInference),
            tools: vec![],
            address: "127.0.0.1:0".parse().unwrap(),
            access: HttpAccess::externally_secured(None).unwrap(),
        })
        .await
        .unwrap();
        // Isolated loopback transport only: no credentials or external providers.
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let response = client
            .get(format!("http://{}/v1/changes", service.address))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        let mut chunks = response.bytes_stream();
        let first = tokio::time::timeout(Duration::from_secs(3), chunks.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let initial: serde_json::Value = serde_json::from_slice(&first).unwrap();
        manager
            .update_library(LibraryConfiguration::default())
            .await
            .unwrap();
        let next = tokio::time::timeout(Duration::from_secs(3), chunks.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let updated: serde_json::Value = serde_json::from_slice(&next).unwrap();
        assert_ne!(initial["catalog"], updated["catalog"]);
        assert!(
            tokio::time::timeout(Duration::from_millis(25), chunks.next())
                .await
                .is_err()
        );
        tokio::time::timeout(Duration::from_secs(3), service.close())
            .await
            .unwrap()
            .unwrap();
        // Shutdown may end HTTP cleanly or close the socket; either must be prompt.
        let end = tokio::time::timeout(Duration::from_secs(3), chunks.next())
            .await
            .unwrap();
        assert!(end.is_none() || end.unwrap().is_err());
    }

    #[tokio::test]
    async fn routes_return_ndjson_and_compatible_summary_without_network() {
        let manager = Arc::new(AgentManager::default());
        let provider = Arc::new(NoInference);
        let conversation = manager
            .create(ConversationOptions::new(provider.clone(), "test", "/test"))
            .await
            .unwrap();
        let host = Arc::new(Host {
            options: ServiceOptions {
                manager,
                provider,
                tools: vec![],
                address: "127.0.0.1:0".parse().unwrap(),
                access: HttpAccess::externally_secured(None).unwrap(),
            },
            remote: None,
            stop: CancellationToken::new(),
            handlers: tokio_util::task::TaskTracker::new(),
            mutations: Arc::new(tokio::sync::Semaphore::new(64)),
        });
        let cancel = CancellationToken::new();
        let request = Request::builder()
            .uri("/v1/changes")
            .body(Body::empty())
            .unwrap();
        let response = handle(host.clone(), request, cancel.clone(), false)
            .await
            .ok()
            .unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()["Content-Type"], "application/x-ndjson");
        let mut body = response.into_body().into_data_stream();
        let initial: serde_json::Value =
            serde_json::from_slice(&body.next().await.unwrap().unwrap()).unwrap();
        assert_eq!(initial["conversations"].as_object().unwrap().len(), 1);
        cancel.cancel();
        assert!(body.next().await.is_none());
        let request = Request::builder()
            .uri("/v1/conversations")
            .body(Body::empty())
            .unwrap();
        let response = handle(host.clone(), request, CancellationToken::new(), false)
            .await
            .ok()
            .unwrap();
        let actual: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 1_000_000).await.unwrap())
                .unwrap();
        let mut old = serde_json::to_value(conversation.snapshot()).unwrap();
        old.as_object_mut().unwrap().remove("messages");
        old.as_object_mut().unwrap().remove("approval");
        assert_eq!(actual, json!([old]));
        host.options.manager.close().await.unwrap();
    }
}

#[cfg(test)]
#[path = "service/remote_desktop_tests.rs"]
mod remote_desktop_tests;
