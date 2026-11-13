//! Provider-owned routing and discovery. Context is carried by each request, never shared.
use crate::{Error, Result, check_cancel, core::*};
use async_trait::async_trait;
use futures_util::{StreamExt, stream::BoxStream};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
use tokio_util::sync::CancellationToken;
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Contexts {
    registry_version: u32,
    contexts: BTreeMap<String, Value>,
}
#[derive(Default)]
struct Discovery {
    generation: u64,
    models: BTreeMap<String, Vec<ChatModel>>,
    warnings: Vec<String>,
}
pub struct ProviderRegistry {
    default: String,
    providers: BTreeMap<String, Arc<dyn ChatProvider>>,
    discovery: Mutex<Discovery>,
}
impl ProviderRegistry {
    pub fn new(default: &str, entries: Vec<(String, Arc<dyn ChatProvider>)>) -> Result<Self> {
        let mut providers = BTreeMap::new();
        for (id, provider) in entries {
            if id.is_empty()
                || id.len() > 32
                || !id
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                || providers.insert(id, provider).is_some()
            {
                return Err(Error::Invalid("Invalid or duplicate provider ID."));
            }
        }
        if !providers.contains_key(default) || providers.len() > 32 {
            return Err(Error::Invalid("A registered default provider is required."));
        }
        Ok(Self {
            default: default.into(),
            providers,
            discovery: Mutex::new(Discovery::default()),
        })
    }
    fn route(&self, model: &str) -> Result<(String, String, Arc<dyn ChatProvider>)> {
        if !valid_model_id(model) {
            return Err(Error::Invalid("Invalid model."));
        }
        let (id, model) = model.split_once('/').unwrap_or((&self.default, model));
        if model.is_empty() {
            return Err(Error::Invalid("Invalid model."));
        }
        Ok((
            id.into(),
            model.into(),
            self.providers
                .get(id)
                .cloned()
                .ok_or(Error::Invalid("Unknown model provider."))?,
        ))
    }
    fn contexts(&self, state: Option<Value>) -> Result<Contexts> {
        match state {
            None => Ok(Contexts {
                registry_version: 1,
                ..Contexts::default()
            }),
            Some(state) if state.get("registry_version").is_some() => {
                let contexts: Contexts = serde_json::from_value(state)
                    .map_err(|_| Error::Invalid("Invalid provider context."))?;
                if contexts.registry_version != 1 || contexts.contexts.len() > 32 {
                    return Err(Error::Invalid("Unsupported provider context."));
                }
                Ok(contexts)
            }
            Some(state) => Ok(Contexts {
                registry_version: 1,
                contexts: BTreeMap::from([(self.default.clone(), state)]),
            }),
        }
    }
}
#[async_trait]
impl ChatProvider for ProviderRegistry {
    fn connections(&self) -> Vec<ProviderConnection> {
        self.providers
            .values()
            .flat_map(|p| p.connections())
            .collect()
    }
    fn model_warnings(&self) -> Vec<String> {
        self.discovery.lock().unwrap().warnings.clone()
    }
    fn supports_web_search(&self) -> bool {
        self.providers.values().any(|p| p.supports_web_search())
    }
    async fn set_credential(&self, id: &str, credential: Option<String>) -> Result<()> {
        let provider = self
            .providers
            .get(id)
            .ok_or(Error::Invalid("Unknown provider."))?;
        {
            let mut discovery = self.discovery.lock().unwrap();
            discovery.generation = discovery.generation.wrapping_add(1);
            discovery.models.remove(id);
            discovery.warnings.clear();
        }
        let result = provider.set_credential(id, credential).await;
        {
            let mut discovery = self.discovery.lock().unwrap();
            discovery.generation = discovery.generation.wrapping_add(1);
            discovery.models.remove(id);
            discovery.warnings.clear();
        }
        result
    }
    async fn search_web(
        &self,
        model: &str,
        query: String,
        cancel: CancellationToken,
    ) -> Result<WebSearchResult> {
        let (_, model, provider) = self.route(model)?;
        provider.search_web(&model, query, cancel).await
    }
    async fn account_balances(
        &self,
        id: &str,
        cancel: CancellationToken,
    ) -> Result<Vec<AccountBalance>> {
        self.providers
            .get(id)
            .ok_or(Error::Invalid("Unknown provider."))?
            .account_balances(id, cancel)
            .await
    }
    fn stream(&self, mut request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        let prepared = (|| {
            let (id, model, provider) = self.route(&request.model)?;
            let contexts = self.contexts(request.provider_state.take())?;
            Ok::<_, Error>((id, model, provider, contexts))
        })();
        Box::pin(async_stream::try_stream! {
            let (id,model,provider,mut contexts) = prepared?;
            request.model = model; request.provider_state = contexts.contexts.get(&id).cloned();
            let cancel = request.cancel.clone(); check_cancel(&cancel)?;
            let mut source = provider.stream(request);
            while let Some(event) = source.next().await {
                check_cancel(&cancel)?;
                match event? {
                    ProviderEvent::Metadata { state, usage } => {
                        if let Some(state) = state { contexts.contexts.insert(id.clone(),state); } else { contexts.contexts.remove(&id); }
                        yield ProviderEvent::Metadata { state: Some(serde_json::to_value(&contexts).map_err(|_|Error::Internal)?), usage };
                    }
                    event => yield event,
                }
            }
        })
    }
    async fn models(&self, cancel: CancellationToken) -> Result<Vec<ChatModel>> {
        let generation = self.discovery.lock().unwrap().generation;
        let mut result = Vec::new();
        let mut warnings = Vec::new();
        let mut failure = None;
        for (id, provider) in &self.providers {
            check_cancel(&cancel)?;
            let connections = provider.connections();
            if !connections.is_empty() && !connections.iter().any(|c| c.connected) {
                continue;
            }
            let discovered = provider.models(cancel.clone()).await;
            let mut discovery = self.discovery.lock().unwrap();
            if discovery.generation != generation {
                return Err(Error::Cancelled);
            }
            match discovered {
                Ok(models) => {
                    if models.len() > 256 {
                        return Err(Error::Invalid("Provider returned too many models."));
                    }
                    let mut seen = std::collections::HashSet::new();
                    let mut qualified = Vec::new();
                    for mut model in models {
                        if !valid_model_id(&model.id) {
                            return Err(Error::Invalid("Provider returned invalid model IDs."));
                        }
                        model.id = format!("{id}/{}", model.id);
                        model.provider = Some(id.clone());
                        if !valid_model_id(&model.id) || !seen.insert(model.id.clone()) {
                            return Err(Error::Invalid("Provider returned invalid model IDs."));
                        }
                        qualified.push(model);
                    }
                    discovery.models.insert(id.clone(), qualified);
                }
                Err(Error::Cancelled) => return Err(Error::Cancelled),
                Err(error) => {
                    failure = Some(error);
                    warnings.push(format!(
                        "Could not refresh {id} models. Cached metadata may be stale."
                    ));
                }
            }
            result.extend(discovery.models.get(id).cloned().unwrap_or_default());
        }
        let mut discovery = self.discovery.lock().unwrap();
        if discovery.generation != generation {
            return Err(Error::Cancelled);
        }
        discovery.warnings = warnings;
        if result.is_empty()
            && let Some(error) = failure
        {
            return Err(error);
        }
        Ok(result)
    }
}
