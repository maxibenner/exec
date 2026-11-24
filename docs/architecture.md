# Architecture

Exec has one authoritative Rust execution engine and a thin native Swift client. The backend is a library plus an HTTP-service executable, not a CLI client or a wrapper around an agent framework.

## Source boundaries

| Location | Responsibility |
|---|---|
| `backend/src/core/` | Provider-neutral contracts, conversation loop, events, settings, context and record validation |
| `backend/src/manager.rs` | Concurrent conversation lifecycle and durable catalog ownership |
| `backend/src/providers/` | Provider wire formats, authentication, discovery, account services and opaque context |
| `backend/src/tools/` | Exact action preparation, approval descriptions, validation and execution |
| `backend/src/storage.rs` | Private single-owner profiles and atomic checkpoints |
| `backend/src/images.rs`, `files.rs`, `shell_logs.rs` | Private image/file assets and retained subprocess output |
| `backend/src/native.rs` | Optional frontend capability broker, never headless capture |
| `backend/src/service.rs`, `service_auth.rs` | HTTP/NDJSON boundary, authentication and composition |
| `backend/src/main.rs` | Standalone launcher and signal-driven shutdown |
| `macOS/Sources/Exec/Application/` | App entry point, startup and window/session lifecycle |
| `macOS/Sources/Exec/Backend/` | Helper lifecycle, HTTP transport and DTO-to-presentation mapping |
| `macOS/Sources/Exec/Core/` | Provider-neutral frontend models and presentation contracts |
| `macOS/Sources/Exec/Features/` | Chat, sessions, settings, transcript and updates |
| `macOS/Sources/Exec/UI/` | Shared rendering, colors and window geometry |
| `macOS/Sources/Exec/Platform/` | Native screen capture |

These folders organize existing modules; they do not introduce additional packages, runtimes, services or dependencies. Prefer small explicit interfaces and composition. Add plugin infrastructure only for a concrete requirement.

## Ownership and safety invariants

- Rust owns inference, tools, approvals, provider credentials, settings, instructions, titles, history, forks, deletion, assets, checkpoints and recovery. Clients own presentation state, not competing execution state or durable transcripts.
- The runtime depends on `ChatProvider`, not provider wire formats. It remains usable without HTTP through `exec_agent::manager::AgentManager` and `core::ConversationOptions`.
- Independent conversations may run concurrently; each has one active operation. Explicit operation-targeted steering queues input for the next model decision, not a second runner. It does not invalidate the in-flight response, its tool calls or their approvals; only explicit denial/cancellation stops actions.
- A completed provider response is not necessarily a completed task. `ProviderEvent::Continue` marks an explicitly intermediate response; the runtime checkpoints it and advances within the same operation and step budget, even without tools. `Done` can settle only with no tool calls and no pending steering. Stream failures never request continuation, and restored/completed operations never resume automatically. Delegation returns only after successful operation settlement; parent result checkpointing still precedes child cleanup.
- Sub-agents are ordinary conversations with immutable parent/session-operation/tool-call provenance. Blocking delegation reuses the runner, persistence, approvals and cancellation; children start with fresh context, cannot recursively delegate, and share the parent workspace without filesystem isolation.
- Tools prepare exact actions without effects. Manual approval is single-use and identifies the conversation, operation and action. Persisted auto mode still validates, checkpoints intent and honors cancellation. Auto mode permits screenshot requests but cannot bypass native OS permission.
- The core filters tool schemas centrally for every inference and compaction request to the name-ordered intersection of session selection and runtime capabilities. That same snapshot supplies append-only, trusted provider-neutral availability context, checkpointed only when the effective set changes at a request boundary. Historical calls/results and opaque provider state survive catalog changes; reduced prompt-cache reuse is possible, not a context reset. Availability context has stable IDs but is not part of UI transcripts; adapters use developer/system roles, not provider-native allowlists. Execution still rejects disabled/unavailable tools before preparation, including changes after request construction. Selection mutations remain durable and idle-only; clients may coalesce desired changes locally during active work.
- Cancellation retains ownership until provider/tool cleanup and final persistence settle. It cannot undo effects. Dropping an observer or completion receiver only detaches; embedders must explicitly cancel, await settlement, and close the manager.
- The runtime never automatically retries inference, tools, rotating-token exchanges, mutations or uncertain checkpoint writes. A failed acknowledgement does not prove the operation had no effects. Agent instructions permit diagnosing clear local setup failures and rerunning safe verification commands after correcting the environment, but prohibit blind retries and approval bypasses. Interrupted or partially completed operations require state inspection; retries that may duplicate external effects, incur charges or consume credentials require renewed user authorization. Tool-specific no-retry restrictions still apply.
- Failed/interrupted assistant output remains in provider context with an explicit incomplete-response annotation, never as a successful reply or executable partial calls. Streaming output stays out of context. Finalized tool calls receive outcomes, including denial, failure, interruption and non-execution. Execution begins only after the complete provider response validates.
- Checkpoint input before inference and intent before effects; publish terminal success only after saving it. Recovery marks unfinished work interrupted and never replays it. Corrupt records are preserved; uncertain ownership and failed writes fail closed.
- Commands, events, settlement and durability are distinct guarantees. An accepted command or observed tool result is not itself a durable receipt.
- Reconnect with a current snapshot and live events, not command replay. Slow observers are disconnected rather than blocking execution. A lost native channel revokes its capability and invalidates correlated results.
- Bound streams, files, subprocess output and execution time. Keep secrets out of workspaces, logs and tool environments. Workspaces and approvals are **not a sandbox** against same-user processes or escaped descendants.

