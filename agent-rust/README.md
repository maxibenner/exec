# Exec agent — Rust

Rust migration of [`../agent`](../agent), with the same functionality and API v1. The TypeScript implementation remains unchanged. This is a standalone library and executable, not a wrapper around Node or an agent framework. The Swift app is unchanged and is not connected to this service.

## Build and run

Rust 1.93 or newer, macOS or Linux, and `/bin/bash` are required. If rustup is installed but Cargo is not on your PATH, run `source "$HOME/.cargo/env"` first.

```sh
cd agent-rust
cargo build --locked --release
cargo test --locked --all-targets
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check

./target/release/exec-agent --help
# Provision DEEPSEEK_API_KEY securely in the environment, or a private credentials.json.
./target/release/exec-agent serve
# File/shell tools are an explicit opt-in:
./target/release/exec-agent --profile /absolute/private/profile serve --workspace-tools
```

See [API.md](API.md) for credentials, all CLI commands, HTTP/NDJSON contracts, approvals, and recovery. Cargo.lock is committed; production requires no Node installation. Tests use fake providers/transports, synthetic credentials, temporary profiles, real local sockets, and real child processes. They never access your Keychain or call a live model.

## Modules

| Module | Responsibility |
|---|---|
| `core/types.rs` | Provider-neutral messages, tools, models, operations and events; serde wire names retain API v1 |
| `core/conversation.rs` | Streamed conversation loop, sequential tools, exact approvals, cooperative cancellation and checkpoints |
| `core/record.rs` | Versioned record validation, context integrity and conservative restart recovery |
| `core/events.rs` | Nonblocking, bounded observer delivery; reconnect by snapshot rather than replay |
| `manager.rs` | Independent concurrent conversations and durable catalog ownership |
| `storage.rs` | Single-owner JSON profiles, serialized atomic checkpoints, locking and directory sync |
| `providers/` | DeepSeek HTTP/SSE, request validation, model discovery and startup-only credentials |
| `tools/` | Revision-checked file operations, literal search, approved bash commands and process-group cleanup |
| `service.rs` | Private Unix-socket HTTP/NDJSON API, composition and orderly shutdown |
| `client.rs`, `terminal.rs` | Transport-only client and escaped/reconciled terminal transcript |
| `main.rs` | Foreground service and interactive/scriptable CLI; no second agent loop |

Async work uses Tokio. Small explicit traits (`ChatProvider`, `Tool`, `PreparedTool`, `Checkpoint`, `ConversationStore`) keep providers, runtime, storage and UI/transport separate. Rust-owned data replaces defensive JavaScript cloning at interfaces. Snapshots and events are independent owned values; shared event frames are immutable.

## Embedding

```rust,no_run
use exec_agent::{core::ConversationOptions, manager::AgentManager};
use std::sync::Arc;

async fn run(provider: Arc<dyn exec_agent::core::ChatProvider>) -> exec_agent::Result<()> {
    let manager = AgentManager::default();
    let conversation = manager.create(ConversationOptions::new(provider, "model-id", "/absolute/workspace")).await?;
    let (_snapshot, mut events) = conversation.subscribe();
    let submitted = conversation.submit("Hello".into())?;
    // Consume events concurrently if you need live updates or approvals.
    // resolve_approval(operation_id, approval_id, approved) authorizes one exact action.
    // cancel(operation_id) requests cleanup, not immediate ownership release.
    let operation = submitted.completion.await.map_err(|_| exec_agent::Error::Internal)?;
    assert!(!operation.state.active());
    drop(events);
    manager.close().await
}
```

`submit` is synchronous in-memory acceptance, not a durable receipt. Dropping the completion receiver or an observer detaches; it does not cancel the runner. Use explicit cancellation, await settlement, then close the manager. As with any async Rust API, await catalog/store operations to completion; do not abort the enclosing task during a durable mutation. Service request handlers remain owned independently of client disconnects for this reason.

A prepared tool is consumed by execution, preventing accidental reuse. Providers and executors must honor their `CancellationToken`; the runtime does not drop an in-flight executor to simulate cleanup. A noncooperative embedded adapter can keep a conversation busy. Observer delivery never calls application code while holding runtime state. Slow observers are disconnected at the byte/event bound and must explicitly subscribe again.

## Preserved behavior and limits

