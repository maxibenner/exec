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
| `backend/src/images.rs`, `shell_logs.rs` | Private image assets and retained subprocess output |
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
- Independent conversations may run concurrently; each has one active operation. Explicit operation-targeted steering inserts text at safe boundaries, not a second runner.
- Tools prepare exact actions without effects. Manual approval is single-use and identifies the conversation, operation and action. Persisted auto mode still validates, checkpoints intent and honors cancellation. Auto mode never grants desktop access.
- Cancellation retains ownership until provider/tool cleanup and final persistence settle. It cannot undo effects. Dropping an observer or completion receiver only detaches; embedders must explicitly cancel, await settlement, and close the manager.
- Never automatically retry inference, tools, rotating-token exchanges, mutations or uncertain checkpoint writes. A failed acknowledgement does not prove the operation had no effects.
- Partial assistant output stays visible but never becomes completed provider context. Finalized tool calls receive outcomes, including denial, failure, interruption and non-execution. Execution begins only after the complete provider response validates.
- Checkpoint input before inference and intent before effects; publish terminal success only after saving it. Recovery marks unfinished work interrupted and never replays it. Corrupt records are preserved; uncertain ownership and failed writes fail closed.
- Commands, events, settlement and durability are distinct guarantees. An accepted command or observed tool result is not itself a durable receipt.
- Reconnect with a current snapshot and live events, not command replay. Slow observers are disconnected rather than blocking execution. A lost native channel revokes its capability and invalidates correlated results.
- Bound streams, files, subprocess output and execution time. Keep secrets out of workspaces, logs and tool environments. Workspaces and approvals are **not a sandbox** against same-user processes or escaped descendants.

## Native frontend

Swift retains the virtualized native transcript, Markdown/diff/image/tool presentation, composer, sidebar, detached windows, selection and scroll state. It also owns unsent drafts, attachment normalization, local window/selection preferences, Finder/Terminal actions and Sparkle updates. Snapshot reconciliation preserves message identity; streamed deltas target exact message/operation IDs.

The app always launches its own bundled helper at `127.0.0.1:8765`, with separate ephemeral API and native credentials passed through the child environment. It strips standalone endpoint/token overrides and ambient provider credentials. There is no external-backend selection, port fallback or automatic attachment to an existing listener. Quit awaits owned-helper cancellation, child reaping and checkpoint completion; it does not force-kill the helper.

Standalone hosting remains configurable for other trusted clients. The API token is a shared administrator credential, not per-user scopes. The Rust listener is HTTP-only: remote use requires HTTPS termination or an encrypted restricted tunnel, without upstream mutation retries or NDJSON buffering. Browser Origin/Fetch-Metadata requests are rejected. See the [API guide](api.md) for configuration and recovery.

### Storage and recovery

The app profile is `~/Library/Application Support/Exec/Agent/`. Rust owns its private **plaintext** credentials, conversations, images, logs and caches. No legacy Swift data or Keychain entries are migrated or removed. Never share an active profile or downgrade its writer.

Normal shutdown releases the listener and store lock. After a crash, verify that the old backend **and its tool processes** have stopped before removing only that profile's stale `conversations/.lock`. Never steal a lock by PID/age, promote orphan staging files or replay interrupted work. A crash may leave orphan tool processes; restart does not terminate them.

### Screenshots

Capture requires a separately authenticated live native channel, macOS Screen Recording permission and explicit per-conversation `/screenshots` enablement. Manual mode still requires approval for each capture. Window capture requires prior enumeration through the same session/channel. Swift echoes exact correlation fields; cancellation, revocation and disconnect invalidate late results. Grants are transient, are not inherited by forks, and are never restored automatically. The backend does not capture screens itself.

## Current behavior and limitations

- Automatic titles are backend-owned and enabled by default. Manual names are never replaced; title inference is bounded, isolated from history and never retried.
- Model/reasoning/auto-mode changes chosen mid-turn coalesce and apply once idle, before queued compaction/fork commands. A desired auto-mode change does not resolve a live approval. Stop discards queued actions; quit prevents them from starting.
- A new conversation can inherit a suggested workspace, but permits one explicit choice before becoming immutable. Existing history is never rebound to another folder.
- Steering is text-only. Images submitted during a response, or input during manual compaction, retain the draft rather than silently scheduling another turn.
- Drafts clear on backend acknowledgement. Uncertain acceptance retains the draft and reconciles state without resubmission; inspect history before explicitly resending.
- Account allowance refreshes only when Settings opens. No per-turn quota attribution is invented.
- Manual/automatic compaction is backend-owned, but distinct durable compaction activity rows are not exposed by the API. The frontend does not fabricate them from token counts.
- History remains readable without credentials. There is no cache-only model catalog endpoint for identical offline picker startup behavior.
- A model is required to create a durable session. A workspace/draft without a model remains local, not a fabricated persisted conversation.

## Verification boundaries

Automated tests use fake providers/transports, isolated profiles, synthetic credentials, local HTTP connections and real subprocesses. They cover authentication, native capability boundaries, approvals, cancellation, context integrity, persistence/recovery and native rendering regressions. They do not access the user's Keychain, call live models, open browser sign-in or capture the screen.

Historical one-off OpenAI/DeepSeek streaming and synthetic-image checks are not continuous live-service guarantees. Interactive OAuth/token rotation, full multi-window UX, physical Screen Recording permission changes, actual remote proxy/VPN deployment, Linux production deployment, notarization/update distribution, Intel/universal builds and machine power-loss durability require separate verification. Mocks do not verify live providers or OS permission UX.