## Runtime tool capability previews

Core `RuntimeToolAvailability` is the canonical local status: `available` and an optional
owned, fixed short `reason`. Builtins implement `Tool::availability(&ToolContext)`; the
existing `Tool::available` boolean wrapper remains the central schema filter and execution
guard. Capability does not incorporate saved disabled-tool selection or approval policy.
Image generation depends only on the independent image-provider connection. Search uses
a provider-neutral local availability method; the provider registry owns selected-route
resolution and connection/disconnect gating, without discovery, authentication or fallback.

Authenticated `POST /v1/tools/availability` previews requested names against supplied
client-effective model/search-model settings. Session queries inspect that conversation's
actual executors, preserving child executor removal; default queries reuse the manager's
normal composition including delegation. Missing executors have a fixed unavailable status.
An idle `ToolContext` has empty operation/call IDs, no images and a fresh cancellation token;
no fabricated conversation, persistence or provider request is needed. Library/snapshot
schemas and deny-list validation are unchanged. See the [API contract](api.md#runtime-tool-availability).

Native capture availability checks a live session binding, or any connected frontend for a
no-session preview. It never checks OS permission or grants consent, selects/binds a frontend,
or requests capture. First-use permission remains reachable through the normal approved tool
path. The manager attaches the existing `ChangeHub` weakly to `NativeHub`; registration,
binding/revocation and disconnect publish catalog invalidations only after native locks are
released. Clients refresh open selectors on those existing hints and effective-setting changes,
without polling or storing runtime capability as selection state.

## Native frontend

Swift retains the virtualized native transcript, Markdown/diff/image/tool presentation, composer, sidebar, detached windows, selection and scroll state. It also owns unsent drafts, attachment normalization, local window/selection preferences, Finder/Terminal actions and Sparkle updates. Snapshot reconciliation preserves message identity. Like iOS, macOS uses the shared incremental `/sync` cursor and prefix-proof contract rather than subscribing to full-history conversation events. It backfills older pages before publication to retain complete transcript navigation and tool-call/result pairing, then polls the changed suffix every 200 ms while active and every two seconds while idle. Unchanged snapshots do not trigger UI reconciliation; cancellation and mutations remain explicit, single-submit operations.

The app always launches its own bundled helper at `127.0.0.1:8765`, with separate ephemeral API and native credentials passed through the child environment. It strips standalone endpoint/token overrides and ambient provider credentials. There is no external-backend selection, port fallback or automatic attachment to an existing listener. Quit awaits owned-helper cancellation, child reaping and checkpoint completion; it does not force-kill the helper.

Standalone hosting remains configurable for other trusted clients. The API token is a shared administrator credential, not per-user scopes. The Rust listener is HTTP-only: remote use requires HTTPS termination or an encrypted restricted tunnel, without upstream mutation retries or NDJSON buffering. Browser Origin/Fetch-Metadata requests are rejected. See the [API guide](api.md) for configuration and recovery.

### Storage and recovery

The app profile is `~/Library/Application Support/Exec/Agent/`. Rust owns its private **plaintext** credentials, conversations, images, logs and caches. No legacy Swift data or Keychain entries are migrated or removed. Never share an active profile or downgrade its writer.

Normal shutdown releases the listener and store lock. After a crash, verify that the old backend **and its tool processes** have stopped before removing only that profile's stale `conversations/.lock`. Never steal a lock by PID/age, promote orphan staging files or replay interrupted work. A crash may leave orphan tool processes; restart does not terminate them.

### Waiting

`wait` is a one-shot tool in `backend/src/tools/wait.rs`, not a scheduler. It accepts a bounded duration, a short display description, and a wake prompt. After the normal intent checkpoint, its executor awaits a cancellation-aware timer; expiry returns the prompt as ordinary tool output and the same operation continues. Periodic checks use successive wait/check calls within the existing step budget. A wait must be the only tool call in its response and requires a remaining model step; invalid batches fail before any tool executes.

The existing single-operation and sequential-tool invariants guarantee at most one live wait per session. Snapshots derive `activeToolName` from live tool ownership, including in catalog summaries; there is no separate wait registry, persisted deadline, or frontend timer. The operation stays `running`. macOS retains the pending tool spinner and displays a green stopwatch in its session row. Waiting counts as active for Stop, deletion confirmation, and quit. Cancellation, deletion, and helper shutdown interrupt waits and await settlement; restart never re-arms them. Steering queues normally and does not wake a timer early. This is not an OS wake scheduler and cannot promise checks while the machine is forcibly asleep or Exec is closed.

### Screenshots

Capture requires a separately authenticated live native channel and macOS Screen Recording permission. The macOS app binds its local adapter before sending a local turn, without prompting for OS access. It also explicitly opts into remote-conversation binding: before a remote turn with screenshots selected, the backend binds an unbound top-level chat to the sole opted-in live adapter and notifies it on the ordered native channel before any capture request. Remote clients cannot grant native capabilities themselves. Manual mode asks for screen access on the first screenshot tool call per conversation; later calls reuse that consent. Auto mode allows requests without a chat prompt and does not create manual consent. An authorized request triggers the native OS permission dialog if needed. Window capture requires prior enumeration through the same session/channel. Swift echoes exact correlation fields; cancellation, revocation and disconnect invalidate late results. Grants are transient and not inherited by forks; manual consent is never restored automatically. The backend does not capture screens itself.

## Current behavior and limitations

- Automatic titles are backend-owned and enabled by default. Manual names are never replaced; title inference is bounded, isolated from history and never retried.
- Model/reasoning/auto-mode changes chosen mid-turn coalesce and apply once idle, before queued compaction/fork commands. A desired auto-mode change does not resolve a live approval. Stop discards queued actions; quit prevents them from starting.
- The backend permits durable workspace changes before the first accepted turn and rejects them permanently afterward, including after failure or cancellation. Existing history is never rebound to another folder. Frontends retain their existing creation flows; macOS still limits workspace selection to unsaved conversations, and iOS chooses the folder before creation.
- Steering is text-only. Images submitted during a response, or input during manual compaction, retain the draft rather than silently scheduling another turn.
- OpenAI Responses maps the last message's documented `phase: commentary` to intermediate completion and `final_answer` to final output, preserving original items/phases in opaque replay context. Item/delta events alone never complete a response. Missing/null phase retains legacy completion behavior; unknown phases fail closed. Undocumented channel fields and progress-like wording are not completion signals. If a provider omits the distinction or labels progress as final, Exec cannot reliably detect it and does not invent a continuation. See the [Responses reference](https://developers.openai.com/api/reference/resources/responses/methods/create).
- Drafts clear on backend acknowledgement. Uncertain acceptance retains the draft and reconciles state without resubmission; inspect history before explicitly resending.
- Account allowance refreshes only when Settings opens. No per-turn quota attribution is invented.
- Manual/automatic compaction is backend-owned: OpenAI keeps its native strategy, while DeepSeek opts into shared text summarization. Snapshots report model capability; the frontend does not infer it from provider IDs or token counts. Both strategies preserve the transcript and share operation/checkpoint/cancellation handling. Native failures never trigger summary retries. Compaction activity uses ordinary assistant/tool rows.
- History remains readable without credentials. There is no cache-only model catalog endpoint for identical offline picker startup behavior.
- A model is required to create a durable session. A workspace/draft without a model remains local, not a fabricated persisted conversation.

## Verification boundaries

Automated tests use fake providers/transports, isolated profiles, synthetic credentials, local HTTP connections and real subprocesses. They cover authentication, native capability boundaries, approvals, cancellation, context integrity, persistence/recovery and native rendering regressions. They do not access the user's Keychain, call live models, open browser sign-in or capture the screen.

Historical one-off OpenAI/DeepSeek streaming and synthetic-image checks are not continuous live-service guarantees. Interactive OAuth/token rotation, full multi-window UX, physical Screen Recording permission changes, actual remote proxy/VPN deployment, Linux production deployment, notarization/update distribution, Intel/universal builds and machine power-loss durability require separate verification. Mocks do not verify live providers or OS permission UX.
