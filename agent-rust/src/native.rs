//! Optional native capture broker. No capture implementation or fallback exists here.
//! Eligibility is granted by trusted host composition, never by an HTTP client's claim.
use crate::{
    Error, Result,
    core::{ToolContext, new_id, valid_id},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CaptureTarget {
    Desktop,
    ListWindows,
    Window,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeAction {
    pub target: CaptureTarget,
    #[serde(rename = "windowID")]
    pub window_id: Option<u32>,
}
impl NativeAction {
    pub fn validate(&self) -> Result<()> {
        if (self.target == CaptureTarget::Window) != self.window_id.is_some_and(|n| n > 0) {
            return Err(Error::Invalid(
                "A window target requires its positive window ID; other targets take no window ID.",
            ));
        }
        Ok(())
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeRequest {
    pub id: String,
    #[serde(rename = "frontendID")]
    pub frontend_id: String,
    #[serde(rename = "conversationID")]
    pub conversation_id: String,
    #[serde(rename = "operationID")]
    pub operation_id: String,
    #[serde(rename = "callID")]
    pub call_id: String,
    pub action: NativeAction,
}
pub use crate::core::WindowInfo as NativeWindow;
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum NativePayload {
    Windows { windows: Vec<NativeWindow> },
    Image { base64: String },
    Failed,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeReply {
    pub request: NativeRequest,
    pub result: NativePayload,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DesktopPermission {
    #[serde(rename = "frontendID")]
    pub frontend_id: Option<String>,
    pub enabled: bool,
}
struct Frontend {
    pid: u32,
    os_permission: bool,
    requests: mpsc::Sender<NativeEvent>,
}
struct Pending {
    request: NativeRequest,
    result: oneshot::Sender<NativePayload>,
}
#[derive(Default)]
struct State {
    eligible: HashMap<u32, (u64, u64)>,
    windows: HashMap<(String, String), std::collections::HashSet<u32>>,
    frontends: HashMap<String, Frontend>,
    permissions: HashMap<String, String>,
    pending: HashMap<String, Pending>,
}
impl State {
    fn cancel_where(&mut self, predicate: impl Fn(&NativeRequest) -> bool) {
        let ids: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, p)| predicate(&p.request))
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            if let Some(pending) = self.pending.remove(&id)
                && let Some(frontend) = self.frontends.get(&pending.request.frontend_id)
            {
                let _ = frontend.requests.try_send(NativeEvent::Cancelled {
                    request: pending.request,
                });
            }
        }
    }
}
struct RequestGuard<'a> {
    hub: &'a NativeHub,
    id: String,
}
impl Drop for RequestGuard<'_> {
    fn drop(&mut self) {
        self.hub
            .state
            .lock()
            .unwrap()
            .cancel_where(|r| r.id == self.id);
    }
}
#[derive(Default)]
pub struct NativeHub {
    state: Mutex<State>,
}
pub struct NativeConnection {
    pub id: String,
    pub requests: mpsc::Receiver<NativeEvent>,
    hub: Arc<NativeHub>,
}
impl Drop for NativeConnection {
    fn drop(&mut self) {
        self.hub.disconnect(&self.id);
    }
}
impl NativeHub {
    /// Only trusted host startup/embedding may nominate its Swift frontend process.
    /// Registration still requires kernel-attested peer PID and a live channel.
    pub fn allow_local_frontend(&self, pid: u32) -> Result<()> {
        if pid == 0 {
            return Err(Error::Invalid("A local frontend PID is required."));
        }
        let identity = process_identity(pid).ok_or(Error::Invalid(
            "The nominated local frontend process is unavailable.",
        ))?;
        self.state.lock().unwrap().eligible.insert(pid, identity);
        Ok(())
    }
    pub(crate) fn register(
        self: &Arc<Self>,
        peer_pid: u32,
        os_permission: bool,
    ) -> Result<NativeConnection> {
        let mut s = self.state.lock().unwrap();
        if s.eligible
            .remove(&peer_pid)
            .is_none_or(|identity| Some(identity) != process_identity(peer_pid))
        {
            return Err(Error::Invalid(
                "This peer was not authorized as the local Swift frontend by the host.",
            ));
        }
        // Authorization is single-use: PID reuse or a reconnect cannot inherit permission.
        if s.frontends.len() >= 8 {
            return Err(Error::Busy);
        }
        let id = new_id();
        let (tx, requests) = mpsc::channel(16);
        s.frontends.insert(
            id.clone(),
            Frontend {
                pid: peer_pid,
                os_permission,
                requests: tx,
            },
        );
        Ok(NativeConnection {
            id,
            requests,
            hub: self.clone(),
        })
    }
    pub(crate) fn update_os_permission(
        &self,
        peer_pid: u32,
        id: &str,
        granted: bool,
    ) -> Result<()> {
        let mut s = self.state.lock().unwrap();
        let frontend = s
            .frontends
            .get_mut(id)
            .filter(|f| f.pid == peer_pid)
            .ok_or(Error::Invalid("Native frontend not found for this peer."))?;
        frontend.os_permission = granted;
        if !granted {
            s.permissions.retain(|_, frontend| frontend != id);
            s.windows.retain(|(frontend, _), _| frontend != id);
            s.cancel_where(|request| request.frontend_id == id);
        }
        Ok(())
    }
    pub fn permission(&self, conversation: &str) -> DesktopPermission {
        let s = self.state.lock().unwrap();
        DesktopPermission {
            frontend_id: s.permissions.get(conversation).cloned(),
            enabled: s.permissions.contains_key(conversation),
        }
    }
    pub fn set_permission(&self, conversation: &str, permission: DesktopPermission) -> Result<()> {
        if !valid_id(conversation) {
            return Err(Error::Invalid("Invalid conversation ID."));
        }
        let mut s = self.state.lock().unwrap();
        if permission.enabled {
            let id = permission
                .frontend_id
                .ok_or(Error::Invalid("Select one eligible native frontend."))?;
            if s.frontends
                .get(&id)
                .is_none_or(|f| !f.os_permission || f.requests.is_closed())
            {
                return Err(Error::Invalid("Native screen permission is not available."));
            }
            if s.permissions
                .get(conversation)
                .is_some_and(|current| current != &id)
            {
                s.cancel_where(|request| request.conversation_id == conversation);
            }
            s.permissions.insert(conversation.into(), id);
        } else {
            s.permissions.remove(conversation);
            s.windows.retain(|(_, session), _| session != conversation);
            s.cancel_where(|request| request.conversation_id == conversation);
        }
        Ok(())
    }
    pub fn bound_frontend(&self, conversation: &str) -> Result<String> {
        let s = self.state.lock().unwrap();
        let id = s.permissions.get(conversation).ok_or(Error::Invalid(
            "Desktop access is disabled for this conversation.",
        ))?;
        if s.frontends
            .get(id)
            .is_none_or(|f| !f.os_permission || f.requests.is_closed())
        {
            return Err(Error::Invalid(
                "The selected native frontend is unavailable.",
            ));
        }
        Ok(id.clone())
    }
    pub fn remove_session(&self, conversation: &str) {
        let mut s = self.state.lock().unwrap();
        s.permissions.remove(conversation);
        s.windows.retain(|(_, session), _| session != conversation);
        s.cancel_where(|request| request.conversation_id == conversation);
    }
    fn disconnect(&self, id: &str) {
        let mut s = self.state.lock().unwrap();
        s.frontends.remove(id);
        s.windows.retain(|(frontend, _), _| frontend != id);
        s.permissions.retain(|_, frontend| frontend != id);
        s.cancel_where(|request| request.frontend_id == id);
    }
    pub(crate) fn reply(&self, peer_pid: u32, reply: NativeReply) -> Result<()> {
        let mut s = self.state.lock().unwrap();
        let pending = s.pending.get(&reply.request.id).ok_or(Error::Invalid(
            "Native request expired or was already answered.",
        ))?;
        if pending.request != reply.request
            || s.frontends
                .get(&reply.request.frontend_id)
                .is_none_or(|f| f.pid != peer_pid || !f.os_permission)
            || s.permissions.get(&reply.request.conversation_id) != Some(&reply.request.frontend_id)
        {
            return Err(Error::Invalid(
                "Native response does not match its live request.",
            ));
        }
        match (&reply.request.action.target, &reply.result) {
            (CaptureTarget::ListWindows, NativePayload::Windows { windows }) => {
                let mut ids = std::collections::HashSet::new();
                if windows.len() > 256
                    || windows.iter().any(|w| {
                        w.id == 0
                            || w.title.len() > 1024
                            || w.title.contains('\0')
                            || !ids.insert(w.id)
                    })
                {
                    return Err(Error::Invalid("Invalid window list."));
                }
            }
            (CaptureTarget::Desktop | CaptureTarget::Window, NativePayload::Image { base64 })
                if base64.len() <= 12 * 1024 * 1024 => {}
            (_, NativePayload::Failed) => {}
            _ => return Err(Error::Invalid("Unexpected native response type.")),
        }
        if let NativePayload::Windows { windows } = &reply.result {
            s.windows.insert(
                (
                    reply.request.frontend_id.clone(),
                    reply.request.conversation_id.clone(),
                ),
                windows.iter().map(|w| w.id).collect(),
            );
        }
        let pending = s.pending.remove(&reply.request.id).unwrap();
        pending
            .result
            .send(reply.result)
            .map_err(|_| Error::Invalid("Native request is no longer active."))
    }
    pub async fn request(
        &self,
        frontend_id: String,
        action: NativeAction,
        context: &ToolContext,
    ) -> Result<NativePayload> {
        action.validate()?;
        crate::check_cancel(&context.cancel)?;
        let request = NativeRequest {
            id: new_id(),
            frontend_id: frontend_id.clone(),
            conversation_id: context.conversation_id.clone(),
            operation_id: context.operation_id.clone(),
            call_id: context.call_id.clone(),
            action,
        };
        let (tx, rx) = oneshot::channel();
        {
            let mut s = self.state.lock().unwrap();
            if s.pending.len() >= 64 {
                return Err(Error::Busy);
            }
            if s.permissions.get(&context.conversation_id) != Some(&frontend_id) {
                return Err(Error::Invalid(
                    "The prepared native target is no longer enabled.",
                ));
            }
            if request.action.target == CaptureTarget::Window
                && !s
                    .windows
                    .get(&(frontend_id.clone(), context.conversation_id.clone()))
                    .is_some_and(|windows| windows.contains(&request.action.window_id.unwrap_or(0)))
            {
                return Err(Error::Invalid(
                    "Enumerate windows through this frontend and conversation before selecting a window.",
                ));
            }
            let frontend = s
                .frontends
                .get(&frontend_id)
                .filter(|f| f.os_permission)
                .ok_or(Error::Invalid("Native frontend disconnected."))?;
            frontend
                .requests
                .try_send(NativeEvent::Request {
                    request: request.clone(),
                })
                .map_err(|_| {
                    Error::Invalid("Native frontend is unavailable; no fallback was attempted.")
                })?;
            s.pending.insert(
                request.id.clone(),
                Pending {
                    request: request.clone(),
                    result: tx,
                },
            );
        }
        let _guard = RequestGuard {
            hub: self,
            id: request.id.clone(),
        };
        let result = tokio::select! {biased;_=context.cancel.cancelled()=>Err(Error::Cancelled),r=tokio::time::timeout(Duration::from_secs(60),rx)=>r.map_err(|_|Error::Invalid("Native capture timed out; no retry was made.")).and_then(|r|r.map_err(|_|Error::Invalid("Native frontend disconnected or permission was withdrawn.")))};
        result
    }
}
fn process_identity(pid: u32) -> Option<(u64, u64)> {
    #[cfg(target_os = "macos")]
    {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of_val(&info);
        let result = unsafe {
            libc::proc_pidinfo(
                i32::try_from(pid).ok()?,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                size as i32,
            )
        };
        if result as usize == size && info.pbi_uid == unsafe { libc::getuid() } {
            Some((info.pbi_start_tvsec, info.pbi_start_tvusec))
        } else {
            None
        }
    }
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::MetadataExt;
        let path = format!("/proc/{pid}/stat");
        if std::fs::metadata(&path).ok()?.uid() != unsafe { libc::getuid() } {
            return None;
        }
        let text = std::fs::read_to_string(path).ok()?;
        let rest = text.rsplit_once(')')?.1;
        Some((rest.split_whitespace().nth(19)?.parse().ok()?, 0))
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = pid;
        None
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NativeEvent {
    Registered {
        #[serde(rename = "frontendID")]
        frontend_id: String,
    },
    Request {
        request: NativeRequest,
    },
    Cancelled {
        request: NativeRequest,
    },
    Ping,
}
/// The kernel, not a client-supplied field, identifies a same-host Unix peer.
pub(crate) fn peer_pid(stream: &tokio::net::UnixStream) -> Option<u32> {
    #[cfg(target_os = "macos")]
    {
        use std::os::fd::AsRawFd;
        let mut pid: libc::pid_t = 0;
        let mut len = std::mem::size_of_val(&pid) as libc::socklen_t;
        let result = unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_LOCAL,
                libc::LOCAL_PEERPID,
                (&mut pid as *mut libc::pid_t).cast(),
                &mut len,
            )
        };
        if result == 0 && pid > 0 && len as usize == std::mem::size_of_val(&pid) {
            return Some(pid as u32);
        }
        None
    }
    #[cfg(target_os = "linux")]
    {
        stream
            .peer_cred()
            .ok()?
            .pid()
            .and_then(|p| u32::try_from(p).ok())
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = stream;
        None
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::*;
    use tokio_util::sync::CancellationToken;
    fn context() -> ToolContext {
        ToolContext {
            conversation_id: new_id(),
            operation_id: new_id(),
            call_id: "call".into(),
            model: "m".into(),
            search_model: None,
            workspace: "/".into(),
            cancel: CancellationToken::new(),
        }
    }
    #[tokio::test]
    async fn only_exact_live_peer_and_request_can_answer() {
        let hub = Arc::new(NativeHub::default());
        assert!(hub.register(std::process::id(), true).is_err());
        hub.allow_local_frontend(std::process::id()).unwrap();
        let mut native = hub.register(std::process::id(), true).unwrap();
        let c = context();
        hub.set_permission(
            &c.conversation_id,
            DesktopPermission {
                frontend_id: Some(native.id.clone()),
                enabled: true,
            },
        )
        .unwrap();
        let task = {
            let h = hub.clone();
            let id = native.id.clone();
            let c = c.clone();
            tokio::spawn(async move {
                h.request(
                    id,
                    NativeAction {
                        target: CaptureTarget::ListWindows,
                        window_id: None,
                    },
                    &c,
                )
                .await
            })
        };
        let request = match native.requests.recv().await.unwrap() {
            NativeEvent::Request { request } => request,
            _ => panic!("missing request"),
        };
        let mut wrong = request.clone();
        wrong.operation_id = new_id();
        assert!(
            hub.reply(
                std::process::id(),
                NativeReply {
                    request: wrong,
                    result: NativePayload::Windows { windows: vec![] }
                }
            )
            .is_err()
        );
        assert!(
            hub.reply(
                8,
                NativeReply {
                    request: request.clone(),
                    result: NativePayload::Windows { windows: vec![] }
                }
            )
            .is_err()
        );
        hub.reply(
            std::process::id(),
            NativeReply {
                request: request.clone(),
                result: NativePayload::Windows { windows: vec![] },
            },
        )
        .unwrap();
        assert!(task.await.unwrap().is_ok());
        assert!(
            hub.reply(
                std::process::id(),
                NativeReply {
                    request,
                    result: NativePayload::Failed
                }
            )
            .is_err()
        );
    }
    #[tokio::test]
    async fn cancellation_disconnect_and_permission_never_fall_back() {
        for mode in 0..3 {
            let hub = Arc::new(NativeHub::default());
            hub.allow_local_frontend(std::process::id()).unwrap();
            let mut native = hub.register(std::process::id(), mode != 2).unwrap();
            let c = context();
            let enabled = DesktopPermission {
                frontend_id: Some(native.id.clone()),
                enabled: true,
            };
            if mode == 2 {
                assert!(hub.set_permission(&c.conversation_id, enabled).is_err());
                continue;
            }
            hub.set_permission(&c.conversation_id, enabled).unwrap();
            let task = {
                let h = hub.clone();
                let id = native.id.clone();
                let c = c.clone();
                tokio::spawn(async move {
                    h.request(
                        id,
                        NativeAction {
                            target: CaptureTarget::Desktop,
                            window_id: None,
                        },
                        &c,
                    )
                    .await
                })
            };
            let request = match native.requests.recv().await.unwrap() {
                NativeEvent::Request { request } => request,
                _ => panic!("missing request"),
            };
            if mode == 0 {
                c.cancel.cancel();
            } else {
                drop(native);
            }
            assert!(task.await.unwrap().is_err());
            assert!(
                hub.reply(
                    std::process::id(),
                    NativeReply {
                        request,
                        result: NativePayload::Failed
                    }
                )
                .is_err()
            );
        }
    }
}
