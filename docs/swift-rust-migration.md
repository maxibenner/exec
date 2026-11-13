# Swift frontend → Rust backend migration

## Scope and ownership

The macOS app now bundles and automatically launches the existing `exec-agent` executable and connects over its private Unix-socket HTTP/NDJSON API. **No Rust sources or API contracts were changed.**

Rust is the sole owner of:
- Provider credentials, browser authentication/token refresh, model discovery and account observations.
- Inference, tool selection/execution, approval decisions, operation-targeted steering/cancellation and compaction.
- Session records, instructions, defaults/order, titles, forks/deletion, checkpoints/recovery, image assets and shell logs.

Swift retains:
- The original native views, virtual transcript renderer, Markdown/diff/tool/image presentation, composer, sidebar, detached windows, keyboard commands, dialogs and selection/scroll state.
- Local unsent drafts and attachment normalization, local window/selected-session preferences, Finder/Terminal opening, and the updater.
- A provider-neutral account/catalog interface (`ChatProvider`), service DTO-to-presentation mapping, and transport/lifecycle code under `macOS/Sources/Exec/Backend/`.
- A presentation-only `ToolApprovalState`, not a tool executor.

The previous Swift provider implementations, OAuth/HTTP/SSE machinery, Keychain adapter, inference/tool loops, file/shell/search/fetch/image executors, conversation recovery/storage, and account metadata store have been removed. Obsolete tests of those implementations have been replaced with frontend/API integration tests. The old standalone lazy-preview builder depended on the removed stores and has been retired; it is not a production transcript path.

## Transcript renderer is retained

**There is no replacement SwiftUI `ScrollView`/`LazyVStack` transcript.** Production `TranscriptView.swift`, `TranscriptLayout.swift`, transcript navigation/selection code, Markdown rendering, diff views, image views and native scrolling machinery are retained. The backend adapter produces their existing `Message`, `ToolCall`, `ToolResult` and `ImageAttachment` values.

- Streamed text is applied to the matching message/operation ID.
- Full snapshots replace/reconcile state rather than append duplicate turns.
- Pending tool cards retain their row identity when their result arrives.
- Edit previews/results, search sources, fetched page bodies, image assets and explicit tool outcomes feed the existing presentations.
- Image loading does not roll streamed text back to an older snapshot.
- Native renderer regressions remain in the test suite: bounded mounted rows, row/measurement reuse, live resizing, scroll anchors, near-bottom behavior, sent-message navigation, selection, Markdown and tool disclosures.

## Connected flows

| Existing flow | Backend mapping |
|---|---|
| Open/reopen conversation | Snapshot + live events; reopening explicitly reconnects a lost observer |
| New conversation/workspace | Durable creation when workspace/model are known; Rust supplies identity/canonical path |
| Send | Upload selected images, submit one turn, reconcile acceptance; no inference retries |
| Send while responding | Exact-operation text steering |
| Stop / Escape | Exact-operation cancellation; retain ownership until cleanup/terminal state |
| Approve Once / Deny | Exact conversation + operation + approval IDs, one request per decision |
| Auto mode / reasoning / model / prompt | Rust settings/model API, only when permitted by the service |
| Session rename, fork, delete, order | Rust catalog APIs; detached windows keep the same frontend session object |
| Provider add/remove | Existing account sheet and browser flow, backed by Rust credential APIs |
| Context and account usage | Rust measurements, with the existing display components |
| Input/generated images | Rust immutable assets, loaded for the existing attachment/image views |
| Quit | Existing confirmation copy/buttons; await Rust shutdown/reaping/checkpoint completion before replying to AppKit |

New sessions retain top-of-sidebar insertion and persistent ordering through `/v1/library`; selection remains a frontend preference. Background session activity does not select another conversation. Deleting a detached conversation does not change the main window selection.

## Installation and storage

Build and test from `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
open dist/Exec.app
```

