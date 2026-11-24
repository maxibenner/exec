mod support;

use exec_agent::{
    Result, core::*, images::ImageStore, providers::ProviderRegistry, tools::create_image_tools,
};
use futures_util::stream::BoxStream;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

struct ImageProvider {
    connected: AtomicBool,
}
impl ChatProvider for ImageProvider {
    fn supports_image_generation(&self) -> bool {
        true
    }
    fn connections(&self) -> Vec<ProviderConnection> {
        vec![ProviderConnection {
            id: "openai".into(),
            name: "Test image provider".into(),
            connected: self.connected.load(Ordering::SeqCst),
            email: None,
            source: "fake".into(),
            manageable: false,
            blocked: false,
        }]
    }
    fn stream(&self, _: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        panic!("Chat must route to the selected chat provider")
    }
}

#[tokio::test]
async fn image_tool_catalog_tracks_image_connection_not_chat_vision() {
    let chat = support::FakeProvider::new(vec![
        support::answer(),
        support::answer(),
        support::answer(),
    ]);
    let images = Arc::new(ImageProvider {
        connected: AtomicBool::new(true),
    });
    let provider = Arc::new(
        ProviderRegistry::new(
            "deepseek",
            vec![
                ("deepseek".into(), chat.clone()),
                ("openai".into(), images.clone()),
            ],
        )
        .unwrap(),
    );
    let root = support::directory();
    let store = ImageStore::open(root.path().join("images")).await.unwrap();
    let mut options = ConversationOptions::new(
        provider.clone(),
        "deepseek/fake",
        "/isolated-test-workspace",
    );
    options.tools = create_image_tools(provider, store);
    let c = Conversation::new(options, None).unwrap();
    for connected in [true, false, true] {
        images.connected.store(connected, Ordering::SeqCst);
        assert_eq!(
            support::complete(c.submit("Continue".into()).unwrap())
                .await
                .state,
            OperationState::Completed
        );
        let requests = chat.requests.lock().unwrap();
        let request = requests.last().unwrap();
        let names: Vec<_> = request
            .tools
            .iter()
            .map(|tool| tool.name.as_str())
            .collect();
        assert_eq!(
            names,
            if connected {
                vec!["generate_image"]
            } else {
                vec![]
            }
        );
        assert!(
            matches!(request.messages.last(), Some(ContextMessage::ToolAvailability { enabled })
            if enabled == &names)
        );
        if requests.len() > 1 {
            let previous = &requests[requests.len() - 2];
            assert!(request.messages.starts_with(&previous.messages));
            assert!(request.message_ids.starts_with(&previous.message_ids));
        }
    }
    c.record().validate().unwrap();
}
