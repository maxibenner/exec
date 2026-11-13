mod support;
use exec_agent::{
    core::*, manager::AgentManager, providers::ProviderRegistry, storage::JsonConversationStore,
    tools::create_provider_tools,
};
use serde_json::json;
use std::sync::{Arc, Mutex};
use support::*;
use tokio_util::sync::CancellationToken;
struct SearchProvider {
    inference: Arc<FakeProvider>,
    searched: Mutex<Vec<String>>,
}
#[async_trait::async_trait]
impl ChatProvider for SearchProvider {
    fn supports_web_search(&self) -> bool {
        true
    }
    fn stream(
        &self,
        request: ProviderRequest,
    ) -> futures_util::stream::BoxStream<'static, exec_agent::Result<ProviderEvent>> {
        self.inference.stream(request)
    }
    async fn search_web(
        &self,
        model: &str,
        query: String,
        _: CancellationToken,
    ) -> exec_agent::Result<WebSearchResult> {
        self.searched.lock().unwrap().push(model.into());
        Ok(WebSearchResult {
            query,
            answer: "evidence".into(),
            sources: vec![],
        })
    }
}
#[tokio::test]
async fn selected_search_model_is_explicit_and_persisted_without_changing_chat_model() {
    for selected in [None, Some("search/other".to_string())] {
        let profile = directory();
        let workspace = directory();
        let call = ProviderEvent::ToolCall(ToolCall {
            id: "search-1".into(),
            name: "web_search".into(),
            arguments: json!({"query":"public query"}).as_object().unwrap().clone(),
        });
        let chat = Arc::new(SearchProvider {
            inference: FakeProvider::new(vec![response(vec![call, ProviderEvent::Done]), answer()]),
            searched: Mutex::new(vec![]),
        });
        let search = Arc::new(SearchProvider {
            inference: FakeProvider::new(vec![]),
            searched: Mutex::new(vec![]),
        });
        let registry = Arc::new(
            ProviderRegistry::new(
                "chat",
                vec![
                    ("chat".into(), chat.clone()),
                    ("search".into(), search.clone()),
                ],
            )
            .unwrap(),
        );
        let tools = create_provider_tools(registry.clone());
        let manager = AgentManager::open(
            JsonConversationStore::open(profile.path()).await.unwrap(),
            |_| (registry.clone(), tools.clone()),
        )
        .await
        .unwrap();
        let mut options = ConversationOptions::new(
            registry.clone(),
            "chat/main",
            workspace.path().to_str().unwrap(),
        );
        options.tools = tools.clone();
        options.settings.search_model = selected.clone();
        let c = manager.create(options).await.unwrap();
        assert_eq!(
            complete(manager.submit(&c.id, "look it up".into()).await.unwrap())
                .await
                .state,
            OperationState::Completed
        );
        assert_eq!(chat.inference.count(), 2);
        assert_eq!(search.inference.count(), 0);
        if selected.is_some() {
            assert_eq!(*search.searched.lock().unwrap(), vec!["other"]);
            assert!(chat.searched.lock().unwrap().is_empty());
        } else {
            assert_eq!(*chat.searched.lock().unwrap(), vec!["main"]);
            assert!(search.searched.lock().unwrap().is_empty());
        }
        manager.close().await.unwrap();
        let manager = AgentManager::open(
            JsonConversationStore::open(profile.path()).await.unwrap(),
            |_| (registry.clone(), tools.clone()),
        )
        .await
        .unwrap();
        assert_eq!(
            manager
                .get(&c.id)
                .unwrap()
                .snapshot()
                .configuration
                .settings
                .search_model,
            selected
        );
        manager.close().await.unwrap();
    }
}
