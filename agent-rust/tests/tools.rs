mod support;
use exec_agent::{
    Result,
    core::*,
    tools::{create_workspace_tools, revision},
};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use support::*;
use tokio_util::sync::CancellationToken;
async fn prepare(
    root: &std::path::Path,
    name: &str,
    args: Value,
    cancel: CancellationToken,
) -> Result<Box<dyn PreparedTool>> {
    create_workspace_tools()
        .into_iter()
        .find(|t| t.definition().name == name)
        .unwrap()
        .prepare(
            args.as_object().unwrap().clone(),
            ToolContext {
                call_id: "test-call".into(),
                model: "fake".into(),
                workspace: root.to_string_lossy().into(),
                cancel,
            },
        )
        .await
}
async fn execute(root: &std::path::Path, name: &str, args: Value) -> Result<String> {
    prepare(root, name, args, CancellationToken::new())
        .await?
        .execute()
        .await
}
fn edit(path: &str, before: &str, after: &str) -> Value {
    json!({"path":path,"expected_revision":revision(before.as_bytes()),"old_text":before,"new_text":after})
}
fn tool_call(name: &str, args: Value) -> ProviderEvent {
    ProviderEvent::ToolCall(ToolCall {
        id: "call".into(),
        name: name.into(),
        arguments: args.as_object().unwrap().clone(),
    })
}
fn runtime(root: &std::path::Path, p: Arc<dyn ChatProvider>) -> Arc<Conversation> {
    let mut config = options(p, create_workspace_tools());
    config.workspace = root.to_string_lossy().into();
    Conversation::new(config, None).unwrap()
}
#[tokio::test]
async fn file_reads_full_revisions_utf8_and_output_bounds() {
    let root = directory();
    let content = "\u{feff}Hello λ\nsecond line\n";
    fs::write(root.path().join("sample"), content).unwrap();
    let p = prepare(
        root.path(),
        "read_file",
        json!({"path":"sample","start_line":2,"end_line":2}),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    assert!(p.approval().is_none());
    assert_eq!(
        p.execute().await.unwrap(),
        format!(
            "Revision: {}\n2: second line\n",
            revision(content.as_bytes())
        )
    );
    fs::write(root.path().join("long"), "x".repeat(50000)).unwrap();
    let out = execute(
        root.path(),
        "read_file",
        json!({"path":"long","start_line":1,"end_line":1}),
    )
    .await
    .unwrap();
    assert!(out.len() <= 32768 && out.contains("truncated"));
    assert!(
        prepare(
            root.path(),
            "read_file",
            json!({"path":"sample","start_line":1,"end_line":401}),
            CancellationToken::new()
        )
        .await
        .is_err()
    );
}
#[tokio::test]
async fn file_tools_reject_traversal_symlinks_binary_oversized_input() {
    let root = directory();
    let outside = directory();
    fs::write(outside.path().join("secret"), "outside").unwrap();
    symlink(outside.path(), root.path().join("linked")).unwrap();
    symlink(outside.path().join("secret"), root.path().join("file-link")).unwrap();
    fs::write(root.path().join("binary"), [0, 1]).unwrap();
    fs::write(root.path().join("invalid-utf8"), [255]).unwrap();
    fs::write(root.path().join("large"), vec![65; 1024 * 1024 + 1]).unwrap();
    for path in [
        "../secret".into(),
        outside.path().join("secret").to_string_lossy().into_owned(),
        "linked/secret".into(),
        "file-link".into(),
        "binary".into(),
        "invalid-utf8".into(),
        "large".into(),
    ] {
        assert!(
            execute(
                root.path(),
                "read_file",
                json!({"path":path,"start_line":1,"end_line":10})
            )
            .await
            .is_err(),
            "{path}"
        );
    }
    assert!(
        execute(root.path(), "list_files", json!({"path":"."}))
            .await
            .unwrap()
            .contains("symlink; not followed")
    );
    assert!(
        execute(root.path(), "list_files", json!({"path":"linked"}))
            .await
            .is_err()
    );
}
#[tokio::test]
async fn search_literal_excludes_hidden_build_linked_files() {
    let root = directory();
    for dir in ["src", "node_modules", "dist"] {
        fs::create_dir(root.path().join(dir)).unwrap();
    }
    fs::write(root.path().join("src/main.txt"), "needle.*\nNEEDLE.*\n").unwrap();
    fs::write(root.path().join(".hidden"), "needle.* hidden").unwrap();
    fs::write(root.path().join("node_modules/dep"), "needle.* dependency").unwrap();
    fs::write(root.path().join("dist/build"), "needle.* build").unwrap();
    symlink(root.path().join("src"), root.path().join("linked")).unwrap();
    let out = execute(
        root.path(),
        "search_text",
        json!({"path":".","query":"needle.*"}),
    )
    .await
    .unwrap();
    assert!(out.contains("src/main.txt\":1: needle.*"));
    assert!(!out.contains("dependency") && !out.contains(":2:") && !out.contains("hidden"));
    assert!(out.contains("Search incomplete"));
    assert!(
        execute(root.path(), "search_text", json!({"path":".","query":""}))
            .await
            .is_err()
    );
}
#[tokio::test]
async fn edit_prepares_without_writing_applies_exact_text_preserves_mode() {
    let root = directory();
    let path = root.path().join("script");
    let before = "\u{feff}first\nsecond\n";
    fs::write(&path, before).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o750)).unwrap();
    let p=prepare(root.path(),"edit_file",json!({"path":"script","expected_revision":revision(before.as_bytes()),"old_text":"second","new_text":"changed"}),CancellationToken::new()).await.unwrap();
    assert!(p.approval().unwrap().contains("Replace exact text"));
    assert_eq!(fs::read_to_string(&path).unwrap(), before);
    assert!(p.execute().await.unwrap().contains("Revision:"));
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        "\u{feff}first\nchanged\n"
    );
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o750
    );
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
}
#[tokio::test]
async fn stale_nonunique_edits_leave_target_and_no_staging_files() {
    let root = directory();
    let path = root.path().join("file");
    fs::write(&path, "aaa").unwrap();
    assert!(prepare(root.path(),"edit_file",json!({"path":"file","expected_revision":revision(b"aaa"),"old_text":"aa","new_text":"b"}),CancellationToken::new()).await.is_err());
    assert!(
        prepare(
            root.path(),
            "edit_file",
            edit("file", "wrong", "new"),
            CancellationToken::new()
        )
        .await
        .is_err()
    );
    let p = prepare(
        root.path(),
        "edit_file",
        edit("file", "aaa", "approved"),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    fs::write(&path, "external change").unwrap();
    assert!(
        p.execute()
            .await
            .unwrap_err()
            .to_string()
            .contains("changed while approval")
    );
    assert_eq!(fs::read_to_string(path).unwrap(), "external change");
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
}
#[tokio::test]
async fn concurrent_edits_serialize_checks_so_only_one_revision_wins() {
    let root = directory();
    fs::write(root.path().join("file"), "original").unwrap();
    let a = prepare(
        root.path(),
        "edit_file",
        edit("file", "original", "first"),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    let b = prepare(
        root.path(),
        "edit_file",
        edit("file", "original", "second"),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    let (a, b) = tokio::join!(a.execute(), b.execute());
    assert_ne!(a.is_ok(), b.is_ok());
    assert!(matches!(
        fs::read_to_string(root.path().join("file"))
            .unwrap()
            .as_str(),
        "first" | "second"
    ));
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
}
#[tokio::test]
async fn creation_never_overwrites_competitor_and_cancellation_never_writes() {
    let root = directory();
    let args =
        json!({"path":"new","expected_revision":"new","old_text":"","new_text":"new content"});
    let p = prepare(
        root.path(),
        "edit_file",
        args.clone(),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    fs::write(root.path().join("new"), "competitor").unwrap();
    assert!(
        p.execute()
            .await
            .unwrap_err()
            .to_string()
            .contains("no longer available")
    );
    assert_eq!(
        fs::read_to_string(root.path().join("new")).unwrap(),
        "competitor"
    );
    let cancel = CancellationToken::new();
    let mut args = args;
    args["path"] = json!("cancelled");
    let p = prepare(root.path(), "edit_file", args.clone(), cancel.clone())
        .await
        .unwrap();
    cancel.cancel();
    assert!(p.execute().await.is_err());
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
    args["path"] = json!("created");
    execute(root.path(), "edit_file", args).await.unwrap();
    assert_eq!(
        fs::read_to_string(root.path().join("created")).unwrap(),
        "new content"
    );
}
#[tokio::test]
async fn ancestor_replaced_with_symlink_during_approval_is_refused() {
    let root = directory();
    let outside = directory();
    fs::create_dir(root.path().join("nested")).unwrap();
    fs::write(root.path().join("nested/file"), "original").unwrap();
    fs::write(outside.path().join("file"), "outside").unwrap();
    let p = prepare(
        root.path(),
        "edit_file",
        edit("nested/file", "original", "new"),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    fs::remove_dir_all(root.path().join("nested")).unwrap();
    symlink(outside.path(), root.path().join("nested")).unwrap();
    assert!(
        p.execute()
            .await
            .unwrap_err()
            .to_string()
            .contains("Symlinks")
    );
    assert_eq!(
        fs::read_to_string(outside.path().join("file")).unwrap(),
        "outside"
    );
}
#[tokio::test]
async fn stale_approved_edit_becomes_actionable_tool_failure_without_effects() {
    let root = directory();
    fs::write(root.path().join("file"), "original").unwrap();
    let p = FakeProvider::new(vec![
        response(vec![
            tool_call("edit_file", edit("file", "original", "new")),
            ProviderEvent::Done,
        ]),
        answer(),
    ]);
    let c = runtime(root.path(), p);
    let run = c.submit("Edit".into()).unwrap();
    let a = approval(&c).await;
    fs::write(root.path().join("file"), "external change").unwrap();
    c.resolve_approval(&run.operation_id, &a.id, true);
    complete(run).await;
    assert_eq!(outcomes(&c), [ToolOutcome::Failed]);
    assert!(
        c.snapshot().messages[2]
            .text()
            .contains("changed while approval")
    );
    assert_eq!(
        fs::read_to_string(root.path().join("file")).unwrap(),
        "external change"
    );
}
#[tokio::test]
async fn shell_requires_approval_uses_workspace_combines_output_and_reports_failure() {
    let root = directory();
    let p = prepare(
        root.path(),
        "shell",
        json!({"command":"pwd; printf out; printf err >&2","timeout_seconds":3}),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    assert!(p.approval().unwrap().contains("Timeout: 3 seconds"));
    assert!(p.approval().unwrap().contains("pwd;"));
    let out = p.execute().await.unwrap();
    for text in [
        "Exit code: 0",
        "out",
        "err",
        &fs::canonicalize(root.path()).unwrap().to_string_lossy(),
    ] {
        assert!(out.contains(text));
    }
    let error = execute(
        root.path(),
        "shell",
        json!({"command":"printf 'failed output'; exit 7"}),
    )
    .await
    .unwrap_err()
    .to_string();
    assert!(error.contains("Exit code: 7") && error.contains("failed output"));
}
#[tokio::test]
async fn shell_environment_fixture() {
    let Ok(root) = std::env::var("EXEC_TEST_ENV_FIXTURE") else {
        return;
    };
    let output = execute(
        std::path::Path::new(&root),
        "shell",
        json!({"command":"printf '%s' \"${EXEC_TOOL_TEST_SECRET-unset}\""}),
    )
    .await
    .unwrap();
    assert!(output.contains("unset"));
    assert!(!output.contains("synthetic-test-value") && !output.contains("injected"));
}
#[tokio::test]
async fn shell_does_not_inherit_secrets_or_startup_injection() {
    let root = directory();
    let startup = root.path().join("startup.sh");
    fs::write(&startup, "printf injected").unwrap();
    let status = tokio::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "shell_environment_fixture"])
        .env("EXEC_TEST_ENV_FIXTURE", root.path())
        .env("EXEC_TOOL_TEST_SECRET", "synthetic-test-value")
        .env("BASH_ENV", startup)
        .status()
        .await
        .unwrap();
    assert!(status.success());
}
#[tokio::test]
async fn shell_bounds_large_output_while_draining() {
    let root = directory();
    let out=execute(root.path(),"shell",json!({"command":"printf 'first\n'; head -c 200000 /dev/zero | tr '\\0' x; printf '\nlast'"})).await.unwrap();
    assert!(out.len() <= 32768);
    for s in ["first", "last", "Output truncated"] {
        assert!(out.contains(s));
    }
}
#[tokio::test]
async fn shell_timeout_terminates_invocation_retaining_diagnostics() {
    let root = directory();
    let start = Instant::now();
    let error = execute(
        root.path(),
        "shell",
        json!({"command":"printf started; sleep 30","timeout_seconds":1}),
    )
    .await
    .unwrap_err()
    .to_string();
    assert!(
        error.contains("timed out") && error.contains("started"),
        "{error}"
    );
    assert!(start.elapsed() < Duration::from_secs(4));
}
#[tokio::test]
async fn shell_cancellation_cleans_process_group_including_term_resistant_child() {
    let root = directory();
    let cancel = CancellationToken::new();
    let p=prepare(root.path(),"shell",json!({"command":"trap '' TERM; sleep 30 & child=$!; printf '%s' \"$child\" > child.pid.tmp; mv child.pid.tmp child.pid; wait","timeout_seconds":5}),cancel.clone()).await.unwrap();
    let task = tokio::spawn(p.execute());
    let pid = wait_file(&root.path().join("child.pid")).await;
    cancel.cancel();
    assert!(
        task.await
            .unwrap()
            .unwrap_err()
            .to_string()
            .contains("interrupted")
    );
    let status = execute(
        root.path(),
        "shell",
        json!({"command":format!("ps -o stat= -p {} || true",pid.parse::<u32>().unwrap())}),
    )
    .await
    .unwrap();
    let state = status.lines().skip(1).collect::<String>();
    let state = state.trim();
    assert!(
        state.is_empty() || state == "(no output)" || state.starts_with('Z'),
        "Child still running: {state}"
    );
}
#[tokio::test]
async fn real_shell_cancellation_retains_diagnostics_and_stops_inference() {
    let root = directory();
    let p = FakeProvider::new(vec![response(vec![
        tool_call(
            "shell",
            json!({"command":"printf started; printf ready > ready; sleep 30","timeout_seconds":5}),
        ),
        ProviderEvent::Done,
    ])]);
    let c = runtime(root.path(), p.clone());
    let run = c.submit("Run".into()).unwrap();
    let a = approval(&c).await;
    c.resolve_approval(&run.operation_id, &a.id, true);
    wait_file(&root.path().join("ready")).await;
    c.cancel(&run.operation_id);
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(p.count(), 1);
    assert_eq!(outcomes(&c), [ToolOutcome::Interrupted]);
    assert!(c.snapshot().messages[2].text().contains("started"));
    assert!(
        c.snapshot().messages[2]
            .text()
            .contains("may have had effects")
    );
}
#[tokio::test]
async fn runtime_denial_never_starts_real_shell() {
    let root = directory();
    let p = FakeProvider::new(vec![
        response(vec![
            tool_call("shell", json!({"command":"touch must-not-exist"})),
            ProviderEvent::Done,
        ]),
        answer(),
    ]);
    let c = runtime(root.path(), p);
    let run = c.submit("Run".into()).unwrap();
    let a = approval(&c).await;
    c.resolve_approval(&run.operation_id, &a.id, false);
    complete(run).await;
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    assert_eq!(outcomes(&c), [ToolOutcome::Denied]);
}
struct WrappedShell {
    conversation: Arc<Mutex<Option<Arc<Conversation>>>>,
}
struct WrappedPrepared {
    inner: Box<dyn PreparedTool>,
    conversation: Arc<Mutex<Option<Arc<Conversation>>>>,
}
#[async_trait::async_trait]
impl Tool for WrappedShell {
    fn definition(&self) -> ToolDefinition {
        exec_agent::tools::create_shell_tool().definition()
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        Ok(Box::new(WrappedPrepared {
            inner: exec_agent::tools::create_shell_tool()
                .prepare(args, context)
                .await?,
            conversation: self.conversation.clone(),
        }))
    }
}
#[async_trait::async_trait]
impl PreparedTool for WrappedPrepared {
    fn approval(&self) -> Option<&str> {
        self.inner.approval()
    }
    async fn execute(self: Box<Self>) -> Result<String> {
        let result = self.inner.execute().await?;
        assert!(result.starts_with("Exit code: 0"));
        let c = self.conversation.lock().unwrap().as_ref().unwrap().clone();
        assert!(c.cancel(&c.snapshot().operation.unwrap().id));
        Ok(result)
    }
}
async fn cancel_boundary(executor: bool) {
    let root = directory();
    let reference = Arc::new(Mutex::new(None::<Arc<Conversation>>));
    let p = FakeProvider::new(vec![response(vec![
        tool_call(
            "shell",
            json!({"command":"printf effect >> effects; printf '%s' $$ > shell.pid","timeout_seconds":2}),
        ),
        ProviderEvent::Done,
    ])]);
    let tools = if executor {
        vec![Arc::new(WrappedShell {
            conversation: reference.clone(),
        }) as Arc<dyn Tool>]
    } else {
        create_workspace_tools()
    };
    let mut config = options(p.clone(), tools);
    config.workspace = root.path().to_string_lossy().into();
    if !executor {
        let reference = reference.clone();
        config.checkpoint = Some(checkpoint(move |r| {
            let reference = reference.clone();
            async move {
                if r.operation.as_ref().is_some_and(|o| o.state.active())
                    && r.messages.iter().any(|m| matches!(m, Message::Tool { .. }))
                {
                    let c = reference.lock().unwrap().as_ref().unwrap().clone();
                    assert!(c.cancel(&r.operation.unwrap().id));
                }
                Ok(())
            }
        }));
    }
    let c = Conversation::new(config, None).unwrap();
    *reference.lock().unwrap() = Some(c.clone());
    let (_, mut events) = c.subscribe();
    let run = c.submit("Run once".into()).unwrap();
    let id = run.operation_id.clone();
    let a = approval(&c).await;
    c.resolve_approval(&id, &a.id, true);
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    assert_eq!(
        fs::read_to_string(root.path().join("effects")).unwrap(),
        "effect"
    );
    assert_eq!(p.count(), 1);
    let kinds = event_kinds(&mut events);
    assert_eq!(
        kinds
            .iter()
            .filter(|e| matches!(e, EventKind::ToolStarted { .. }))
            .count(),
        1
    );
    assert_eq!(
        kinds
            .iter()
            .filter(|e| matches!(e, EventKind::ToolFinished { .. }))
            .count(),
        1
    );
    assert_eq!(
        outcomes(&c),
        [if executor {
            ToolOutcome::Interrupted
        } else {
            ToolOutcome::Completed
        }]
    );
    assert!(!c.busy());
    assert!(!c.cancel(&id));
    assert!(c.snapshot().active_tool_call_id.is_none());
    *reference.lock().unwrap() = None;
}
#[tokio::test]
async fn cancellation_at_real_executor_return_preserves_effects_once() {
    cancel_boundary(true).await;
}
#[tokio::test]
async fn cancellation_at_real_result_publication_preserves_effects_once() {
    cancel_boundary(false).await;
}
