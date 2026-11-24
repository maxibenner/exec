use exec_agent::{Result, core::*};
use futures_util::stream::BoxStream;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

struct CapabilityProvider {
    enabled: AtomicBool,
}
impl ChatProvider for CapabilityProvider {
    fn stream(&self, _: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        panic!("Snapshot capability checks must not call inference")
    }
    fn supports_compaction(&self, model: &str) -> bool {
        self.enabled.load(Ordering::SeqCst) && matches!(model, "deepseek/test" | "mock/supported")
    }
}

#[test]
fn snapshots_report_model_capability_without_persisting_it() {
    let provider = Arc::new(CapabilityProvider {
        enabled: AtomicBool::new(true),
    });
    for (model, supported) in [
        ("deepseek/test", true),
        ("mock/supported", true),
        ("mock/unsupported", false),
        ("openai/unsupported", false),
    ] {
        let conversation = Conversation::new(
            ConversationOptions::new(provider.clone(), model, "/test"),
            None,
        )
        .unwrap();
        let snapshot = conversation.snapshot();
        assert!(snapshot.messages.is_empty());
        assert_eq!(snapshot.supports_compaction, supported, "{model}");
        assert_eq!(
            serde_json::to_value(&snapshot).unwrap()["supportsCompaction"],
            supported,
            "{model}"
        );
        assert_eq!(conversation.subscribe().0.supports_compaction, supported);
        assert_eq!(
            conversation
                .sync(SyncCursor::Latest)
                .unwrap()
                .snapshot
                .supports_compaction,
            supported,
            "sync snapshots must carry the same capability"
        );
        let record = conversation.record();
        assert!(
            serde_json::to_value(&record)
                .unwrap()
                .get("supportsCompaction")
                .is_none()
        );
        provider.enabled.store(false, Ordering::SeqCst);
        assert!(!conversation.snapshot().supports_compaction);
        let restored = Conversation::new(
            ConversationOptions::new(provider.clone(), model, "/test"),
            Some(record),
        )
        .unwrap();
        assert!(!restored.snapshot().supports_compaction);
        provider.enabled.store(true, Ordering::SeqCst);
        assert_eq!(restored.snapshot().supports_compaction, supported);
    }
}

#[test]
fn snapshot_compaction_capability_defaults_false_on_legacy_wire() {
    let conversation = Conversation::new(
        ConversationOptions::new(
            Arc::new(CapabilityProvider {
                enabled: AtomicBool::new(true),
            }),
            "deepseek/test",
            "/test",
        ),
        None,
    )
    .unwrap();
    let mut wire = serde_json::to_value(conversation.snapshot()).unwrap();
    assert!(
        serde_json::from_value::<ConversationSnapshot>(wire.clone())
            .unwrap()
            .supports_compaction
    );
    wire["supportsCompaction"] = false.into();
    assert!(
        !serde_json::from_value::<ConversationSnapshot>(wire.clone())
            .unwrap()
            .supports_compaction
    );
    wire.as_object_mut().unwrap().remove("supportsCompaction");
    assert!(
        !serde_json::from_value::<ConversationSnapshot>(wire)
            .unwrap()
            .supports_compaction
    );
}
