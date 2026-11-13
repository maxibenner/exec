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
struct Host {
    options: ServiceOptions,
    stop: CancellationToken,
    handlers: tokio_util::task::TaskTracker,
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
    let images = crate::images::ImageStore::open(profile.join("images")).await?;
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
    manager.attach_native(native);
    match start_service(ServiceOptions {
        manager: manager.clone(),
        provider,
        tools,
        address,
        access,
    })
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
    let listener = tokio::net::TcpListener::bind(options.address).await?;
    let address = listener.local_addr()?;
    let stop = CancellationToken::new();
    let host = Arc::new(Host {
        options,
        stop: stop.clone(),
        handlers: tokio_util::task::TaskTracker::new(),
    });
    let task = tokio::spawn(async move {
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
        async move {
            // Cancel discovery when the caller disconnects, but let accepted
            // catalog mutations finish instead of dropping a durable write.
            let _guard = cancel.clone().drop_guard();
            let response = handlers
                .spawn(async move { dispatch(host, request.map(Body::new), cancel).await })
                .await
                .unwrap_or_else(|_| json_response(500, json!({"error":"Service request failed."})));
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
struct ApiError(u16, &'static str);
type ApiResult<T> = std::result::Result<T, ApiError>;
impl From<Error> for ApiError {
    fn from(error: Error) -> Self {
        match error {
            Error::Busy => Self(409, "Conversation is busy."),
            Error::Invalid(message) => Self(400, message),
            _ => Self(
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
    match handle(host, request, cancel).await {
        Ok(response) => response,
        Err(ApiError(status, error)) => {
            let mut response = json_response(status, json!({"error":error}));
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
async fn body<T: serde::de::DeserializeOwned>(request: Request<Body>) -> ApiResult<T> {
    if request
        .headers()
        .get("content-type")
        .and_then(|h| h.to_str().ok())
        != Some("application/json")
    {
        return Err(ApiError(415, "Use application/json."));
    }
    let bytes = tokio::time::timeout(
        Duration::from_secs(15),
        to_bytes(request.into_body(), 12 * 1024 * 1024),
    )
    .await
    .map_err(|_| ApiError(408, "Request timed out."))?
    .map_err(|_| ApiError(413, "Request is too large."))?;
    serde_json::from_slice(&bytes).map_err(|_| ApiError(400, "Invalid JSON or request fields."))
}
fn identifier(id: &str) -> ApiResult<()> {
    if valid_id(id) {
        Ok(())
    } else {
        Err(ApiError(400, "Invalid identifier."))
    }
}
fn text(value: &str, max: usize) -> ApiResult<()> {
    if value.trim().is_empty() || value.encode_utf16().count() > max || value.contains('\0') {
        Err(ApiError(400, "Invalid string field."))
    } else {
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Create {
    model: Option<String>,
    workspace: String,
    settings: Option<SessionSettings>,
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
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rename {
    title: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SelectModel {
    model: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UploadImage {
    name: String,
    base64: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Submit {
    text: String,
    #[serde(default)]
    images: Vec<ImageRef>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Steer {
    #[serde(rename = "operationID")]
    operation_id: String,
    text: String,
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
async fn handle(
    host: Arc<Host>,
    request: Request<Body>,
    request_cancel: CancellationToken,
) -> ApiResult<Response<Body>> {
    if request.headers().contains_key("origin") || request.headers().contains_key("sec-fetch-site")
    {
        return Err(ApiError(403, "Browser requests are not supported."));
    }
    let native = request.uri().path().starts_with("/v1/native/")
        || (request.method() == "PUT"
            && request.uri().path().starts_with("/v1/conversations/")
            && request.uri().path().ends_with("/desktop"));
    host.options
        .access
        .authorize(request.headers(), native)
        .map_err(|(status, message)| ApiError(status, message))?;
    if host.stop.is_cancelled() {
        return Err(ApiError(503, "Service is stopping."));
    }
    let route = request
        .uri()
        .path_and_query()
        .map(|v| v.as_str())
        .unwrap_or("")
        .to_owned();
    let method = request.method().as_str().to_owned();
    let options = &host.options;
    if method == "POST" && route == "/v1/native/events" {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Register {
            os_screen_permission: bool,
        }
        let input: Register = body(request).await?;
        let mut connection = options
            .manager
            .native()
            .register(input.os_screen_permission)?;
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
        let input: Permission = body(request).await?;
        options
            .manager
            .native()
            .update_os_permission(&input.frontend_id, input.granted)?;
        return Ok(json_response(200, json!({"accepted":true})));
    }
    if method == "POST" && route == "/v1/native/results" {
        let input: crate::native::NativeReply = body(request).await?;
        options.manager.native().reply(input).map_err(|_| {
            ApiError(
                409,
                "Native request is no longer active or does not match this request and action.",
            )
        })?;
        return Ok(json_response(200, json!({"accepted":true})));
    }
    if method == "GET" && route == "/v1/health" {
        return Ok(json_response(
            200,
            json!({"version":1,"toolsEnabled":options.tools.iter().any(|tool| !["web_search", "fetch_content","generate_image","take_screenshot"].contains(&tool.definition().name.as_str()))}),
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
        let models = tokio::select! {biased;_=cancel.cancelled()=>return Err(ApiError(503,"Service is stopping.")),value=tokio::time::timeout(Duration::from_secs(120),options.manager.discover_models(options.provider.clone(), cancel.clone()))=>value.map_err(|_|ApiError(500,"Model discovery failed."))??};
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
        let input: ReadLog = body(request).await?;
        if input.max_bytes == 0 || input.max_bytes > 32768 {
            return Err(ApiError(400, "Read 1–32768 log bytes."));
        }
        let chunk = options
            .manager
            .read_log(id, input.offset, input.max_bytes)
            .await
            .map_err(|error| match error {
                Error::Invalid("Log is not referenced by an available conversation.") => {
                    ApiError(404, "Log not found.")
                }
                Error::Invalid(message) => ApiError(400, message),
                other => ApiError::from(other),
            })?;
        return Ok(json_response(200, chunk));
    }
    if method == "POST" && route == "/v1/fetch" {
        let input: Fetch = body(request).await?;
        crate::content_fetch::public_url(&input.url).map_err(|_| {
            ApiError(
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
        let search: Search = body(request).await?;
        text(&search.model, 128)?;
        search_query(&search.query).map_err(|_| ApiError(400, "Invalid search query."))?;
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
            return Err(ApiError(404, "Provider not found."));
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
        let input: Cancel = body(request).await?;
        identifier(&input.operation_id)?;
        options.manager.cancel_connection(&input.operation_id)?;
        return Ok(json_response(202, json!({"accepted":true})));
    }
    if method == "POST"
        && let Some(id) = route
            .strip_prefix("/v1/providers/")
            .and_then(|s| s.strip_suffix("/connect"))
    {
        let _: Empty = body(request).await?;
        return Ok(json_response(
            202,
            options
                .manager
                .connect(options.provider.clone(), id)
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
            return Err(ApiError(404, "Provider not found."));
        }
        let credential = match method.as_str() {
            "PUT" => Some(body::<Connect>(request).await?.api_key),
            "DELETE" => None,
            _ => return Err(ApiError(404, "Route not found.")),
        };
        let connections = options
            .manager
            .set_credential(options.provider.clone(), id, credential)
            .await
            .map_err(|error| match error {
                Error::Invalid(message) => ApiError(400, message),
                other => ApiError::from(other),
            })?;
        return Ok(json_response(200, connections));
    }
    if route == "/v1/library" {
        return match method.as_str() {
            "GET" => Ok(json_response(200, options.manager.library_configuration()?)),
            "PUT" => {
                let config: LibraryConfiguration = body(request).await?;
                config
                    .validate()
                    .map_err(|_| ApiError(400, "Invalid library configuration."))?;
                Ok(json_response(
                    200,
                    options.manager.update_library(config).await?,
                ))
            }
            _ => Err(ApiError(404, "Route not found.")),
        };
    }
    if route == "/v1/conversations" {
        if method == "GET" {
            let mut summaries: Vec<_> = options
                .manager
                .list()?
                .into_iter()
                .map(|s| {
                    let mut v = serde_json::to_value(s).unwrap();
                    v.as_object_mut().unwrap().remove("messages");
                    v.as_object_mut().unwrap().remove("approval");
                    v
                })
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
            let create: Create = body(request).await?;
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
                )
                .await
                .map_err(|error| match error {
                    Error::Invalid(message) => ApiError(400, message),
                    other => ApiError::from(other),
                })?;
            return Ok(json_response(201, created.snapshot()));
        }
    }
    let Some(tail) = route.strip_prefix("/v1/conversations/") else {
        return Err(ApiError(404, "Route not found."));
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
                Error::Invalid(message) => ApiError(409, message),
                other => other.into(),
            })?;
        return Ok(json_response(200, json!({"released":true})));
    }

    if parts.is_empty()
        || parts.len() > 2
        || parts.get(1).is_some_and(|s| {
            ![
                "events",
                "turns",
                "cancel",
                "approvals",
                "settings",
                "steer",
                "title",
                "model",
                "fork",
                "compact",
                "images",
                "desktop",
            ]
            .contains(s)
        })
    {
        return Err(ApiError(404, "Route not found."));
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
        return Err(ApiError(
            409,
            "Conversation is unreadable. Its file is preserved; inspect it before explicit deletion.",
        ));
    }
    let conversation = options
        .manager
        .get(parts[0])
        .map_err(|_| ApiError(404, "Conversation not found."))?;
    let action = parts.get(1).copied();
    match (method.as_str(), action) {
        ("GET", None) => Ok(json_response(200, conversation.snapshot())),
        ("DELETE", None) => {
            if host.stop.is_cancelled() {
                return Err(ApiError(503, "Service is stopping."));
            }
            if conversation.busy() {
                return Err(ApiError(
                    409,
                    "Cancel and await the active operation before deleting.",
                ));
            }
            options.manager.delete(parts[0]).await?;
            Ok(json_response(200, json!({"deleted":true})))
        }
        ("PUT", Some("title")) => {
            let input: Rename = body(request).await?;
            let metadata = SessionMetadata {
                title: Some(input.title.clone()),
                manually_named: true,
                activity_at: 0,
            };
            metadata
                .validate()
                .map_err(|_| ApiError(400, "Invalid title."))?;
            Ok(json_response(
                200,
                options.manager.rename(parts[0], input.title).await?,
            ))
        }
        ("PUT", Some("model")) => {
            let input: SelectModel = body(request).await?;
            text(&input.model, 128)?;
            Ok(json_response(
                200,
                options.manager.select_model(parts[0], input.model).await?,
            ))
        }
        ("POST", Some("fork")) => {
            let _: Empty = body(request).await?;
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
            let settings: SessionSettings = body(request).await?;
            settings
                .validate()
                .map_err(|_| ApiError(400, "Invalid session settings."))?;
            if host.stop.is_cancelled() {
                return Err(ApiError(503, "Service is stopping."));
            }
            Ok(json_response(
                200,
                options.manager.update_settings(parts[0], settings).await?,
            ))
        }
        ("GET", Some("events")) => {
            let (snapshot, mut receiver) = conversation.subscribe();
            let stop = host.stop.clone();
            let frames = async_stream::stream! {
                yield Ok::<_,std::io::Error>(format!("{}\n",serde_json::to_string(&ServiceEvent::Snapshot{snapshot}).unwrap()));
                loop{
                    let frame=tokio::select!{biased;_=stop.cancelled()=>break,value=receiver.recv()=>value};
                    match frame{
                        Ok(frame)=>yield Ok(format!("{}\n",serde_json::to_string(frame.as_ref()).unwrap())),
                        Err(_)=>{yield Err(std::io::Error::other("Observer disconnected; reconnect for a snapshot."));break;}
                    }
                }
            };
            Ok(Response::builder()
                .status(StatusCode::OK)
                .header("Content-Type", "application/x-ndjson")
                .header("Cache-Control", "no-store")
                .header("X-Content-Type-Options", "nosniff")
                .body(Body::from_stream(frames))
                .unwrap())
        }
        ("POST", Some("turns")) => {
            let submit: Submit = body(request).await?;
            if submit.images.is_empty() {
                text(&submit.text, 128 * 1024)?;
            } else if submit.text.len() > 128 * 1024 || submit.text.contains('\0') {
                return Err(ApiError(400, "Invalid message."));
            }
            if host.stop.is_cancelled() {
                return Err(ApiError(503, "Service is stopping."));
            }
            let run = options
                .manager
                .submit_images(parts[0], submit.text, submit.images)
                .await
                .map_err(|error| match error {
                    Error::Invalid(message) => ApiError(400, message),
                    Error::Storage => ApiError(409, "Conversation requires storage recovery."),
                    other => ApiError::from(other),
                })?;
            Ok(json_response(202, json!({"operationID":run.operation_id})))
        }
        ("POST", Some("compact")) => {
            let _: Empty = body(request).await?;
            let run = options.manager.compact(parts[0])?;
            Ok(json_response(202, json!({"operationID":run.operation_id})))
        }
        ("GET", Some("desktop")) => Ok(json_response(
            200,
            options.manager.desktop_permission(parts[0])?,
        )),
        ("PUT", Some("desktop")) => {
            let input: crate::native::DesktopPermission = body(request).await?;
            Ok(json_response(
                200,
                options.manager.set_desktop_permission(parts[0], input)?,
            ))
        }
        ("POST", Some("images")) => {
            let input: UploadImage = body(request).await?;
            let bytes = crate::images::decode_base64(&input.base64)
                .map_err(|_| ApiError(400, "Invalid image data."))?;
            let image = options
                .manager
                .upload_image(parts[0], input.name, bytes)
                .await?;
            Ok(json_response(201, image))
        }
        ("POST", Some("steer")) => {
            let input: Steer = body(request).await?;
            identifier(&input.operation_id)?;
            text(&input.text, 128 * 1024)?;
            let id = options
                .manager
                .steer(parts[0], &input.operation_id, input.text)?;
            Ok(json_response(
                202,
                json!({"operationID":input.operation_id,"messageID":id}),
            ))
        }
        ("POST", Some("cancel")) => {
            let cancel: Cancel = body(request).await?;
            identifier(&cancel.operation_id)?;
            if !conversation.cancel(&cancel.operation_id) {
                return Err(ApiError(409, "Operation is no longer cancellable."));
            }
            Ok(json_response(
                202,
                json!({"accepted":true,"operationID":cancel.operation_id}),
            ))
        }
        ("POST", Some("approvals")) => {
            let resolve: Resolve = body(request).await?;
            identifier(&resolve.operation_id)?;
            identifier(&resolve.approval_id)?;
            if !conversation.resolve_approval(
                &resolve.operation_id,
                &resolve.approval_id,
                resolve.approved,
            ) {
                return Err(ApiError(409, "Approval is stale or already resolved."));
            }
            Ok(json_response(200, json!({"resolved":true})))
        }
        _ => Err(ApiError(405, "Method not allowed.")),
    }
}
