mod support;

use exec_agent::{
    Error,
    core::*,
    manager::AgentManager,
    service::start_persistent_service,
    storage::{ConversationStore, JsonConversationStore},
};
use serde_json::json;
use std::fs;
use support::{client::AgentClient, *};

#[tokio::test]
async fn missing_and_legacy_library_defaults_do_not_change_legacy_sessions() {
    let profile = directory();
    let workspace = directory();
    let provider = FakeProvider::new(vec![]);
    let store = JsonConversationStore::open(profile.path()).await.unwrap();
    assert_eq!(
        store.load_library().await.unwrap().default_disabled_tools,
        ["shell"]
    );
    let manager = AgentManager::open(store, |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let old = manager
        .create(options(provider.clone(), vec![]))
        .await
        .unwrap();
    let old_id = old.id.clone();
    let mut legacy_record = serde_json::to_value(old.record()).unwrap();
    legacy_record["metadata"]
        .as_object_mut()
        .unwrap()
        .remove("disabledTools");
    let mut legacy_library = serde_json::to_value(LibraryConfiguration::default()).unwrap();
    legacy_library
        .as_object_mut()
        .unwrap()
        .remove("defaultDisabledTools");
    manager.close().await.unwrap();
    fs::write(
        profile.path().join(format!("{old_id}.json")),
        serde_json::to_vec(&legacy_record).unwrap(),
    )
    .unwrap();
    fs::write(
        profile.path().join("library.json"),
        serde_json::to_vec(&legacy_library).unwrap(),
    )
    .unwrap();

    let manager = AgentManager::open(
        JsonConversationStore::open(profile.path()).await.unwrap(),
        |_| (provider.clone(), vec![]),
    )
    .await
    .unwrap();
    assert_eq!(
        manager
            .library_configuration()
            .unwrap()
            .default_disabled_tools,
        ["shell"]
    );
    let old = manager.get(&old_id).unwrap();
    assert!(old.snapshot().metadata.disabled_tools.is_empty());
    let new = manager
        .create_session(
            provider.clone(),
            vec![],
            Some("fake".into()),
            workspace.path().to_string_lossy().into_owned(),
            None,
            None,
        )
        .await
        .unwrap();
    assert_eq!(new.snapshot().metadata.disabled_tools, ["shell"]);
    let fork = manager.fork(&old_id, provider, vec![]).await.unwrap();
    assert!(fork.snapshot().metadata.disabled_tools.is_empty());
    assert!(old.snapshot().metadata.disabled_tools.is_empty());
    manager.close().await.unwrap();
}

#[tokio::test]
async fn library_tool_defaults_persist_inherit_and_allow_explicit_empty_override() {
    let profile = directory();
    let workspace = directory();
    let provider = FakeProvider::new(vec![]);
    let mut existing = Vec::<ConversationSnapshot>::new();
    for defaults in [
        json!(["shell"]),
        json!(["delegate", "unavailable"]),
        json!([]),
    ] {
        let service = start_persistent_service(
            profile.path(),
            provider.clone(),
            false,
            "127.0.0.1:0".parse().unwrap(),
            http_access(),
        )
        .await
        .unwrap();
        let client = AgentClient::new(service.address).unwrap();
        let updated = client
            .call(
                "PATCH",
                "/v1/library",
                Some(json!({"defaultDisabledTools":defaults})),
            )
            .await
            .unwrap();
        assert_eq!(updated["defaultDisabledTools"], defaults);
        // An unrelated patch must not reset an explicit empty selection.
        let updated = client
            .call(
                "PATCH",
                "/v1/library",
                Some(json!({"automaticTitles":false})),
            )
            .await
            .unwrap();
        assert_eq!(updated["defaultDisabledTools"], defaults);
        service.close().await.unwrap();
        let saved: serde_json::Value = serde_json::from_slice(
            &fs::read(profile.path().join("conversations/library.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(saved["defaultDisabledTools"], defaults);

        let service = start_persistent_service(
            profile.path(),
            provider.clone(),
            false,
            "127.0.0.1:0".parse().unwrap(),
            http_access(),
        )
        .await
        .unwrap();
        let client = AgentClient::new(service.address).unwrap();
        assert_eq!(
            json!(client.library().await.unwrap().default_disabled_tools),
            defaults
        );
        for previous in &existing {
            assert_eq!(client.get(&previous.id).await.unwrap(), *previous);
        }
        let inherited = client
            .create("fake", workspace.path().to_str().unwrap())
            .await
            .unwrap();
        assert_eq!(json!(inherited.metadata.disabled_tools), defaults);
        let override_selection: ConversationSnapshot = serde_json::from_value(
            client
                .call(
                    "POST",
                    "/v1/conversations",
                    Some(json!({
                        "model":"fake", "workspace":workspace.path(), "disabledTools":[]
                    })),
                )
                .await
                .unwrap(),
        )
        .unwrap();
        assert!(override_selection.metadata.disabled_tools.is_empty());
        // Library defaults can retain unavailable tools; explicit session requests cannot.
        assert_eq!(
            client
                .call(
                    "POST",
                    "/v1/conversations",
                    Some(json!({
                        "model":"fake", "workspace":workspace.path(),
                        "disabledTools":["unavailable"]
                    })),
                )
                .await
                .unwrap_err(),
            Error::Api(400)
        );
        existing.extend([inherited, override_selection]);
        service.close().await.unwrap();
    }
}

#[tokio::test]
async fn library_patch_rejects_invalid_disabled_tools_without_changing_defaults() {
    let profile = directory();
    let service = start_persistent_service(
        profile.path(),
        FakeProvider::new(vec![]),
        false,
        "127.0.0.1:0".parse().unwrap(),
        http_access(),
    )
    .await
    .unwrap();
    let client = AgentClient::new(service.address).unwrap();
    let original = client.library().await.unwrap();
    for invalid in [
        json!(null),
        json!("shell"),
        json!([1]),
        json!([""]),
        json!(["shell", "shell"]),
        json!(["bad name"]),
        json!(["bad\0name"]),
        json!(["x".repeat(129)]),
        json!((0..257).map(|i| format!("tool{i}")).collect::<Vec<_>>()),
    ] {
        assert_eq!(
            client
                .call(
                    "PATCH",
                    "/v1/library",
                    Some(json!({"defaultDisabledTools":invalid})),
                )
                .await
                .unwrap_err(),
            Error::Api(400)
        );
        assert_eq!(client.library().await.unwrap(), original);
    }
    service.close().await.unwrap();
}