Xcode 26+ and Rust/Cargo 1.93+ are required to build. End users do **not** need Cargo or a separately installed/running service. The app includes `Contents/MacOS/exec-agent`, built from this checkout with `Cargo.lock`, signed before the containing app with the same configured certificate. There is no fallback to an arbitrary installed executable or a different signing identity.

The new private profile is:

```text
~/Library/Application Support/Exec/Agent/
```

Rust owns the profile's `credentials.json`, `service.sock`, `conversations/`, images, logs and caches. Credentials are private **plaintext**, not Keychain-encrypted. The existing account sheet now states this accurately. GUI startup removes ambient `DEEPSEEK_API_KEY`/`OPENAI_SESSION_JSON` overrides from the child environment so onboarding manages this profile, not an inherited shell credential.

**No legacy Swift data, credentials, sessions, images or defaults are migrated or deleted.** Existing users reconnect providers in the same account UI. The new selected-session preference has a distinct key.

### Shutdown and recovery

Normal app termination sends SIGTERM to the owned service and waits for it to exit. Rust cancels work, reaps tool processes, settles writes and removes its own socket/lock. The app does not force-kill the helper, steal locks, replay pending work or resume inference on launch.

A crash/forced termination can leave a backend running, or a stale socket/lock and orphaned tool processes. Startup refuses an existing socket. Follow the Rust recovery procedure in `agent-rust/API.md`: verify the old service **and its tool processes** have stopped before an operator removes stale ownership artifacts. There is no automatic recovery button that deletes them.

The socket path must fit Rust's 100-byte limit. An unusually long home path produces a startup error rather than silently selecting a different store.

### Build-toolchain note

The build scripts disable release debug stripping (`CARGO_PROFILE_RELEASE_STRIP=none`). With the installed Rust/macOS combination, stripped proc-macro dylibs were rejected by dyld as a misaligned LINKEDIT string pool, misleadingly reported as a missing `zerofrom_derive` crate. Keeping symbols resolved this without modifying Rust sources, compiler artifacts or signing identity. Upstream report: <https://github.com/rust-lang/rust/issues/157750>.

## Minimal compatibility adjustments already made

These reflect current backend contracts; they are not replacement UI designs:

1. **Automatic session titles:** removed the Session Titles settings section and generation machinery, as explicitly requested. Manual rename and prompt-derived fallback titles remain.
2. **Idle-only mutations:** model/reasoning/auto-mode controls, rename and fork are unavailable while the conversation is running. The backend does not support changing live approval policy or forking a running boundary.
3. **Immutable workspace:** once Rust has created a session, its workspace cannot be changed. The existing picker remains available before creation; use New Conversation for a different workspace afterward.
4. **Text-only steering:** image submissions during a response, and input during manual compaction, retain the draft and use the existing inline error presentation. They are not silently queued as later inference.
5. **Credential disclosure:** the existing account sheet's Keychain paragraph now describes private plaintext storage. Backend provider statuses have no personal account label, so the existing subtitle shows `Connected` instead of inventing an identity.
6. **Image generation routing/approval:** the standalone backend composes OpenAI image generation independently of the chat provider and requires approval in manual mode. The existing approval component displays the exact backend proposal with a generic action heading where no old shell/edit heading applies. The settings footer accurately identifies the OpenAI subscription. Swift does not bypass approval or select a different image provider.
7. **Input acceptance:** a submitted draft clears on backend acknowledgement, not before a local Swift checkpoint. An uncertain acknowledgement retains the draft and reconciles the snapshot without resubmitting. Inspect the transcript before explicitly resending it.
8. **Errors:** errors still use the existing inline error surface/account alert. Backend-safe diagnostic text is preserved; old provider-specific wording is not reconstructed from string matching.

Search-model preferences remain within the selected chat provider, preserving the existing disclosure/routing behavior rather than silently introducing cross-provider search.

## Unsupported or incomplete parity: decisions required, not implemented