- One active operation per conversation, concurrent independent conversations, streamed text, finite step limit (32 by default), no hidden prompt queue.
- Finalized tool calls get paired results for success, denial, failure, interruption, or non-execution. Partial/failed assistant responses stay visible but never become completed provider context. Tool calls are withheld until the entire provider response completes successfully.
- Exact, single-use approvals; no client connected means wait. Cancellation stays possible until final checkpoint commit begins. Tool executor ownership includes cancellation cleanup, never merely saved intent.
- No automatic inference, credential, mutation, tool, or checkpoint retries. Errors expose safe diagnostics rather than raw provider bodies or transport exceptions.
- Concrete DeepSeek origin only, non-thinking text/function calls, explicit `thinking: {type: "disabled"}` and `reasoning_effort: "none"`. Supported finish reason **and** `[DONE]` are required; unexpected reasoning fails.
- DeepSeek: 120-second default deadline (configurable up to 900), 16 MiB request/stream bound, 256 KiB SSE frames, 4 MiB text, 64 calls with 32 KiB argument JSON, and 128 KiB model discovery responses. Redirects, cookies, retries and ambient proxies are disabled.
- File reads: regular UTF-8 files up to 1 MiB, 1–400 numbered lines, SHA-256 full-file revision, 32 KiB output. Listing: one directory, at most 2,000 entries. Search: case-sensitive single-line literal, bounded depth/time/entries/matches/output, hidden/dependency/build entries skipped, incompleteness reported.
- Edits: exact unique replacement (including overlapping-match rejection), matching revision, approval before effects, revalidation before commit, serialized writes, exclusive no-overwrite creation. POSIX owner/group/mode are preserved; ACLs and extended attributes are not retained. Do not use for metadata-sensitive files.
- Shell: approved exact command/workspace, clean explicit environment, default 120-second timeout (1–900), combined stdout/stderr, first/last 15,000 bytes for truncated output. No full-log retention. TERM then KILL cleanup owns the process group through escalation; background jobs are killed even after successful shell exit. Escaped descendants are not contained; pipe draining is bounded.

File tools check path components and use no-follow file opens. As in the sketch, external ancestor-replacement/final-check races remain possible: these tools are **not a sandbox**. Shell commands and external editors are outside the internal edit lock. Same-user processes can still access same-user credentials.

## Persistence and recovery

API v1 JSON names and version-1 checkpoint records are retained, including `operationID`, `callID`, `activeToolCallID`, and `executingToolID`. Native Rust APIs use snake_case. Both implementations can read completed records written by the other; never run both against one profile simultaneously.

Profiles use a `.lock` directory, one validated `<UUID>.json` file per conversation, `0700` new directories, `0600` checkpoints, same-directory staging, file sync, atomic rename and directory sync. Corrupt/linked/unsupported/oversized records fail startup rather than being discarded. The limit is 16 MiB per record. This is local single-owner storage, not a network database or hostile-filesystem sandbox.

Checkpoints preserve user input before inference, in-flight responses, finalized calls, approval state, execution intent, each result, and terminal state. The first partial delta is saved, then at most once per second as deltas arrive. A crash can lose the unsaved text tail. Terminal success is published only after its save succeeds.

Restart marks unfinished work interrupted, clears approvals/live tool ownership, and fills missing results conservatively. Saved intent means an action **may have had effects**; later calls were not executed. Recovery itself is saved before publishing the manager. Nothing is replayed. Failed saves latch an error and block new submissions; failed deletion closes retained runner references until reload.

Normal service shutdown removes its socket and lock. A crash deliberately leaves ownership recovery to the operator: verify the old service **and its tool processes** have stopped, then remove only that profile's stale `service.sock` and `conversations/.lock`. Never steal a lock based on PID or age. Orphaned staging files are ignored, not promoted. Restart does not terminate orphaned shells from an abrupt service crash.

## Verification and scope

[TEST_PARITY.md](TEST_PARITY.md) maps the original test groups to the Rust suite and explains the test counts. The API was also smoke-tested in both directions with the original TypeScript client/service, using a fake provider and isolated profiles.

Verified on macOS with Rust 1.93.1. Live DeepSeek authentication/service compatibility, interactive TTY behavior, Linux deployment, machine power-loss guarantees, remote access and Swift integration remain unverified. Automated mocks do not establish live provider compatibility.

The sketch's intentionally absent features remain absent: credential onboarding, OpenAI subscription access, full shell logs, authenticated remote serving, plugins/skills infrastructure and Swift client integration. No agent framework or speculative features were added.
