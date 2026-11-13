mod support;
use exec_agent::{
    core::*,
    tools::{create_file_tools, revision},
};
use serde_json::json;
use std::fs;
use support::*;
#[tokio::test]
async fn edit_previews_are_exact_and_only_successful_effects_get_applied_details() {
    for approved in [false, true] {
        let root = directory();
        let path = root.path().join("file.txt");
        let before = "first\nold\nlast\n";
        fs::write(&path, before).unwrap();
        let call=ProviderEvent::ToolCall(ToolCall{id:"edit-1".into(),name:"edit_file".into(),arguments:json!({"path":"file.txt","expected_revision":revision(before.as_bytes()),"old_text":"old","new_text":"new"}).as_object().unwrap().clone()});
        let p = FakeProvider::new(vec![response(vec![call, ProviderEvent::Done]), answer()]);
        let mut options = options(p.clone(), create_file_tools());
        options.workspace = root.path().to_str().unwrap().into();
        let c = Conversation::new(options, None).unwrap();
        let run = c.submit("edit".into()).unwrap();
        let pending = approval(&c).await;
        let details = pending.details.clone().unwrap();
        assert!(
            matches!(&details,ToolDetails::Edit{path,diff,truncated:false} if path=="file.txt"&&diff.contains("-old\n+new\n"))
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), before);
        c.resolve_approval(&run.operation_id, &pending.id, approved);
        complete(run).await;
        let snapshot = c.snapshot();
        let applied = snapshot.messages.iter().find_map(|m| {
            if let Message::Tool { details, .. } = m {
                details.clone()
            } else {
                None
            }
        });
        if approved {
            assert_eq!(applied, Some(details));
            assert_eq!(fs::read_to_string(&path).unwrap(), "first\nnew\nlast\n");
        } else {
            assert!(applied.is_none());
            assert_eq!(fs::read_to_string(&path).unwrap(), before);
        }
        let requests = p.requests.lock().unwrap();
        let context = serde_json::to_value(&requests[1].messages).unwrap();
        assert!(!context.to_string().contains("---"));
    }
}
#[tokio::test]
async fn long_line_diff_is_explicitly_truncated_without_changing_edit_execution() {
    let root = directory();
    let before = format!("x{}", "a".repeat(100000));
    fs::write(root.path().join("long.txt"), &before).unwrap();
    let call=ProviderEvent::ToolCall(ToolCall{id:"edit-1".into(),name:"edit_file".into(),arguments:json!({"path":"long.txt","expected_revision":revision(before.as_bytes()),"old_text":"x","new_text":"y"}).as_object().unwrap().clone()});
    let p = FakeProvider::new(vec![response(vec![call, ProviderEvent::Done]), answer()]);
    let mut options = options(p, create_file_tools());
    options.workspace = root.path().to_str().unwrap().into();
    options.settings.auto_approve = true;
    let c = Conversation::new(options, None).unwrap();
    assert_eq!(
        complete(c.submit("edit".into()).unwrap()).await.state,
        OperationState::Completed
    );
    assert!(c.snapshot().messages.iter().any(|m|matches!(m,Message::Tool{details:Some(ToolDetails::Edit{truncated:true,diff,..}),..} if diff.len()<66000&&diff.contains("not a complete patch"))));
    assert!(
        fs::read_to_string(root.path().join("long.txt"))
            .unwrap()
            .starts_with('y')
    );
}
