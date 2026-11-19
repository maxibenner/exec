use support::client::AgentClient;
mod support;
use exec_agent::{Error, Result, core::*, manager::AgentManager, service::*};
use futures_util::stream::BoxStream;
use std::{sync::Arc, time::Duration};
use tokio_util::sync::CancellationToken;
struct Provider;
#[async_trait::async_trait]
impl ChatProvider for Provider {
    fn stream(&self, _: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        panic!("sign-in/history must never invoke inference")
    }
    async fn connect(
        &self,
        _: &str,
        method: ConnectionMethod,
        challenge: tokio::sync::oneshot::Sender<AuthenticationChallenge>,
        cancel: CancellationToken,
    ) -> Result<()> {
        challenge
            .send(AuthenticationChallenge {
                authorization_url: "https://example.com/synthetic-auth-challenge".into(),
                device_code: (method == ConnectionMethod::DeviceCode).then(|| {
                    DeviceCodeChallenge {
                        user_code: "TEST-CODE".into(),
                        expires_at: 4_000_000_000,
                    }
                }),
            })
            .map_err(|_| Error::Cancelled)?;
        cancel.cancelled().await;
        Err(Error::Cancelled)
    }
}
#[tokio::test]
async fn browser_authentication_is_manager_owned_targeted_and_settles_before_shutdown() {
    let root = support::directory();
    let manager = Arc::new(AgentManager::default());
    let service = start_service(ServiceOptions {
        access: support::http_access(),
        manager: manager.clone(),
        provider: Arc::new(Provider),
        tools: vec![],
        address: "127.0.0.1:0".parse().unwrap(),
    })
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let c = client
        .create("test", root.path().to_str().unwrap())
        .await
        .unwrap();
    let challenge = client.connect_browser("openai").await.unwrap();
    assert!(client.get(&c.id).await.is_ok());
    assert!(matches!(
        client.create("test", root.path().to_str().unwrap()).await,
        Err(Error::Api(409))
    ));
    assert!(client.cancel_connection(&new_id()).await.is_err());
    client
        .cancel_connection(&challenge.attempt.id)
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(3), async {
        while client.connection_attempt().await.unwrap().unwrap().state == "running" {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        client.connection_attempt().await.unwrap().unwrap().state,
        "interrupted"
    );
    let second = client.connect_browser("openai").await.unwrap();
    assert_ne!(second.attempt.id, challenge.attempt.id);
    service.close().await.unwrap();
    assert_eq!(manager.connection_attempt().unwrap().state, "interrupted");
}

#[tokio::test]
async fn device_login_is_explicit_and_keeps_the_existing_browser_wire_contract() {
    let manager = Arc::new(AgentManager::default());
    let service = start_service(ServiceOptions {
        access: support::http_access(),
        manager: manager.clone(),
        provider: Arc::new(Provider),
        tools: vec![],
        address: "127.0.0.1:0".parse().unwrap(),
    })
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    for body in [
        serde_json::json!({"method":null}),
        serde_json::json!({"method":"unsupported"}),
        serde_json::json!({"method":"device_code","extra":true}),
    ] {
        assert!(matches!(
            client
                .call("POST", "/v1/providers/openai/connect", Some(body))
                .await,
            Err(Error::Api(400))
        ));
        assert!(manager.connection_attempt().is_none());
    }
    let challenge = client
        .call(
            "POST",
            "/v1/providers/openai/connect",
            Some(serde_json::json!({"method":"device_code"})),
        )
        .await
        .unwrap();
    assert_eq!(
        challenge["authorizationUrl"],
        "https://example.com/synthetic-auth-challenge"
    );
    assert!(challenge.get("authorizationURL").is_none());
    assert_eq!(challenge["deviceCode"]["userCode"], "TEST-CODE");
    assert_eq!(manager.connection_attempt().unwrap().state, "running");
    service.close().await.unwrap();
    assert_eq!(manager.connection_attempt().unwrap().state, "interrupted");
}

struct NoChallenge;
#[async_trait::async_trait]
impl ChatProvider for NoChallenge {
    fn stream(&self, _: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        panic!("authentication never invokes inference")
    }
    async fn connect(
        &self,
        _: &str,
        _: ConnectionMethod,
        challenge: tokio::sync::oneshot::Sender<AuthenticationChallenge>,
        cancel: CancellationToken,
    ) -> Result<()> {
        cancel.cancelled().await;
        drop(challenge);
        Err(Error::Cancelled)
    }
}
#[tokio::test(start_paused = true)]
async fn challenge_startup_timeout_cancels_and_settles_the_account_operation() {
    let manager = Arc::new(AgentManager::default());
    let task_manager = manager.clone();
    let task = tokio::spawn(async move {
        task_manager
            .connect_with_method(
                Arc::new(NoChallenge),
                "openai",
                ConnectionMethod::DeviceCode,
            )
            .await
    });
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_secs(46)).await;
    assert!(task.await.unwrap().is_err());
    manager.cancel_and_wait().await.unwrap();
    assert_eq!(manager.connection_attempt().unwrap().state, "interrupted");
}
