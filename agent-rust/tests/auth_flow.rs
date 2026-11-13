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
        challenge: tokio::sync::oneshot::Sender<String>,
        cancel: CancellationToken,
    ) -> Result<()> {
        challenge
            .send("https://example.com/synthetic-auth-challenge".into())
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
