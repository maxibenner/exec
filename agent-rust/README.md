# Exec agent — Rust

Rust migration of [`../agent`](../agent), now extending API v1 with the agreed [backend parity](PARITY.md) scope implemented. The TypeScript implementation remains unchanged. This is a standalone library and executable, not a wrapper around Node or an agent framework. The Swift app is unchanged and is not connected to this service.

## Guiding principles

See [GUIDING_PRINCIPLES.md](GUIDING_PRINCIPLES.md) for the architectural, execution-safety, persistence, API, security, and verification principles carried forward from the original system.

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
| `core/settings.rs`, `workspace_instructions.rs` | Durable execution settings and manager-owned safe instruction loading |
| `core/events.rs` | Nonblocking, bounded observer delivery; reconnect by snapshot rather than replay |
| `manager.rs` | Independent concurrent conversations and durable catalog ownership |
| `storage.rs` | Single-owner JSON profiles, serialized atomic checkpoints, locking and directory sync |
| `providers/` | DeepSeek and OpenAI wire formats, authentication, discovery, account/search/image services and opaque context |
| `core/images.rs`, `images.rs` | Neutral image references/reader contract and private validated immutable assets |
| `native.rs` | Manager-owned optional local frontend capability broker; never captures screens |
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
    let submitted = manager.submit(&conversation.id, "Hello".into()).await?;
    // Consume events concurrently if you need live updates or approvals.
    // resolve_approval(operation_id, approval_id, approved) authorizes one exact action.
    // cancel(operation_id) requests cleanup, not immediate ownership release.
    let operation = submitted.completion.await.map_err(|_| exec_agent::Error::Internal)?;
    assert!(!operation.state.active());
    drop(events);
    manager.close().await
}
```

`Conversation::submit` is synchronous in-memory acceptance, not a durable receipt.
`AgentManager::submit` first loads root AGENTS.md for a new conversation, then delegates
to the same runner. Embedders calling the runner directly may supply an instruction
snapshot through `submit_with_instructions`; the runner never reads host instructions
itself. The first accepted input freezes even an absent AGENTS.md. Both entry points
checkpoint input and the frozen configuration before inference. Settings updates are
idle-only, remain owned when the caller detaches, and publish only after a successful save.
A failed settings-save acknowledgement blocks further mutations/inference until reload.

Acceptance is not a durable receipt. Dropping the completion receiver or an observer detaches; it does not cancel the runner. Use explicit cancellation, await settlement, then close the manager. As with any async Rust API, await catalog/store operations to completion; do not abort the enclosing task during a durable mutation. Service request handlers remain owned independently of client disconnects for this reason.

A prepared tool is consumed by execution, preventing accidental reuse. Providers and executors must honor their `CancellationToken`; the runtime does not drop an in-flight executor to simulate cleanup. A noncooperative embedded adapter can keep a conversation busy. Observer delivery is nonblocking and never calls frontend code while holding runtime state. Optional embedded provider/tool metadata hooks must be fast and non-reentrant. Slow observers are disconnected at the byte/event bound and must explicitly subscribe again.

## Preserved behavior and limits

- One active operation per conversation, concurrent independent conversations, streamed text, finite step limit (32 by default), explicit operation-targeted steering (no hidden prompt queue).
- Finalized tool calls get paired results for success, denial, failure, interruption, or non-execution. Partial/failed assistant responses stay visible but never become completed provider context. Tool calls are withheld until the entire provider response completes successfully.
- New conversations default to persisted auto-approval. Manual mode uses exact, single-use approvals and waits even with no client connected. Auto mode still prepares, validates, checkpoints intent and checks cancellation before effects. Cancellation stays possible until final checkpoint commit begins; executor ownership includes cleanup.
- No automatic inference, credential, mutation, tool, or checkpoint retries. Errors expose safe diagnostics rather than raw provider bodies or transport exceptions.
- DeepSeek adapter: text/function calls and capability-gated images with model-default or explicit reasoning effort. Explicit `none` disables thinking and rejects unexpected reasoning. Supported finish reason **and** `[DONE]` are required; incomplete state is never committed.
- DeepSeek: 120-second default deadline (configurable up to 900), 16 MiB request/stream bound, 256 KiB SSE frames, 4 MiB text, 64 calls with 32 KiB argument JSON, and 128 KiB model discovery responses. Redirects, cookies, retries and ambient proxies are disabled.
- File reads: regular UTF-8 files up to 1 MiB, 1–400 numbered lines, SHA-256 full-file revision, 32 KiB output. Listing: one directory, at most 2,000 entries. Search: case-sensitive single-line literal, bounded depth/time/entries/matches/output, hidden/dependency/build entries skipped, incompleteness reported.
- Edits: exact unique replacement (including overlapping-match rejection), matching revision, approval before effects, revalidation before commit, serialized writes, exclusive no-overwrite creation. POSIX owner/group/mode are preserved; ACLs and extended attributes are not retained. Do not use for metadata-sensitive files.
- Shell: approved exact command/workspace, clean explicit environment, default 120-second timeout (1–900), combined stdout/stderr, first/last 15,000 bytes for truncated output. Managed services retain private logs up to 64 MiB, with explicit partial-log reporting on quota/write/drain failure. TERM then KILL cleanup owns the process group through escalation; background jobs are killed even after successful shell exit. Escaped descendants are not contained; pipe draining is bounded.

File tools check path components and use no-follow file opens. As in the sketch, external ancestor-replacement/final-check races remain possible: these tools are **not a sandbox**. Shell commands and external editors are outside the internal edit lock. Same-user processes can still access same-user credentials.

## Persistence and recovery

API v1 names such as `operationID`, `callID`, `activeToolCallID`, and `executingToolID` remain. Checkpoints now use **version 7** (including image references, opaque provider context, token measurements and resource ownership), requiring execution settings and frozen instruction state. Version-2/3/4/5/6 records remain readable. Version-1 records are read conservatively with manual approval and no newly loaded AGENTS.md context; their next save writes version 7. The TypeScript sketch cannot read these new records. Never share an active profile or downgrade its writer. This is not a Swift-store migration.

Profiles use a `.lock` directory, one validated `<UUID>.json` file per conversation, `0700` new directories, `0600` checkpoints, same-directory staging, file sync, atomic rename and directory sync. Corrupt/unsupported/oversized owned regular records appear as unreadable sessions and are preserved; valid sessions remain available. Linked/special/foreign-owned entries, uncertain file identity, lost store ownership and corrupt library metadata still fail startup. The limit is 16 MiB per record. This is local single-owner storage, not a network database or hostile-filesystem sandbox.

Checkpoints preserve user input before inference, in-flight responses, finalized calls, approval state, execution intent, each result, and terminal state. The first partial delta is saved, then at most once per second as deltas arrive. A crash can lose the unsaved text tail. Terminal success is published only after its save succeeds.

Restart marks unfinished work interrupted, clears approvals/live tool ownership, and fills missing results conservatively. Saved intent means an action **may have had effects**; later calls were not executed. Recovery itself is saved before publishing the manager. Nothing is replayed. Failed saves latch an error and block new submissions; failed deletion closes retained runner references until reload.

Normal service shutdown removes its socket and lock. A crash deliberately leaves ownership recovery to the operator: verify the old service **and its tool processes** have stopped, then remove only that profile's stale `service.sock` and `conversations/.lock`. Never steal a lock based on PID or age. Orphaned staging files are ignored, not promoted. Restart does not terminate orphaned shells from an abrupt service crash.

## Verification and scope

The agreed backend checklist in [PARITY.md](PARITY.md) is implemented. The original Swift
app remains unchanged; its API integration and native capture adapter are a separate phase.
Remote access, Keychain and Swift-store migration are excluded. Automatic title generation
and per-run before/after allowance observations remain explicitly deferred.

The standalone registry composes DeepSeek and OpenAI subscription adapters with isolated
opaque conversation contexts. DeepSeek API-key onboarding uses private JSON or environment
credentials. OpenAI uses browser PKCE/OIDC sign-in, private rotating credentials, and
single-flight refresh with a durable consumed-token marker. An uncertain refresh requires
reconnection, never reuse of the possibly consumed token. Missing credentials do not block
history. Model/account caches are account-scoped, private, and expose freshness/staleness.

The runner owns manual/automatic OpenAI compaction without replacing visible history.
Neutral image references and private immutable assets support uploaded input, generated
images and optional frontend screenshots. Fork/delete/release preserve shared ownership.
Native capture requires explicit host nomination of a local Swift process, kernel peer
identity, a live channel, frontend-owned OS permission and separate session permission.
There is no headless capture or remote fallback. Registration is single-use, permissions
are transient, and cancellation/disconnect invalidates exact correlated results.

Search, balances, current allowance/reset information, public-page fetch, images, context
usage, compaction and native capability transport have typed API/client coverage and CLI
controls where appropriate. The CLI does not implement native screen capture. `scraper`
handles bounded HTML parsing; `image` validates PNG/JPEG assets; `ring` verifies OIDC
signatures; `base64` encodes bounded image/JWT payloads. No agent framework was introduced.

Automated verification uses fake providers/transports, synthetic credentials, isolated
stores, local sockets and subprocesses. OIDC tests generate an ephemeral RSA fixture with
OpenSSL (test-time prerequisite only). Live OpenAI/DeepSeek compatibility, browser sign-in,
subscription image quota behavior, native Swift/OS permissions, interactive TTY behavior,
Linux deployment and machine power-loss guarantees remain unverified. Mocks do not verify
live services. No Swift files or code-signing settings were changed.

See [ARCHITECTURE_AUDIT.md](ARCHITECTURE_AUDIT.md) for the final guidance review and
ownership/verification evidence.