use crate::{
    Error, Result, core::*, manager::AgentManager, storage::JsonConversationStore,
    tools::create_workspace_tools,
};
use axum::{
    body::{Body, to_bytes},
    http::{Request, Response, StatusCode},
};
use serde::Deserialize;
use serde_json::json;
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
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
pub fn profile_socket(profile: &Path) -> PathBuf {
    profile.join("service.sock")
}
pub struct ServiceOptions {
    pub manager: Arc<AgentManager>,
    pub provider: Arc<dyn ChatProvider>,
    pub tools: Vec<Arc<dyn Tool>>,
    pub socket_path: PathBuf,
}
struct Host {
    options: ServiceOptions,
    stop: CancellationToken,
    handlers: tokio_util::task::TaskTracker,
}
pub struct Service {
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
) -> Result<Service> {
    let profile = private_directory(profile).await?;
    let tools = if workspace_tools {
        create_workspace_tools()
    } else {
        vec![]
    };
    let store = JsonConversationStore::open(profile.join("conversations")).await?;
    let manager = AgentManager::open(store, |_| (provider.clone(), tools.clone())).await?;
    match start_service(ServiceOptions {
        manager: manager.clone(),
        provider,
        tools,
        socket_path: profile_socket(&profile),
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
    use std::os::unix::ffi::OsStrExt;
    if !options.socket_path.is_absolute() || options.socket_path.as_os_str().as_bytes().len() > 100
    {
        return Err(Error::Invalid(
            "Socket path must be absolute and at most 100 bytes.",
        ));
    }
    private_directory(options.socket_path.parent().ok_or(Error::Internal)?).await?;
    // bind refuses existing endpoints; never unlink a stale socket on startup.
    let listener = tokio::net::UnixListener::bind(&options.socket_path)?;
    if fs::set_permissions(&options.socket_path, fs::Permissions::from_mode(0o600)).is_err() {
        let _ = fs::remove_file(&options.socket_path);
        return Err(Error::Internal);
    }
    let identity = fs::symlink_metadata(&options.socket_path)?;
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
        let closed = host.options.manager.close().await;
        if fs::symlink_metadata(&host.options.socket_path)
            .is_ok_and(|m| crate::storage::same_file(&m, &identity))
        {
            let _ = fs::remove_file(&host.options.socket_path);
        }
        closed
    });
    Ok(Service {
        stop,
        task: Some(task),
    })
}
async fn serve_connection(
    host: Arc<Host>,
    socket: tokio::net::UnixStream,
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
        if error == Error::Busy {
            return Self(409, "Conversation is busy.");
        }
        Self(
            500,
            "Service request failed. Inspect conversation state before continuing.",
        )
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
        Err(ApiError(status, error)) => json_response(status, json!({"error":error})),
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
        to_bytes(request.into_body(), 256 * 1024),
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
struct Submit {
    text: String,
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
    if method == "GET" && route == "/v1/health" {
        return Ok(json_response(
            200,
            json!({"version":1,"toolsEnabled":!options.tools.is_empty()}),
        ));
    }
    if method == "GET" && route == "/v1/models" {
        let cancel = request_cancel.child_token();
        let _guard = cancel.clone().drop_guard();
        let models = tokio::select! {biased;_=cancel.cancelled()=>return Err(ApiError(503,"Service is stopping.")),value=tokio::time::timeout(Duration::from_secs(120),options.provider.models(cancel.clone()))=>value.map_err(|_|ApiError(500,"Model discovery failed."))??};
        return Ok(json_response(200, models));
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
            let summaries: Vec<_> = options
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
            ]
            .contains(s)
        })
    {
        return Err(ApiError(404, "Route not found."));
    }
    identifier(parts[0])?;
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
            text(&submit.text, 128 * 1024)?;
            if host.stop.is_cancelled() {
                return Err(ApiError(503, "Service is stopping."));
            }
            let run = options
                .manager
                .submit(parts[0], submit.text)
                .await
                .map_err(|error| match error {
                    Error::Invalid(message) => ApiError(400, message),
                    Error::Storage => ApiError(409, "Conversation requires storage recovery."),
                    other => ApiError::from(other),
                })?;
            Ok(json_response(202, json!({"operationID":run.operation_id})))
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
