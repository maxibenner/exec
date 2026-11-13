use crate::{Error, Result, core::*, storage::ConversationStore};
use std::{
    collections::{BTreeMap, HashSet},
    sync::{Arc, Mutex},
};

#[derive(Default)]
struct Catalog {
    conversations: BTreeMap<String, Arc<Conversation>>,
    mutating: HashSet<String>,
    closed: bool,
}
pub struct AgentManager {
    catalog: Mutex<Catalog>,
    store: Option<Arc<dyn ConversationStore>>,
}
impl Default for AgentManager {
    fn default() -> Self {
        Self {
            catalog: Mutex::new(Catalog::default()),
            store: None,
        }
    }
}
impl AgentManager {
    pub async fn open(
        store: Arc<dyn ConversationStore>,
        configure: impl Fn(&ConversationRecord) -> (Arc<dyn ChatProvider>, Vec<Arc<dyn Tool>>),
    ) -> Result<Arc<Self>> {
        let manager = Arc::new(Self {
            catalog: Mutex::new(Catalog::default()),
            store: Some(store.clone()),
        });
        let restore = async {
            for record in store.load().await? {
                let (provider, tools) = configure(&record);
                let mut options = ConversationOptions::new(
                    provider,
                    record.model.clone(),
                    record.workspace.clone(),
                );
                options.tools = tools;
                options.checkpoint = Some(store.clone());
                let active = record.operation.as_ref().is_some_and(|o| o.state.active());
                let conversation = Conversation::new(options, Some(record))?;
                if active {
                    store.save(conversation.record()).await?;
                }
                manager
                    .catalog
                    .lock()
                    .unwrap()
                    .conversations
                    .insert(conversation.id.clone(), conversation);
            }
            Ok::<_, Error>(())
        }
        .await;
        if restore.is_err() {
            let _ = store.close().await;
            return Err(Error::Invalid(
                "Could not restore conversations. No work was resumed; inspect the profile before continuing.",
            ));
        }
        Ok(manager)
    }
    pub async fn create(&self, mut options: ConversationOptions) -> Result<Arc<Conversation>> {
        if let Some(store) = &self.store {
            options.checkpoint = Some(store.clone());
        }
        let conversation = Conversation::new(options, None)?;
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed {
                return Err(Error::Invalid("Agent manager is closed."));
            }
            c.mutating.insert(conversation.id.clone());
        }
        let saved = if let Some(store) = &self.store {
            store.save(conversation.record()).await
        } else {
            Ok(())
        };
        let mut c = self.catalog.lock().unwrap();
        c.mutating.remove(&conversation.id);
        if let Err(error) = saved {
            conversation.dispose()?;
            return Err(error);
        }
        c.conversations
            .insert(conversation.id.clone(), conversation.clone());
        Ok(conversation)
    }
    /// Load project instructions only for the first accepted turn, then freeze them.
    /// The runner atomically accepts input and persists the snapshot before inference.
    pub async fn submit(&self, id: &str, text: String) -> Result<Submission> {
        let conversation = self.get(id)?;
        if conversation.busy() {
            return Err(Error::Busy);
        }
        let snapshot = conversation.snapshot();
        let instructions = if snapshot.configuration.instructions_frozen {
            None
        } else {
            crate::workspace_instructions::load(snapshot.workspace).await?
        };
        conversation.submit_with_instructions(text, instructions)
    }
    pub async fn update_settings(
        &self,
        id: &str,
        settings: SessionSettings,
    ) -> Result<ConversationSnapshot> {
        self.get(id)?.update_settings(settings).await
    }
    pub fn get(&self, id: &str) -> Result<Arc<Conversation>> {
        let c = self.catalog.lock().unwrap();
        if c.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        if c.mutating.contains(id) {
            return Err(Error::Invalid("Conversation catalog operation is pending."));
        }
        c.conversations
            .get(id)
            .cloned()
            .ok_or(Error::Invalid("Conversation not found."))
    }
    pub fn list(&self) -> Result<Vec<ConversationSnapshot>> {
        let c = self.catalog.lock().unwrap();
        if c.closed {
            return Err(Error::Invalid("Agent manager is closed."));
        }
        Ok(c.conversations.values().map(|c| c.snapshot()).collect())
    }
    pub async fn delete(&self, id: &str) -> Result<()> {
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed || c.mutating.contains(id) {
                return Err(Error::Internal);
            }
            let conversation = c
                .conversations
                .get(id)
                .ok_or(Error::Invalid("Conversation not found."))?;
            conversation.dispose()?;
            c.mutating.insert(id.into());
        }
        let deleted = if let Some(store) = &self.store {
            store.delete(id.into()).await
        } else {
            Ok(())
        };
        let mut c = self.catalog.lock().unwrap();
        c.mutating.remove(id);
        deleted?;
        c.conversations.remove(id);
        Ok(())
    }
    pub async fn close(&self) -> Result<()> {
        {
            let mut c = self.catalog.lock().unwrap();
            if c.closed {
                return Err(Error::Invalid("Agent manager is closed."));
            }
            if !c.mutating.is_empty() || c.conversations.values().any(|c| c.busy()) {
                return Err(Error::Invalid(
                    "Stop and await active conversations/catalog operations before closing the manager.",
                ));
            }
            // Holding the catalog lock excludes catalog operations. dispose also atomically excludes submissions through retained references.
            for conversation in c.conversations.values() {
                conversation.dispose()?;
            }
            c.closed = true;
        }
        if let Some(store) = &self.store {
            store.close().await?;
        }
        Ok(())
    }
    pub async fn cancel_and_wait(&self) -> Result<()> {
        let conversations: Vec<_> = self
            .catalog
            .lock()
            .unwrap()
            .conversations
            .values()
            .cloned()
            .collect();
        for conversation in &conversations {
            if let Some(op) = conversation.snapshot().operation {
                conversation.cancel(&op.id);
            }
        }
        for conversation in conversations {
            let (_, mut events) = conversation.subscribe();
            while conversation.busy() {
                if events.recv().await.is_err() {
                    events = conversation.subscribe().1;
                }
            }
        }
        Ok(())
    }
}
