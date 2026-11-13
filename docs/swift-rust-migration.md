# Swift frontend → Rust backend migration

## Scope and ownership

The macOS app now bundles and automatically launches the existing `exec-agent` executable and connects over its loopback HTTP/NDJSON API at `http://127.0.0.1:8765`. The initial cutover did not change Rust. A separate feature restored backend-owned automatic titles. This follow-up fixes one provider transport compatibility issue (valid OpenAI event streams without a Content-Type header); API contracts and backend ownership are unchanged.

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
| New conversation/workspace | Inherited workspace stays selectable once until explicit choice or session start; Rust supplies durable identity/canonical path |
| Send | Upload selected images, submit one turn, reconcile acceptance; no inference retries |
| Send while responding | Exact-operation text steering |
| Stop / Escape | Exact-operation cancellation; retain ownership until cleanup/terminal state |
| Approve Once / Deny | Exact conversation + operation + approval IDs, one request per decision |
| Auto mode / reasoning / model / prompt | Rust settings/model API, only when permitted by the service |
| Session rename, fork, delete, order | Rust catalog APIs; detached windows keep the same frontend session object |
| Provider add/remove | API-key entry sheet; OpenAI opens browser authentication directly, backed by Rust credential APIs |
| Context and account usage | Context follows Rust snapshots; account allowance refreshes only when Settings opens |
| Screenshots | Explicit `/screenshots` grant, HTTP native channel, exact correlated capture/results |
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

Rust owns the profile's `credentials.json`, `service.sock`, `conversations/`, images, logs and caches. Credentials are private **plaintext**, not Keychain-encrypted. The onboarding sheet has no explanatory auth/storage paragraph; this storage contract is documented here. GUI startup removes ambient `DEEPSEEK_API_KEY`/`OPENAI_SESSION_JSON` overrides from the child environment so onboarding manages this profile, not an inherited shell credential.

**No legacy Swift data, credentials, sessions, images or defaults are migrated or deleted.** Existing users reconnect providers in the same account UI. The new selected-session preference has a distinct key.

### Shutdown and recovery

Normal app termination sends SIGTERM to the owned service and waits for it to exit. Rust cancels work, reaps tool processes, settles writes and releases its listener and store lock. The app does not force-kill the helper, steal locks, replay pending work or resume inference on launch.

A crash/forced termination can leave a backend running, or a stale store lock and orphaned tool processes. Startup fails if port 8765 is occupied; it never attaches to another server. Follow the Rust recovery procedure in `agent-rust/API.md`: verify the old service **and its tool processes** have stopped before an operator removes stale ownership artifacts. There is no automatic recovery button that deletes them.

There is no socket path limit, endpoint discovery, authentication or port fallback. Any local process can access the API. Profile ownership/permissions and store locking are unchanged.

### Build-toolchain note

The build scripts disable release debug stripping (`CARGO_PROFILE_RELEASE_STRIP=none`). With the installed Rust/macOS combination, stripped proc-macro dylibs were rejected by dyld as a misaligned LINKEDIT string pool, misleadingly reported as a missing `zerofrom_derive` crate. Keeping symbols resolved this without modifying Rust sources, compiler artifacts or signing identity. Upstream report: <https://github.com/rust-lang/rust/issues/157750>.

## Minimal compatibility adjustments already made

These reflect current backend contracts; they are not replacement UI designs:

1. **Automatic session titles:** subsequently restored as backend-owned, isolated metadata inference, enabled by default via the library `automaticTitles` setting. Manual naming permanently prevents automatic replacement. Each accepted user turn may generate a title using the session model before chat inference, with a 15-second bound and no retry; title failures retain the existing/fallback title. Routine follow-ups are instructed to preserve the established topic. No title prompt or output enters conversation history.
2. **Idle-only backend mutations:** `/model`, `/reasoning` and `/auto-approve` can be chosen mid-turn. The latest settings are applied once idle, before queued `/compact` or `/fork` actions. Repeated pending actions coalesce; failures never replay mutations. A live approval is not implicitly resolved by changing the desired auto-mode. Rename stays idle-only. Stop discards pending action commands; Quit also prevents queued work from starting.
3. **Immutable workspace:** `/workspace` becomes inactive after an explicit choice or session start. A new conversation inherits the previous folder only as a suggestion and still permits one explicit choice. Its immutable Rust record is not created merely by inheriting that folder or changing model defaults. Sending, explicit selection, enabling screenshots, or saving a draft on navigation commits the workspace. Use New Conversation afterward; existing history is never rebound to another folder.

4. **Text-only steering:** image submissions during a response, and input during manual compaction, retain the draft and use the existing inline error presentation. They are not silently queued as later inference.
5. **Provider onboarding:** adding OpenAI opens browser auth directly, without an intermediate explanatory sheet. DeepSeek keeps only key entry and actions, without the auth/storage paragraph. Backend provider statuses have no personal account label, so the existing subtitle shows `Connected` instead of inventing an identity.
6. **Image generation routing/approval:** the standalone backend composes OpenAI image generation independently of the chat provider and requires approval in manual mode. The existing approval component displays the exact backend proposal with a generic action heading where no old shell/edit heading applies. The settings footer accurately identifies the OpenAI subscription. Swift does not bypass approval or select a different image provider.
7. **Input acceptance:** a submitted draft clears on backend acknowledgement, not before a local Swift checkpoint. An uncertain acknowledgement retains the draft and reconciles the snapshot without resubmitting. Inspect the transcript before explicitly resending it.
8. **Errors:** errors still use the existing inline error surface/account alert. Backend-safe diagnostic text is preserved; old provider-specific wording is not reconstructed from string matching.

Search-model preferences remain within the selected chat provider, preserving the existing disclosure/routing behavior rather than silently introducing cross-provider search.

