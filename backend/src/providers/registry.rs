//! Provider-owned routing and discovery. Context is carried by each request, never shared.
use crate::{Error, Result, check_cancel, core::*};
use async_trait::async_trait;
use futures_util::{StreamExt, stream::BoxStream};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashSet},
    sync::{Arc, Mutex},
};
use tokio_util::sync::CancellationToken;
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Contexts {
    registry_version: u32,
    contexts: BTreeMap<String, Value>,
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CachedMetadata {
    identity: String,
    #[serde(default)]
    models: Vec<ChatModel>,
    #[serde(default)]
    fetched_at: u64,
    #[serde(default)]
    usage: Option<AccountUsage>,
    #[serde(default)]
    balances: Option<Vec<AccountBalance>>,
    #[serde(default)]
    balance_fetched_at: Option<u64>,
}
impl CachedMetadata {
    fn valid(&self, id: &str) -> bool {
        self.models.len() <= 256
            && self.models.iter().all(|m| {
                valid_model_id(&m.id)
                    && m.id.starts_with(&format!("{id}/"))
                    && m.name.len() <= 1024
                    && m.context_window.is_none_or(|n| n > 0 && n <= 1_000_000_000)
                    && m.efforts.len() <= 32
                    && m.efforts
                        .iter()
                        .all(|e| !e.id.is_empty() && e.id.len() <= 64 && e.name.len() <= 1024)
            })
            && self.usage.as_ref().is_none_or(|u| {
                u.windows.len() <= 16
                    && u.windows.iter().all(|w| {
                        w.duration_seconds > 0
                            && w.duration_seconds <= 31_536_000
                            && w.used_percent.is_finite()
                            && (0.0..=100.0).contains(&w.used_percent)
                            && w.resets_at > 0
                    })
            })
            && self.balances.as_ref().is_none_or(|b| {
                b.len() <= 16
                    && b.iter().all(|b| {
                        b.currency.len() <= 8
                            && !b.amount.is_empty()
                            && b.amount.len() <= 64
                            && b.amount
                                .strip_prefix('-')
                                .unwrap_or(&b.amount)
                                .split('.')
                                .count()
                                <= 2
                            && b.amount
                                .strip_prefix('-')
                                .unwrap_or(&b.amount)
                                .split('.')
                                .all(|part| {
                                    !part.is_empty() && part.bytes().all(|v| v.is_ascii_digit())
                                })
                    })
            })
    }
}
#[derive(Default)]
struct Discovery {
    cache_warning: Option<&'static str>,
    cache_disabled: bool,
    observations: BTreeMap<String, CachedMetadata>,
    stale: std::collections::HashSet<String>,

    generation: u64,
    models: BTreeMap<String, Vec<ChatModel>>,
    warnings: Vec<String>,
}
pub struct ProviderRegistry {
    default: String,
    providers: BTreeMap<String, Arc<dyn ChatProvider>>,
    discovery: Mutex<Discovery>,
    access: BTreeMap<String, Arc<tokio::sync::RwLock<()>>>,
    disconnecting: Arc<Mutex<HashSet<String>>>,
    cache: Option<super::private_json::PrivateJson>,
}
struct DisconnectReservation {
    id: String,
    disconnecting: Arc<Mutex<HashSet<String>>>,
}
impl Drop for DisconnectReservation {
    fn drop(&mut self) {
        self.disconnecting.lock().unwrap().remove(&self.id);
    }
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
        if providers
            .values()
            .filter(|p| p.supports_image_generation())
            .count()
            > 1
        {
            return Err(Error::Invalid(
                "Compose exactly one image-generation provider; implicit provider fallback is not supported.",
            ));
        }
        if !providers.contains_key(default) || providers.len() > 32 {
            return Err(Error::Invalid("A registered default provider is required."));
        }
        Ok(Self {
            default: default.into(),
            access: providers
                .keys()
                .map(|id| (id.clone(), Arc::new(tokio::sync::RwLock::new(()))))
                .collect(),
            providers,
            discovery: Mutex::new(Discovery::default()),
            disconnecting: Arc::default(),
            cache: None,
        })
    }
    pub async fn with_cache(mut self, path: std::path::PathBuf) -> Result<Self> {
        let cache = super::private_json::PrivateJson::new(path)?;
        let doc = match cache.load().await {
            Ok(doc) => doc,
            Err(_) => {
                self.discovery.lock().unwrap().cache_warning =
                    Some("Metadata cache is unreadable or insecure; it was not modified.");
                return Ok(self);
            }
        };
        for (id, provider) in &self.providers {
            if let Some(identity) = provider.metadata_identity(id)
                && let Some(entry) = doc.get(id).filter(|v| v["identity"] == identity)
                && let Ok(mut entry) = serde_json::from_value::<CachedMetadata>(entry.clone())
                && entry.valid(id)
            {
                if let Some(usage) = &mut entry.usage {
                    usage.stale = true;
                }
                let mut d = self.discovery.lock().unwrap();
                d.models.insert(id.clone(), entry.models.clone());
                d.observations.insert(id.clone(), entry);
                d.stale.insert(id.clone());
                d.stale.insert(format!("balance:{id}"));
            }
        }
        self.cache = Some(cache);
        Ok(self)
    }
    async fn save_cache(&self, id: &str) -> Result<()> {
        let entry = {
            let d = self.discovery.lock().unwrap();
            if d.cache_disabled {
                return Ok(());
            }
            d.observations.get(id).cloned()
        };
        if let Some(cache) = &self.cache
            && cache
                .update(id.into(), entry.map(serde_json::to_value).transpose()?)
                .await
                .is_err()
        {
            let mut d = self.discovery.lock().unwrap();
            d.cache_disabled = true;
            d.cache_warning = Some(
                "Metadata cache could not be saved; writes are disabled until restart. Current observations remain in memory.",
            );
        }
        Ok(())
    }
    fn invalidate(&self, id: &str) {
        let mut d = self.discovery.lock().unwrap();
        d.generation = d.generation.wrapping_add(1);
        d.models.remove(id);
        d.observations.remove(id);
        d.stale.remove(id);
    }
    fn cached_model(
        &self,
        id: &str,
        model: &str,
        provider: &dyn ChatProvider,
    ) -> Option<ChatModel> {
        let identity = provider.metadata_identity(id);
        let d = self.discovery.lock().unwrap();
        if let Some(identity) = identity {
            if d.observations
                .get(id)
                .is_none_or(|e| e.identity != identity)
            {
                return None;
            }
        } else if !provider.connections().is_empty() {
            return None;
        }
        d.models
            .get(id)?
            .iter()
            .find(|m| m.id == format!("{id}/{model}"))
            .cloned()
    }
    // Keep every provider request alive through its cleanup before credential writes.
    // try_read never queues new inference behind a disconnect or silently replays it.
    fn read_access(&self, id: &str) -> Result<tokio::sync::OwnedRwLockReadGuard<()>> {
        let disconnecting = self.disconnecting.lock().unwrap();
        if disconnecting.contains(id) {
            return Err(Error::Busy);
        }
        self.access
            .get(id)
            .ok_or(Error::Invalid("Unknown provider."))?
            .clone()
            .try_read_owned()
            .map_err(|_| Error::Busy)
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
    fn provider_id(&self, model: &str) -> Option<String> {
        self.route(model).ok().map(|(id, _, _)| id)
    }
    fn image_generation_provider_id(&self) -> Option<String> {
        self.providers
            .iter()
            .find(|(_, p)| p.supports_image_generation())
            .map(|(id, _)| id.clone())
    }
    async fn prepare_model(&self, model: &str, cancel: CancellationToken) -> Result<()> {
        let (id, bare, provider) = self.route(model)?;
        let _access = self.read_access(&id)?;
        if !provider.supports_compaction(&bare) || self.context_window(model).is_none() {
            provider.prepare_model(&bare, cancel).await?;
        }
        Ok(())
    }
    fn image_context_indices(&self, request: &ProviderRequest) -> Result<Vec<usize>> {
        let (id, model, provider) = self.route(&request.model)?;
        let contexts = self.contexts(request.provider_state.clone())?;
        let mut request = request.clone();
        request.model = model;
        request.provider_state = contexts.contexts.get(&id).cloned();
        provider.image_context_indices(&request)
    }
    async fn accepts_images(&self, model: &str, cancel: CancellationToken) -> Result<bool> {
        let (id, bare, provider) = self.route(model)?;
        let _access = self.read_access(&id)?;
        if let Some(accepts) = self
            .cached_model(&id, &bare, provider.as_ref())
            .and_then(|m| m.accepts_images)
        {
            return Ok(accepts);
        }
        provider.accepts_images(&bare, cancel).await
    }
    fn supports_image_generation(&self) -> bool {
        self.providers
            .values()
            .any(|p| p.supports_image_generation())
    }
    fn max_image_generation_inputs(&self) -> usize {
        self.providers
            .values()
            .find(|p| p.supports_image_generation())
            .map_or(0, |p| p.max_image_generation_inputs())
    }
    fn image_generation_available(&self) -> bool {
        self.providers
            .values()
            .find(|p| p.supports_image_generation())
            .is_some_and(|p| p.image_generation_available())
    }
    async fn generate_image(
        &self,
        input: ImageGeneration,
        cancel: CancellationToken,
    ) -> Result<GeneratedImage> {
        let id = self
            .image_generation_provider_id()
            .ok_or(Error::Provider(crate::ProviderFailure::Unsupported))?;
        let _access = self.read_access(&id)?;
        self.providers[&id].generate_image(input, cancel).await
    }
    fn metadata_identity(&self, id: &str) -> Option<String> {
        self.providers.get(id)?.metadata_identity(id)
    }
    fn context_window(&self, model: &str) -> Option<u64> {
        let (id, bare, provider) = self.route(model).ok()?;
        self.cached_model(&id, &bare, provider.as_ref())
            .and_then(|m| m.context_window)
            .or_else(|| provider.context_window(&bare))
    }
    fn supports_compaction(&self, model: &str) -> bool {
        self.route(model)
            .is_ok_and(|(_, model, p)| p.supports_compaction(&model))
    }
    async fn compact(&self, mut request: ProviderRequest) -> Result<Value> {
        let (id, model, provider) = self.route(&request.model)?;
        let _access = self.read_access(&id)?;
        let mut contexts = self.contexts(request.provider_state.take())?;
        request.model = model;
        request.provider_state = contexts.contexts.get(&id).cloned();
        let state = provider.compact(request).await?;
        contexts.contexts.insert(id, state);
        serde_json::to_value(contexts).map_err(|_| Error::Internal)
    }
    async fn settle(&self) {
        for p in self.providers.values() {
            p.settle().await;
        }
    }
    async fn connect(
        &self,
        id: &str,
        method: ConnectionMethod,
        challenge: tokio::sync::oneshot::Sender<AuthenticationChallenge>,
        cancel: CancellationToken,
    ) -> Result<()> {
        let provider = self
            .providers
            .get(id)
            .ok_or(Error::Invalid("Unknown provider."))?;
        let _access = self.access[id].write().await;
        self.invalidate(id);
        let result = provider.connect(id, method, challenge, cancel).await;
        self.invalidate(id);
        self.save_cache(id).await?;
        result
    }
    async fn account_usage(&self, id: &str, cancel: CancellationToken) -> Result<AccountUsage> {
        check_cancel(&cancel)?;
        let _access = self.read_access(id)?;
        let provider = self
            .providers
            .get(id)
            .ok_or(Error::Invalid("Unknown provider."))?;
        let identity = provider
            .metadata_identity(id)
            .ok_or(Error::Provider(crate::ProviderFailure::Authentication))?;
        let (generation, cached) = {
            let d = self.discovery.lock().unwrap();
            (
                d.generation,
                d.observations
                    .get(id)
                    .filter(|e| e.identity == identity)
                    .and_then(|e| e.usage.clone()),
            )
        };
        if let Some(usage) = &cached
            && !usage.stale
            && SessionMetadata::activity().saturating_sub(usage.fetched_at) < 30_000
        {
            return Ok(usage.clone());
        }
        let result = provider.account_usage(id, cancel.clone()).await;
        check_cancel(&cancel)?;
        let result = {
            let mut d = self.discovery.lock().unwrap();
            if d.generation != generation
                || provider.metadata_identity(id) != Some(identity.clone())
            {
                return Err(Error::Cancelled);
            }
            match result {
                Ok(usage) => {
                    let entry = d.observations.entry(id.into()).or_default();
                    entry.identity = identity;
                    entry.usage = Some(usage.clone());
                    Ok(usage)
                }
                Err(Error::Cancelled) => Err(Error::Cancelled),
                Err(error) => {
                    if let Some(mut usage) = cached {
                        usage.stale = true;
                        d.observations.get_mut(id).unwrap().usage = Some(usage.clone());
                        Ok(usage)
                    } else {
                        Err(error)
                    }
                }
            }
        };
        self.save_cache(id).await?;
        result
    }
    fn metadata_freshness(&self) -> Vec<MetadataFreshness> {
        let d = self.discovery.lock().unwrap();
        let now = SessionMetadata::activity();
        self.providers
            .iter()
            .map(|(id, p)| {
                let entry = d
                    .observations
                    .get(id)
                    .filter(|e| p.metadata_identity(id) == Some(e.identity.clone()));
                MetadataFreshness {
                    provider: id.clone(),
                    models_fetched_at: entry.map(|e| e.fetched_at).filter(|n| *n > 0),
                    models_stale: entry.is_none_or(|e| {
                        d.stale.contains(id)
                            || now.saturating_sub(e.fetched_at) > 300_000
                            || e.fetched_at > now.saturating_add(60_000)
                    }),
                    usage_fetched_at: entry.and_then(|e| e.usage.as_ref().map(|u| u.fetched_at)),
                    usage_stale: entry.and_then(|e| e.usage.as_ref()).is_none_or(|u| {
                        u.stale
                            || now.saturating_sub(u.fetched_at) > 30_000
                            || u.fetched_at > now.saturating_add(60_000)
                    }),
                    balance_fetched_at: entry.and_then(|e| e.balance_fetched_at),
                    balance_stale: entry.and_then(|e| e.balance_fetched_at).is_none_or(|t| {
                        d.stale.contains(&format!("balance:{id}")) || now.saturating_sub(t) > 30_000
                    }),
                }
            })
            .collect()
    }
    fn connections(&self) -> Vec<ProviderConnection> {
        self.providers
            .values()
            .flat_map(|p| p.connections())
            .collect()
    }
    fn model_warnings(&self) -> Vec<String> {
        let d = self.discovery.lock().unwrap();
        let mut warnings = d.warnings.clone();
        if let Some(warning) = d.cache_warning {
            warnings.push(warning.into());
        }
        warnings
    }
    fn supports_web_search(&self) -> bool {
        self.providers.values().any(|p| p.supports_web_search())
    }
    fn web_search_availability(&self, model: &str) -> RuntimeToolAvailability {
        if model.is_empty() {
            return RuntimeToolAvailability::unavailable("Select a model.");
        }
        let Ok((id, model, provider)) = self.route(model) else {
            return RuntimeToolAvailability::unavailable(
                "Search is not supported by the selected provider.",
            );
        };
        // Nonblocking local gate only; never queue, discover or refresh credentials.
        let Ok(_access) = self.read_access(&id) else {
            return RuntimeToolAvailability::unavailable("Connect the selected search provider.");
        };
        provider.web_search_availability(&model)
    }
    fn reserve_disconnect(&self, id: &str) -> Result<Box<dyn Send>> {
        if !self.providers.contains_key(id) {
            return Err(Error::Invalid("Unknown provider."));
        }
        if !self.disconnecting.lock().unwrap().insert(id.into()) {
            return Err(Error::Busy);
        }
        Ok(Box::new(DisconnectReservation {
            id: id.into(),
            disconnecting: self.disconnecting.clone(),
        }))
    }
    async fn set_credential(&self, id: &str, credential: Option<String>) -> Result<()> {
        let gate = self
            .access
            .get(id)
            .ok_or(Error::Invalid("Unknown provider."))?;
        let _access = gate.write().await;
        let provider = self
            .providers
            .get(id)
            .ok_or(Error::Invalid("Unknown provider."))?;
        {
            let mut discovery = self.discovery.lock().unwrap();
            discovery.generation = discovery.generation.wrapping_add(1);
            discovery.models.remove(id);
            discovery.observations.remove(id);
            discovery.stale.remove(id);
            discovery.warnings.clear();
        }
        let result = provider.set_credential(id, credential).await;
        self.save_cache(id).await?;
        {
            let mut discovery = self.discovery.lock().unwrap();
            discovery.generation = discovery.generation.wrapping_add(1);
            discovery.models.remove(id);
            discovery.observations.remove(id);
            discovery.stale.remove(id);
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
        let (id, model, provider) = self.route(model)?;
        let _access = self.read_access(&id)?;
        provider.search_web(&model, query, cancel).await
    }
    async fn account_balances(
        &self,
        id: &str,
        cancel: CancellationToken,
    ) -> Result<Vec<AccountBalance>> {
        check_cancel(&cancel)?;
        let _access = self.read_access(id)?;
        let provider = self
            .providers
            .get(id)
            .ok_or(Error::Invalid("Unknown provider."))?;
        let Some(identity) = provider.metadata_identity(id) else {
            return provider.account_balances(id, cancel).await;
        };
        let (generation, cached) = {
            let d = self.discovery.lock().unwrap();
            (
                d.generation,
                d.observations
                    .get(id)
                    .filter(|e| e.identity == identity)
                    .cloned(),
            )
        };
        if let Some(entry) = &cached
            && entry
                .balance_fetched_at
                .is_some_and(|t| SessionMetadata::activity().saturating_sub(t) < 30_000)
            && !self
                .discovery
                .lock()
                .unwrap()
                .stale
                .contains(&format!("balance:{id}"))
            && let Some(balances) = &entry.balances
        {
            return Ok(balances.clone());
        }
        let result = provider.account_balances(id, cancel.clone()).await;
        check_cancel(&cancel)?;
        let result = {
            let mut d = self.discovery.lock().unwrap();
            if d.generation != generation
                || provider.metadata_identity(id) != Some(identity.clone())
            {
                return Err(Error::Cancelled);
            }
            match result {
                Ok(balances) => {
                    d.stale.remove(&format!("balance:{id}"));
                    let entry = d.observations.entry(id.into()).or_default();
                    entry.identity = identity;
                    entry.balances = Some(balances.clone());
                    entry.balance_fetched_at = Some(SessionMetadata::activity());
                    Ok(balances)
                }
                Err(Error::Cancelled) => Err(Error::Cancelled),
                Err(error) => {
                    d.stale.insert(format!("balance:{id}"));
                    if let Some(balances) = cached.and_then(|e| e.balances) {
                        Ok(balances)
                    } else {
                        Err(error)
                    }
                }
            }
        };
        self.save_cache(id).await?;
        result
    }
    fn fork_state(
        &self,
        state: Value,
        message_ids: &[String],
        messages: &[ContextMessage],
    ) -> Result<Option<Value>> {
        let mut contexts = self.contexts(Some(state))?;
        for (id, state) in std::mem::take(&mut contexts.contexts) {
            if let Some(provider) = self.providers.get(&id)
                && let Some(state) = provider.fork_state(state, message_ids, messages)?
            {
                contexts.contexts.insert(id, state);
            }
        }
        Ok(Some(serde_json::to_value(contexts)?))
    }
    fn stream(&self, mut request: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        let prepared = (|| {
            let (id, model, provider) = self.route(&request.model)?;
            let access = self.read_access(&id)?;
            let contexts = self.contexts(request.provider_state.take())?;
            Ok::<_, Error>((id, model, provider, contexts, access))
        })();
        Box::pin(async_stream::try_stream! {
            let (id,model,provider,mut contexts,_access) = prepared?;
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
        let mut saves = Vec::new();
        for (id, provider) in &self.providers {
            check_cancel(&cancel)?;
            let _access = self.read_access(id)?;
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
                        if !valid_model_id(&model.id)
                            || model.name.len() > 1024
                            || model.efforts.len() > 32
                            || model
                                .context_window
                                .is_some_and(|n| n == 0 || n > 1_000_000_000)
                        {
                            return Err(Error::Invalid("Provider returned invalid model IDs."));
                        }
                        model.id = format!("{id}/{}", model.id);
                        model.provider = Some(id.clone());
                        if !valid_model_id(&model.id) || !seen.insert(model.id.clone()) {
                            return Err(Error::Invalid("Provider returned invalid model IDs."));
                        }
                        qualified.push(model);
                    }
                    if let Some(identity) = provider.metadata_identity(id) {
                        let entry = discovery.observations.entry(id.clone()).or_default();
                        entry.identity = identity;
                        entry.models = qualified.clone();
                        entry.fetched_at = SessionMetadata::activity();
                        saves.push(id.clone());
                    }
                    discovery.stale.remove(id);
                    discovery.models.insert(id.clone(), qualified);
                }
                Err(Error::Cancelled) => return Err(Error::Cancelled),
                Err(error) => {
                    failure = Some(error);
                    discovery.stale.insert(id.clone());
                    warnings.push(format!(
                        "Could not refresh {id} models. Cached metadata may be stale."
                    ));
                }
            }
            result.extend(discovery.models.get(id).cloned().unwrap_or_default());
        }
        for id in saves {
            self.save_cache(&id).await?;
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
