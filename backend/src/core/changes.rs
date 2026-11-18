use super::new_id;
use serde::Serialize;
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
use tokio::sync::watch;

/// Invalidation hints, not a replay log. Revisions are strings for lossless clients.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ChangeNotification {
    pub epoch: String,
    pub catalog: String,
    pub conversations: BTreeMap<String, String>,
}

struct HubState {
    sender: watch::Sender<ChangeNotification>,
    serial: u64,
    instances: BTreeMap<String, String>,
}

/// Lock order: manager catalog -> conversation state -> hub. Never read state
/// while holding a watch borrow. Updates mutate one watch value, not a queue/map
/// clone per token; slow consumers retain only the latest revision map.
pub(crate) struct ChangeHub(Mutex<HubState>);
impl Default for ChangeHub {
    fn default() -> Self {
        let (sender, _) = watch::channel(ChangeNotification {
            epoch: new_id(),
            catalog: "0".into(),
            conversations: BTreeMap::new(),
        });
        Self(Mutex::new(HubState {
            sender,
            serial: 0,
            instances: BTreeMap::new(),
        }))
    }
}
impl ChangeHub {
    pub(crate) fn subscribe(&self) -> watch::Receiver<ChangeNotification> {
        self.0.lock().unwrap().sender.subscribe()
    }
    pub(crate) fn attach(self: &Arc<Self>, id: &str) -> ChangeRegistration {
        let instance = new_id();
        let mut state = self.0.lock().unwrap();
        state.instances.insert(id.into(), instance.clone());
        state.serial += 1;
        let revision = state.serial.to_string();
        state.sender.send_modify(|value| {
            value.catalog = revision.clone();
            value.conversations.insert(id.into(), revision);
        });
        ChangeRegistration {
            hub: self.clone(),
            id: id.into(),
            instance,
        }
    }
    pub(crate) fn catalog_changed(&self) {
        let mut state = self.0.lock().unwrap();
        state.serial += 1;
        let revision = state.serial.to_string();
        state.sender.send_modify(|value| value.catalog = revision);
    }
    /// Model discovery/authentication can change provider-derived snapshot fields
    /// without touching a conversation record. These infrequent operations must
    /// invalidate cached clients too (including conversations created during them).
    pub(crate) fn provider_metadata_changed(&self) {
        let mut state = self.0.lock().unwrap();
        state.serial += 1;
        let revision = state.serial.to_string();
        state.sender.send_modify(|value| {
            value.catalog = revision.clone();
            for conversation in value.conversations.values_mut() {
                *conversation = revision.clone();
            }
        });
    }
    pub(crate) fn remove(&self, id: &str) {
        let mut state = self.0.lock().unwrap();
        state.instances.remove(id);
        state.serial += 1;
        let revision = state.serial.to_string();
        state.sender.send_modify(|value| {
            value.catalog = revision;
            value.conversations.remove(id);
        });
    }
}
pub(crate) struct ChangeRegistration {
    hub: Arc<ChangeHub>,
    id: String,
    instance: String,
}
impl ChangeRegistration {
    pub(super) fn changed(&self, catalog: bool) {
        let mut state = self.hub.0.lock().unwrap();
        // A retained handle to a deleted/replaced conversation cannot resurrect it.
        if state.instances.get(&self.id) != Some(&self.instance) {
            return;
        }
        state.serial += 1;
        let revision = state.serial.to_string();
        state.sender.send_modify(|value| {
            if catalog {
                value.catalog = revision.clone();
            }
            value.conversations.insert(self.id.clone(), revision);
        });
    }
}