### Native screenshots — permission-flow integration is deferred

Rust supports a native capture *protocol*, but it requires a host-nominated process, live registered channel, prior reported OS permission and an explicitly enabled per-session desktop capability **before the tool is exposed**. The old Swift flow requested OS/tool permission only when the model called the tool, with `Approve Once` / `Always for This Session` and auto-mode handling.

Those are not interchangeable permission models. This migration does **not** nominate/register a native capture channel, silently turn on desktop access, request Screen Recording permission on every launch, or run a Swift screenshot tool outside Rust. Consequently, `take_screenshot` is not available from this app yet. The existing native capture helper and existing screenshot presentation are retained as frontend code, but are not invoked by a hidden fallback.

**Decision needed:** approve a minimal explicit capability-enablement flow using the current UI, or revise the Rust preparation/permission contract in a separate task. Until then, no claims of screenshot feature parity or verified TCC behavior are made.

### Compaction activity rows

Manual compaction is connected and cancellable; automatic compaction remains Rust-owned. The API exposes generic operation state and measured context usage, but no distinct automatic/manual compaction transcript events or durable activity rows. The renderer's existing compaction row component remains intact, but the adapter does not fabricate persisted `Compacting…`/completed rows or infer them from token counts.

**Decision needed:** a future backend event/transcript contract if the old activity-row behavior must be restored exactly.

### Before/after allowance observations

Current allowance/reset information is connected. Rust explicitly defers per-run before/after allowance observations, so Swift does not retain the old side-channel requests/storage or manufacture quota attribution. A backend observation contract is required before restoring that behavior.

### Offline model catalog startup

Rust owns account-scoped caches, but the current API does not expose a cache-only model catalog separate from `/v1/models` discovery. History is loaded before discovery and remains readable without credentials; the frontend does not restore the old Swift account/model cache. An offline-only catalog endpoint would be needed for identical first-frame cached model-picker behavior.

### Blank sessions without a model

Rust requires a model to create a durable session. A workspace/draft can remain local before any model is available, but it is not a persisted Rust conversation yet. Swift does not insert a fabricated model ID merely to create an empty record. A backend draft-session contract would be needed to preserve that edge case across restarts without a second conversation store.

## Verification

`./scripts/test.sh` passed **51 checks**. `./scripts/build-app.sh` succeeded with the configured stable signing certificate, including verification of the bundled helper and app.

Automated checks use isolated stores, synthetic transport fixtures and an actual local Rust subprocess with an empty credential environment. They never read the user's Keychain, configure a live provider, call a live model, open browser sign-in or capture the screen.

Verified:
- Existing native transcript/layout/selection/Markdown/tool-rendering checks.
- Snapshot/Unicode delta reconciliation without duplicate rows, exact approval correlation and single decision submission.
- Cancellation retains ownership/sleep prevention until terminal cleanup.
- Uncertain turn/configuration requests are not automatically repeated.
- Quit copy/buttons, repeated-Quit coalescing, Cancel behavior and waiting for backend shutdown.
- Real Unix HTTP/chunked NDJSON, disconnected provider state, session creation/settings/rename/order/fork/delete, image upload/read/release, safe disconnected-provider turn failure, detached deletion preserving main selection/drafts, and clean service socket/lock removal.
- Signed app/helper build and `codesign --verify --deep --strict` with the configured stable certificate.

Still manual/unverified:
- Live OpenAI browser authentication/rotation, DeepSeek credentials, live model/tool/service behavior and subscription image quota.
- Full interactive app startup/quit, multi-window visual comparison, long live streams and all failure dialogs against real providers.
- Native capture registration/TCC/session-permission UX (deferred above).
- Installer/notarization/update distribution and Intel/universal builds.

Mocks and a disconnected real backend do not establish live provider compatibility. The retained renderer tests are meaningful regressions, not a claim that a person performed a complete pixel-by-pixel UI comparison.
