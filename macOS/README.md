<p align="center">
  <img src="Resources/Glass_Icon.png" alt="Exec glass app icon" width="64" height="64">
</p>

# Exec

A minimal, native macOS app for AI chat and coding. Built with Swift and SwiftUI, with keyboard shortcuts for moving between conversations and slash commands for changing settings without leaving the composer.

Exec supports OpenAI subscriptions through ChatGPT/Codex sign-in and DeepSeek through an API key. Connect both at the same time and switch models within any conversation using `/model`.

Work with local files, review edits, and run shell commands. You can also search the web, read pages, generate images, and share screenshots. Conversations save locally and can run side by side or in separate windows.

## Get started

Requires macOS 14+, Xcode 26 or later (including the Swift toolchain and Icon Composer asset compiler), and either a ChatGPT account with Codex access or a DeepSeek API key. Build from source; builds are not notarized for distribution.

```sh
./scripts/build-app.sh
open dist/Exec.app
```

Open **Settings → Providers** and use **+** to add OpenAI or DeepSeek. OpenAI opens browser sign-in; DeepSeek opens a secure API-key sheet. Select a connection and use **−** to remove it. To replace credentials, remove the provider and add it again. Use `/model` to select a model and `/workspace` to choose a local project. DeepSeek models and reasoning levels are discovered from its API, rather than pinned in the app.

Quit any running copy before opening a rebuilt app. Sign-in uses local port 1455.

## Keyboard controls

| Action | Shortcut |
| --- | --- |
| New conversation | ⌘T |
| Switch conversations | ⌘1 through ⌘9, in sidebar order |
| Detach conversation | ⌘D |
| Move detached conversation back | ⌘W |
| Delete conversation | ⌘⇧Delete |
| Send a message / steer the active turn | Return |
| Stop current operation | Escape or ⌘. |
| Open command menu | `/` in the composer |

Slash commands: `/model`, `/reasoning`, `/auto-approve`, `/compact`, `/workspace`, `/finder`, `/terminal`.

The sidebar starts collapsed when the local library has no chats. Its initial layout is chosen from existing saved-session filenames before the window appears, without waiting for account restoration or adding another cache. Its toolbar toggle remains available; later session changes do not override your choice. The empty window shows “No Sessions”; provider availability is shown in an open chat.

Switching conversations keeps background work running. Drag images into the composer to attach them.

You can send new instructions while the assistant is working. They appear in the conversation immediately and reach the model after the current tool or model response finishes. Remaining tools from the old response are marked as not executed, and an unstarted approval is withdrawn so the assistant can reconsider. Send does not cancel a running operation; use Stop for that. After a stop or failure, unconsumed messages remain saved with the conversation and are included when you send your next message, without automatically restarting work.

