//! Optional native capture broker. No capture implementation or fallback exists here.
//! HTTP registration requires the independently provisioned native capability.
//! TCP does not attest process identity. OS permission and session enablement remain explicit.
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
    os_permission: bool,
    requests: mpsc::Sender<NativeEvent>,
}
struct Pending {
    request: NativeRequest,
    result: oneshot::Sender<NativePayload>,
}
#[derive(Default)]
struct State {
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
    pub(crate) fn register(self: &Arc<Self>, os_permission: bool) -> Result<NativeConnection> {
        let mut s = self.state.lock().unwrap();
        if s.frontends.len() >= 8 {
            return Err(Error::Busy);
        }
        let id = new_id();
        let (tx, requests) = mpsc::channel(16);
        s.frontends.insert(
            id.clone(),
            Frontend {
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
    pub(crate) fn update_os_permission(&self, id: &str, granted: bool) -> Result<()> {
        let mut s = self.state.lock().unwrap();
        let frontend = s
            .frontends
            .get_mut(id)
            .ok_or(Error::Invalid("Native frontend not found."))?;
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
    pub(crate) fn reply(&self, reply: NativeReply) -> Result<()> {
        let mut s = self.state.lock().unwrap();
        let pending = s.pending.get(&reply.request.id).ok_or(Error::Invalid(
            "Native request expired or was already answered.",
        ))?;
        if pending.request != reply.request
            || s.frontends
                .get(&reply.request.frontend_id)
                .is_none_or(|f| !f.os_permission)
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
    async fn only_exact_live_request_can_answer() {
        let hub = Arc::new(NativeHub::default());

        let mut native = hub.register(true).unwrap();
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
            hub.reply(NativeReply {
                request: wrong,
                result: NativePayload::Windows { windows: vec![] }
            })
            .is_err()
        );
        hub.reply(NativeReply {
            request: request.clone(),
            result: NativePayload::Windows { windows: vec![] },
        })
        .unwrap();
        assert!(task.await.unwrap().is_ok());
        assert!(
            hub.reply(NativeReply {
                request,
                result: NativePayload::Failed
            })
            .is_err()
        );
    }
    #[tokio::test]
    async fn cancellation_disconnect_and_permission_never_fall_back() {
        for mode in 0..3 {
            let hub = Arc::new(NativeHub::default());

            let mut native = hub.register(mode != 2).unwrap();
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
                hub.reply(NativeReply {
                    request,
                    result: NativePayload::Failed
                })
                .is_err()
            );
        }
    }
}
