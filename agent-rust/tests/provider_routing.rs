mod support;
use exec_agent::{
    Error, ProviderFailure, core::*, manager::AgentManager, providers::ProviderRegistry,
};
use serde_json::json;
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
use support::*;
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn switching_providers_preserves_isolated_opaque_context_and_neutral_history() {
    let first = FakeProvider::new(vec![
        script(|request| {
            assert_eq!(request.model, "model");
            assert!(request.provider_state.is_none());
            Box::pin(futures_util::stream::iter(vec![
                Ok(ProviderEvent::Text("A".into())),
                Ok(ProviderEvent::Metadata {
                    state: Some(json!({"owned":"a"})),
                    usage: None,
                }),
                Ok(ProviderEvent::Done),
            ]))
        }),
        script(|request| {
            assert_eq!(request.provider_state, Some(json!({"owned":"a"})));
            Box::pin(futures_util::stream::iter(vec![
                Ok(ProviderEvent::Text("A again".into())),
                Ok(ProviderEvent::Done),
            ]))
        }),
    ]);
    let second = FakeProvider::new(vec![script(|request| {
        assert_eq!(request.model, "other");
        assert!(request.provider_state.is_none());
        Box::pin(futures_util::stream::iter(vec![
            Ok(ProviderEvent::Text("B".into())),
            Ok(ProviderEvent::Metadata {
                state: Some(json!({"owned":"b"})),
                usage: None,
            }),
            Ok(ProviderEvent::Done),
        ]))
    })]);
    let registry = Arc::new(
        ProviderRegistry::new(
            "first",
            vec![
                ("first".into(), first.clone()),
                ("second".into(), second.clone()),
            ],
        )
        .unwrap(),
    );
    let manager = AgentManager::default();
    let c = manager
        .create(ConversationOptions::new(
            registry,
            "first/model",
            "/isolated-test-workspace",
        ))
        .await
        .unwrap();
    complete(c.submit("first".into()).unwrap()).await;
    manager
        .select_model(&c.id, "second/other".into())
        .await
        .unwrap();
    complete(c.submit("second".into()).unwrap()).await;
    manager
        .select_model(&c.id, "first/model".into())
        .await
        .unwrap();
    complete(c.submit("back".into()).unwrap()).await;
    assert_eq!(first.count(), 2);
    assert_eq!(second.count(), 1);
    assert!(
        c.record().provider_state.unwrap()["contexts"]
            .get("second")
            .is_some()
    );
    assert_eq!(c.snapshot().messages.len(), 6);
    manager.close().await.unwrap();
}
struct CatalogProvider {
    responses: Mutex<VecDeque<exec_agent::Result<Vec<ChatModel>>>>,
}
#[async_trait::async_trait]
impl ChatProvider for CatalogProvider {
    fn stream(
        &self,
        _: ProviderRequest,
    ) -> futures_util::stream::BoxStream<'static, exec_agent::Result<ProviderEvent>> {
        panic!("discovery must not infer")
    }
    async fn models(&self, _: CancellationToken) -> exec_agent::Result<Vec<ChatModel>> {
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("discovery retried")
    }
    async fn set_credential(&self, _: &str, _: Option<String>) -> exec_agent::Result<()> {
        Ok(())
    }
}
#[tokio::test]
async fn catalogs_are_namespaced_cached_with_warnings_and_invalidated_on_auth_change() {
    let model: ChatModel = serde_json::from_value(json!({"id":"model","name":"Model"})).unwrap();
    let p = Arc::new(CatalogProvider {
        responses: Mutex::new(VecDeque::from([
            Ok(vec![model]),
            Err(Error::Provider(ProviderFailure::Transport)),
            Err(Error::Provider(ProviderFailure::Transport)),
        ])),
    });
    let registry = ProviderRegistry::new("first", vec![("first".into(), p)]).unwrap();
    let models = registry.models(CancellationToken::new()).await.unwrap();
    assert_eq!(models[0].id, "first/model");
    assert_eq!(models[0].provider.as_deref(), Some("first"));
    assert_eq!(
        registry.models(CancellationToken::new()).await.unwrap(),
        models
    );
    assert_eq!(registry.model_warnings().len(), 1);
    registry.set_credential("first", None).await.unwrap();
    assert_eq!(
        registry.models(CancellationToken::new()).await.unwrap_err(),
        Error::Provider(ProviderFailure::Transport)
    );
}
#[tokio::test]
async fn unqualified_models_keep_default_route_and_unknown_provider_never_infers() {
    let p = FakeProvider::new(vec![answer()]);
    let registry =
        Arc::new(ProviderRegistry::new("first", vec![("first".into(), p.clone())]).unwrap());
    let c = conversation(registry.clone(), vec![]);
    complete(c.submit("hello".into()).unwrap()).await;
    assert_eq!(p.requests.lock().unwrap()[0].model, "fake");
    let manager = AgentManager::default();
    let c = manager
        .create(ConversationOptions::new(
            registry,
            "missing/model",
            "/isolated-test-workspace",
        ))
        .await
        .unwrap();
    assert_eq!(
        complete(c.submit("no route".into()).unwrap()).await.state,
        OperationState::Failed
    );
    assert_eq!(p.count(), 1);
    manager.close().await.unwrap();
}