For OpenAI conversations, choose a separate **Search model** in **Settings → Models & Tools → Web Search**. It defaults to GPT-6 Luna and uses its default reasoning level. DeepSeek conversations use [DeepSeek's native search API](https://api-docs.deepseek.com/api/search/), with queries limited to 128 Unicode characters. Search results use the same source cards and transcript storage for either provider. Searches never fall back to another provider. A missing model never silently moves an existing conversation to another service. Temporary refresh failures retain cached models only for providers that are still authenticated.

Settings → Models & Tools retains model and reasoning preferences per provider while displaying only usable defaults. Web search shows a model picker for OpenAI and the native service name for DeepSeek; image generation shows availability for each connected provider. Account allowances appear in Settings → Usage, independently of the current chat model. The composer shows Context 0% until context usage is reported. Connecting another provider does not override a valid selection. The default title model is **Same as chat model**; an unavailable override also resolves to the chat model. Provider-specific settings, including the OpenAI search-model picker, appear only when applicable.

Tools follow the provider captured at the start of a turn, even if you change the model picker while it runs. File operations, shell commands and direct page fetching use the existing local executor and approval rules. Image generation and manual compaction remain OpenAI-only. Screenshots and image attachments require an image-capable model; incompatible image history is rejected before inference, rather than silently stripped. DeepSeek does not currently compact history automatically; switch models or start a new session if its context limit is reached.

Conversations belong to one local library, seeded from the existing Codex identity on upgrade so current sessions remain readable. Disconnecting a provider does not delete conversations or sign out another provider. All windows and model pickers immediately exclude its models. When a chosen model becomes unavailable, the composer replaces its model/reasoning line with **Model unavailable** in red and keeps the draft. With no providers connected, that line reads **Connect a provider in settings** in red. Submission is disabled in either case; use `/model` to choose an available model, or add a provider in Settings. The composer has no model dropdown, connection button, or refresh button. New chats use an available default, but an already chosen model is never automatically replaced, even in an empty chat. Switching models sends the visible conversation to the selected provider; opaque reasoning and response state stay separate by provider and credential identity. An active turn finishes with its captured model; a later submitted turn uses the new selection.

Codex usage diagnostics are saved with each conversation inside its entry in the provider-state envelope. That entry contains `requestUsage` records for main responses, searches, and compaction: requested/reported models, timestamps, outcomes, input/output tokens, cached input, and reasoning tokens when supplied. Missing counts remain unknown; cached input and reasoning are subsets, not additional tokens. Incomplete requests can remain `unconfirmed` when no final accounting was saved. These records are never sent back as model context.

`allowanceObservations` records fresh Codex account-wide readings before and after each OpenAI run, including stopped or failed runs. A failed reading is saved as unavailable; it never substitutes a cached display value. These readings may include concurrent activity in other apps and are not an exact per-session charge. Existing sessions remain readable; historical usage cannot be reconstructed.

### Local-first startup

Saved conversations open independently of model discovery and usage requests. On subsequent launches, Exec reads the last-known account presentation, models and usage from disk **before requesting credentials from Keychain**. The existing session files supply sidebar order, selection and the selected transcript; no second transcript cache is created. The same window, sidebar and conversation objects remain mounted when the restored account matches.

This initial presentation is read-only: cached identity never authorizes sending, tools, auto-approval or session writes. Credentials and opaque conversation context must restore successfully before work can run. A missing or different account discards the old presentation and invalidates its cache; credential-read failures offer an explicit retry. After local restoration, model and usage refreshes do not block navigation or draft editing.

Exec keeps the disposable cache in `~/Library/Caches/Exec/AccountMetadata/`, including an owner-only `startup.json` with the last-used provider, account display name and opaque conversation identity—not tokens or authentication responses. This local presentation data is not encrypted. Model catalogs can be reused for up to seven days, and usage values for up to five minutes, excluding expired usage windows. Expired usage keeps its cached row layout but displays unknown values. Successful refreshes update the cache; failures retain usable cached values. Disconnected providers are filtered from cached model choices. Disconnecting the last provider clears the startup account pointer; the local library remains available. Missing or corrupt caches fall back to normal local restoration. Model catalogs refresh automatically on app startup and when providers are added or removed. There is no manual refresh control; discovery does not block navigation or draft editing.

On macOS 15 and later, Exec remembers the main window's normal size, position and display in local preferences. The next window uses that geometry during initial placement, while native scene restoration stays disabled to avoid its startup height correction. No post-appearance resize is used. Changed or disconnected displays are handled by fitting the window onto an available display. Full-screen transitions do not overwrite the normal frame; relaunch opens a normal window. The first launch of this version starts a new geometry record. macOS 14 retains native restoration.

## Access and storage

- Auto-approval starts on for workspace conversations. Turn it off with `/auto-approve` to review edits and shell commands. Commands run with your user permissions, outside a sandbox, and can affect files beyond the workspace. Stopping does not undo changes.
- Shell results keep up to 32 KiB of combined stdout/stderr. Larger results show the first and last 16 KiB, with the omitted byte count. The full captured output is saved in an owner-only `<session UUID>.shell-logs/` directory alongside that session's snapshot, and the result includes its absolute path. Inspect it with a separate shell command (subject to the normal approval setting), not by rerunning the original command. Logs survive app restarts and are removed when their session is deleted; cleanup failure prevents successful session deletion and is reported for explicit recovery. These logs may contain sensitive command output and are not encrypted. Small outputs are not saved separately. Cancellation or errors before returning a result discard unpublished logs; timeouts can return the output captured before termination. If session storage is unavailable or saving fails, the preview and command status are still returned with an explicit log-unavailable notice. Older `exec-shell-*/output.log` files in the system temporary directory are not associated with a session and remain subject to manual or OS cleanup; they are not migrated or deleted based on transcript paths.
- Requested files, workspace instructions, attachments, tool results, and screenshots may be sent to the provider. Screenshots require macOS Screen Recording permission. Web searches send queries to the provider; page fetching contacts websites directly.
- Credentials stay in separate Keychain items (`openai.codex.session` and `deepseek.api-key`). Conversations and managed images are stored in `~/Library/Application Support/Exec/`, without app-level encryption. Unsent drafts and attachments do not survive restarts.
- On first launch, Exec renames the former `Application Support/Harness/` folder to `Exec/`, preserving its contents and permissions. Quit older copies before upgrading. If both folders exist, startup reports a conflict rather than merging or overwriting data; back up both folders before resolving it. Historical tool-result text may still mention the old absolute image paths, but saved image attachments use relative paths and remain readable. Older builds do not know about the new location.
- Settings remain in the `local.swift-harness` UserDefaults domain, and credentials retain the same Keychain service. These compatibility identifiers (including the bundle ID) are intentionally unchanged so existing settings and sign-in remain available.
- Exec uses a Codex-compatible backend, not OpenAI's public API. Usage limits and feature availability depend on your account and model; service support can change.

## Provider structure

`ChatProvider` remains the boundary for UI and orchestration. `ProviderRegistry` owns shared authentication and model catalogs; `MultiProvider` gives each conversation isolated child providers and routes model IDs. Existing OpenAI IDs are unchanged; DeepSeek IDs use a `deepseek/` prefix only inside Exec. Wire requests receive the native model ID.

`Providers/DeepSeek/` owns API-key validation, [model discovery](https://api-docs.deepseek.com/api/list-models/), bounded HTTP transport, streaming Chat Completions, native search, and opaque reasoning state. Completed reasoning is replayed according to [DeepSeek's tool-calling contract](https://api-docs.deepseek.com/guides/thinking_mode/). Interrupted streams never publish tool calls or commit reasoning, and inference/authentication failures are not automatically retried. The providers share only neutral SSE framing and core message/tool types. No new dependencies are required.

## Development

No third-party dependencies. Open `Package.swift` in Xcode, or run:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Tests use isolated stores and fake transports, not your Keychain or live model calls. Live-service behavior still needs manual validation.

For consistent Keychain access across rebuilds, configure a stable signing certificate:

```sh
security find-identity -v -p codesigning
git config --local exec.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```

Without a configured identity, builds use ad-hoc signing and may prompt for Keychain access again. Never commit signing keys or credentials.
