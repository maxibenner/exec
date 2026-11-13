mod support;
use async_trait::async_trait;
use exec_agent::{Error, Result, core::*, providers::ProviderRegistry};
use futures_util::stream::BoxStream;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use tokio_util::sync::CancellationToken;
#[derive(Default)]
struct Provider {
    identity: Mutex<String>,
    offline: AtomicBool,
    models: AtomicUsize,
    usage: AtomicUsize,
    balances: AtomicUsize,
}
impl Provider {
    fn new(identity: &str, offline: bool) -> Arc<Self> {
        Arc::new(Self {
            identity: Mutex::new(identity.into()),
            offline: AtomicBool::new(offline),
            ..Self::default()
        })
    }
}
#[async_trait]
impl ChatProvider for Provider {
    fn metadata_identity(&self, _: &str) -> Option<String> {
        Some(self.identity.lock().unwrap().clone())
    }
    fn stream(&self, _: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        panic!("metadata must never invoke inference")
    }
    async fn models(&self, _: CancellationToken) -> Result<Vec<ChatModel>> {
        self.models.fetch_add(1, Ordering::SeqCst);
        if self.offline.load(Ordering::SeqCst) {
            return Err(Error::Internal);
        }
        Ok(vec![ChatModel {
            id: "model".into(),
            name: "Model".into(),
            context_window: Some(100),
            max_output_tokens: None,
            efforts: vec![],
            default_effort: None,
            provider: None,
            accepts_images: Some(true),
        }])
    }
    async fn account_usage(&self, _: &str, _: CancellationToken) -> Result<AccountUsage> {
        self.usage.fetch_add(1, Ordering::SeqCst);
        if self.offline.load(Ordering::SeqCst) {
            return Err(Error::Internal);
        }
        Ok(AccountUsage {
            windows: vec![AllowanceWindow {
                duration_seconds: 3600,
                used_percent: 25.0,
                resets_at: 1_900_000_000,
            }],
            fetched_at: SessionMetadata::activity(),
            stale: false,
        })
    }
    async fn account_balances(&self, _: &str, _: CancellationToken) -> Result<Vec<AccountBalance>> {
        self.balances.fetch_add(1, Ordering::SeqCst);
        if self.offline.load(Ordering::SeqCst) {
            return Err(Error::Internal);
        }
        Ok(vec![AccountBalance {
            currency: "USD".into(),
            amount: "12.34".into(),
        }])
    }
}
#[tokio::test]
async fn persisted_metadata_is_account_scoped_and_stale_fallback_is_explicit() {
    let root = support::directory();
    let path = root.path().join("metadata.json");
    let p = Provider::new("synthetic-account-fingerprint", false);
    let registry = ProviderRegistry::new("test", vec![("test".into(), p.clone())])
        .unwrap()
        .with_cache(path.clone())
        .await
        .unwrap();
    assert_eq!(
        registry.models(CancellationToken::new()).await.unwrap()[0].id,
        "test/model"
    );
    let usage = registry
        .account_usage("test", CancellationToken::new())
        .await
        .unwrap();
    assert!(!usage.stale);
    registry
        .account_usage("test", CancellationToken::new())
        .await
        .unwrap();
    registry
        .account_balances("test", CancellationToken::new())
        .await
        .unwrap();
    registry
        .account_balances("test", CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(p.usage.load(Ordering::SeqCst), 1);
    assert_eq!(p.balances.load(Ordering::SeqCst), 1);
    assert!(!registry.metadata_freshness()[0].models_stale);
    let p = Provider::new("synthetic-account-fingerprint", true);
    let restored = ProviderRegistry::new("test", vec![("test".into(), p.clone())])
        .unwrap()
        .with_cache(path.clone())
        .await
        .unwrap();
    assert_eq!(restored.context_window("test/model"), Some(100));
    assert_eq!(
        restored
            .models(CancellationToken::new())
            .await
            .unwrap()
            .len(),
        1
    );
    assert!(!restored.model_warnings().is_empty());
    assert!(
        restored
            .account_usage("test", CancellationToken::new())
            .await
            .unwrap()
            .stale
    );
    assert_eq!(
        restored
            .account_balances("test", CancellationToken::new())
            .await
            .unwrap()[0]
            .amount,
        "12.34"
    );
    let freshness = &restored.metadata_freshness()[0];
    assert!(freshness.models_stale && freshness.usage_stale && freshness.balance_stale);
    let changed = ProviderRegistry::new(
        "test",
        vec![("test".into(), Provider::new("different-account", true))],
    )
    .unwrap()
    .with_cache(path)
    .await
    .unwrap();
    assert!(changed.models(CancellationToken::new()).await.is_err());
    assert!(
        changed
            .account_usage("test", CancellationToken::new())
            .await
            .is_err()
    );
    assert!(
        changed
            .account_balances("test", CancellationToken::new())
            .await
            .is_err()
    );
}
#[tokio::test]
async fn corrupt_or_insecure_optional_cache_is_not_repaired_and_does_not_block_discovery() {
    let root = support::directory();
    let target = root.path().join("target");
    std::fs::write(&target, b"preserve").unwrap();
    let path = root.path().join("metadata.json");
    std::os::unix::fs::symlink(&target, &path).unwrap();
    let registry = ProviderRegistry::new(
        "test",
        vec![("test".into(), Provider::new("account", false))],
    )
    .unwrap()
    .with_cache(path)
    .await
    .unwrap();
    assert!(!registry.model_warnings().is_empty());
    assert_eq!(
        registry
            .models(CancellationToken::new())
            .await
            .unwrap()
            .len(),
        1
    );
    assert_eq!(std::fs::read(target).unwrap(), b"preserve");
}