## Native screenshots

The Swift frontend registers one live channel over the same unauthenticated HTTP API. There is no host nomination or peer/PID verification. Startup reports existing OS permission but never requests or grants it automatically. In the composer, `/screenshots` explicitly enables or disables screen sharing **for that conversation**. Enabling requests macOS Screen Recording permission if necessary. If macOS requires a restart after a grant, the existing inline error explains that; the app never bypasses TCC.

Only an enabled session with OS permission exposes `take_screenshot` to the model. Swift uses the existing ScreenCaptureKit implementation, returns typed window lists or image bytes, and echoes every backend correlation field unchanged. Window capture requires prior enumeration through the same session/channel, enforced by Rust. Screens and titles remain untrusted evidence. In manual approval mode each capture still needs `Approve Once`; there is no local approval bypass or misleading “Always for This Session” action. Auto mode alone never grants screen access.

Stop/cancellation, disable, OS revocation or channel disconnect prevents late capture results from being shared. No capture/result is retried. OS permission restoration does not re-enable sessions. Grants are transient, not restored on restart or inherited by forks. A disconnected channel requires a new app/backend launch and explicit session enablement, not an automatic registration retry.

## Remaining compatibility limits

### Compaction activity rows

Manual compaction is connected and cancellable; automatic compaction remains Rust-owned. The API exposes generic operation state and measured context usage, but no distinct automatic/manual compaction transcript events or durable activity rows. The renderer's existing compaction row component remains intact, but the adapter does not fabricate persisted `Compacting…`/completed rows or infer them from token counts.

**Decision needed:** a future backend event/transcript contract if the old activity-row behavior must be restored exactly.

### Account allowance policy

Before/after turn allowance observations are intentionally removed from the product requirements. Current allowance/reset information refreshes only when the user opens Settings, not on launch, account changes, or turn completion. The last fetched observation retains its timestamp; no per-turn quota attribution is invented.

### Offline model catalog startup

Rust owns account-scoped caches, but the current API does not expose a cache-only model catalog separate from `/v1/models` discovery. History is loaded before discovery and remains readable without credentials; the frontend does not restore the old Swift account/model cache. An offline-only catalog endpoint would be needed for identical first-frame cached model-picker behavior.

### Blank sessions without a model

Rust requires a model to create a durable session. A workspace/draft can remain local before any model is available, but it is not a persisted Rust conversation yet. Swift does not insert a fabricated model ID merely to create an empty record. A backend draft-session contract would be needed to preserve that edge case across restarts without a second conversation store.

## Verification

`./scripts/test.sh` passed **58 checks**. `./scripts/build-app.sh` succeeded with the configured stable signing certificate, including verification of the bundled helper and app.

Automated checks use isolated stores, synthetic transport fixtures and an actual local Rust subprocess with an empty credential environment. They never read the user's Keychain, configure a live provider, call a live model, open browser sign-in or capture the screen.

Verified:
- Deferred commands, coalescing, uncertain-settings failure gating, inherited workspace one-choice behavior and Settings-only usage refresh.
- Native capture correlation, cancellation discarding late results, no result retries, OS revocation and no implicit regrant.
- Existing native transcript/layout/selection/Markdown/tool-rendering checks.
- Snapshot/Unicode delta reconciliation without duplicate rows, exact approval correlation and single decision submission.
- Cancellation retains ownership/sleep prevention until terminal cleanup.
- Uncertain turn/configuration requests are not automatically repeated.
- Quit copy/buttons, repeated-Quit coalescing, Cancel behavior and waiting for backend shutdown.
- Real loopback HTTP/chunked NDJSON, disconnected provider state, session creation/settings/rename/order/fork/delete, image upload/read/release, safe disconnected-provider turn failure, detached deletion preserving main selection/drafts, and clean listener/store-lock release.
- Signed app/helper build and `codesign --verify --deep --strict` with the configured stable certificate.

Still manual/unverified:
- Live OpenAI browser authentication/rotation and reconnect UI; account removal/replacement. Other provider tools beyond the explicit live checks below, including quotas/exhaustion, remain unverified.
- Full interactive app startup/quit, multi-window visual comparison, long live streams and all failure dialogs against real providers.
- Interactive Screen Recording prompts/relaunch, real ScreenCaptureKit capture through the new session grant UI, and physical permission revocation. HTTP channel registration, grants/revocation and fork isolation are tested against an isolated actual Rust subprocess; capture itself is faked in automated tests.
- Installer/notarization/update distribution and Intel/universal builds.

Mocks and a disconnected real backend do not establish live provider compatibility. The retained renderer tests are meaningful regressions, not a claim that a person performed a complete pixel-by-pixel UI comparison.

### One-off authorized live checks (not automated tests)

Used the existing configured accounts only for this debugging session, with temporary conversations and synthetic inputs, no user project contents and no credential copies/logging. The original OpenAI error was reproduced as a successful SSE response lacking Content-Type; the Rust adapter now tolerates a missing header while rejecting explicitly incompatible types and requiring a valid completed stream. One end-to-end Rust plain-text turn completed after the fix.

Additional manual API checks all completed: OpenAI Unicode/multiline fenced text, follow-up context recall, text plus a synthetic red image (color recognized), image-only input, exact-operation text steering, and one explicitly approved image generation. The generated 1536×1024 image asset was retrieved and its byte count validated. DeepSeek Unicode text also completed. No inference or generation was retried. Temporary conversations and image references were deleted afterward and the service exited cleanly. These verify live backend behavior, not a full interactive Swift UI/TCC walkthrough.

The full isolated Rust test suite passed, including missing-header success, truncated stream failure and incompatible Content-Type rejection. Live credentials are never part of the long-term test suite.
