#[path = "support/http.rs"]
mod http;
mod support;
use exec_agent::{
    Error, ProviderFailure,
    core::*,
    providers::{DeepSeekProvider, HttpResponse},
    tools::create_provider_tools,
};
use http::*;
use serde_json::json;
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn search_and_balance_decode_bounded_neutral_values_without_inference() {
    let transport = Transport::new(|request| async move {
        Ok(match request.path.as_str() {
            "v1/tools/search" => {
                assert_eq!(
                    serde_json::from_str::<serde_json::Value>(&request.body.unwrap()).unwrap(),
                    json!({"query":"public query","count":10,"need_content":false})
                );
                json_response(json!({"results":[
                    {"title":"Source", "url":"https://example.com/article", "summary":"An excerpt", "snippet":"unused"},
                    {"title":"Duplicate", "url":"https://example.com/article", "summary":"dup", "snippet":""},
                    {"title":"Bad", "url":"javascript:alert(1)", "summary":"bad", "snippet":""}
                ]}))
            }
            "user/balance" => {
                assert!(request.body.is_none());
                json_response(
                    json!({"balance_infos":[{"currency":"USD","total_balance":"12.3400"}]}),
                )
            }
            _ => panic!("unexpected inference"),
        })
    });
    let p = provider(transport.clone());
    let found = p
        .search_web(
            "deepseek-chat",
            "public query".into(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(found.sources.len(), 1);
    assert_eq!(found.answer, "[1] An excerpt");
    let balances = p
        .account_balances("deepseek", CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(balances[0].amount, "12.3400");
    assert_eq!(transport.count(), 2);
    assert!(
        p.search_web("deepseek-chat", "x".repeat(129), CancellationToken::new())
            .await
            .is_err()
    );
    assert_eq!(transport.count(), 2);
}

#[tokio::test]
async fn model_search_tool_uses_same_runner_loop_and_persists_sources_as_evidence() {
    let calls = Arc::new(AtomicUsize::new(0));
    let count = calls.clone();
    let transport = Transport::new(move |request| {
        let count = count.clone();
        async move {
            if request.path == "v1/tools/search" {
                return Ok(json_response(
                    json!({"results":[{"title":"Source","url":"https://example.com/source","summary":"Evidence","snippet":""}]}),
                ));
            }
            assert_eq!(request.path, "chat/completions");
            if count.fetch_add(1, Ordering::SeqCst) == 0 {
                let call = delta(
                    json!({"tool_calls":[{"index":0,"id":"search-1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"public query\"}"}}]}),
                    Some("tool_calls"),
                );
                Ok(wire(event(call) + &event(json!("[DONE]"))))
            } else {
                let body: serde_json::Value = serde_json::from_str(&request.body.unwrap()).unwrap();
                assert!(body.to_string().contains("https://example.com/source"));
                Ok(wire(complete("Answer with a source")))
            }
        }
    });
    let p = Arc::new(provider(transport.clone()));
    let mut opts = support::options(p.clone(), create_provider_tools(p));
    opts.model = "deepseek-chat".into();
    let c = Conversation::new(opts, None).unwrap();
    assert_eq!(
        support::complete(c.submit("look it up".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert_eq!(transport.count(), 3);
    assert_eq!(support::outcomes(&c), [ToolOutcome::Completed]);
    assert!(c.snapshot().messages.iter().any(|m|matches!(m,Message::Tool{details:Some(ToolDetails::Search{result}),..} if result.sources.len()==1)));
    assert!(
        c.snapshot()
            .messages
            .iter()
            .any(|m| m.text().contains("https://example.com/source"))
    );
}

#[tokio::test]
async fn malformed_balance_and_failed_search_never_retry_or_leak_provider_bodies() {
    for amount in ["NaN", "1e10", "", "--2", "1.2.3"] {
        let value = json!({"balance_infos":[{"currency":"USD","total_balance":amount}]});
        let transport = Transport::new(move |_| {
            let value = value.clone();
            async move { Ok(json_response(value)) }
        });
        assert_eq!(
            provider(transport.clone())
                .account_balances("deepseek", CancellationToken::new())
                .await
                .unwrap_err(),
            Error::Provider(ProviderFailure::Response)
        );
        assert_eq!(transport.count(), 1);
    }
    let transport = Transport::new(|_| async {
        Ok(HttpResponse {
            status: 429,
            content_type: Some("application/json".into()),
            body: Box::pin(futures_util::stream::once(async {
                Ok(bytes::Bytes::from_static(b"private raw body"))
            })),
        })
    });
    let error = provider(transport.clone())
        .search_web(
            "deepseek-chat",
            "public query".into(),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert_eq!(error, Error::Provider(ProviderFailure::RateLimit));
    assert!(!error.to_string().contains("private raw body"));
    assert_eq!(transport.count(), 1);
}

#[tokio::test]
async fn service_requests_honor_cancellation_and_deadlines_without_retry() {
    let transport = Transport::new(|_| async { std::future::pending().await });
    let p = DeepSeekProvider::with_transport(
        credentials(),
        transport.clone(),
        Duration::from_millis(20),
    )
    .unwrap();
    assert_eq!(
        p.search_web(
            "deepseek-chat",
            "public query".into(),
            CancellationToken::new()
        )
        .await
        .unwrap_err(),
        Error::Provider(ProviderFailure::Timeout)
    );
    assert_eq!(transport.count(), 1);
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert_eq!(
        p.account_balances("deepseek", cancel).await.unwrap_err(),
        Error::Cancelled
    );
    assert_eq!(transport.count(), 1);
}

#[tokio::test]
async fn provider_service_api_round_trips_without_inference() {
    use exec_agent::{client::AgentClient, service::*};
    let root = support::directory();
    let transport = Transport::new(|request| async move {
        Ok(if request.path == "user/balance" {
            json_response(json!({"balance_infos":[{"currency":"CNY","total_balance":"1.25"}]}))
        } else {
            assert_eq!(request.path, "v1/tools/search");
            json_response(json!({"results":[]}))
        })
    });
    let service =
        start_persistent_service(root.path(), Arc::new(provider(transport.clone())), false)
            .await
            .unwrap();
    let client = AgentClient::new(profile_socket(root.path())).unwrap();
    assert_eq!(client.balances("deepseek").await.unwrap()[0].amount, "1.25");
    assert!(
        client
            .search_web("deepseek-chat", "public query")
            .await
            .unwrap()
            .sources
            .is_empty()
    );
    assert_eq!(transport.count(), 2);
    service.close().await.unwrap();
}

struct ChangingAccount {
    entered: CancellationToken,
    release: CancellationToken,
}
#[async_trait::async_trait]
impl ChatProvider for ChangingAccount {
    fn stream(
        &self,
        _: ProviderRequest,
    ) -> futures_util::stream::BoxStream<'static, exec_agent::Result<ProviderEvent>> {
        panic!("no inference")
    }
    async fn account_balances(
        &self,
        _: &str,
        _: CancellationToken,
    ) -> exec_agent::Result<Vec<AccountBalance>> {
        self.entered.cancel();
        self.release.cancelled().await;
        Ok(vec![AccountBalance {
            amount: "1".into(),
            currency: "USD".into(),
        }])
    }
    async fn set_credential(&self, _: &str, _: Option<String>) -> exec_agent::Result<()> {
        Ok(())
    }
}
#[tokio::test]
async fn stale_account_observations_are_rejected_after_credential_changes() {
    use exec_agent::manager::AgentManager;
    let manager = Arc::new(AgentManager::default());
    let p = Arc::new(ChangingAccount {
        entered: CancellationToken::new(),
        release: CancellationToken::new(),
    });
    let observed = manager.clone();
    let provider = p.clone();
    let task = tokio::spawn(async move {
        observed
            .account_balances(provider, "test", CancellationToken::new())
            .await
    });
    p.entered.cancelled().await;
    manager
        .set_credential(p.clone(), "test", None)
        .await
        .unwrap();
    p.release.cancel();
    assert_eq!(task.await.unwrap().unwrap_err(), Error::Cancelled);
    manager.close().await.unwrap();
}
