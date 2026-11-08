<p align="center">
  <img src="Resources/Glass_Icon.png" alt="Exec glass app icon" width="64" height="64">
</p>

# Exec

A minimal, native macOS app for AI chat and coding. Built with Swift and SwiftUI, with keyboard shortcuts for moving between conversations and slash commands for changing settings without leaving the composer.

Exec currently supports OpenAI subscriptions through ChatGPT/Codex sign-in. No API key is needed. Support for other providers is planned.

Work with local files, review edits, and run shell commands. You can also search the web, read pages, generate images, and share screenshots. Conversations save locally and can run side by side or in separate windows.

## Get started

Requires macOS 14+, Xcode 26 or later (including the Swift toolchain and Icon Composer asset compiler), and a ChatGPT account with Codex access. Build from source; builds are not notarized for distribution.

```sh
./scripts/build-app.sh
open dist/Exec.app
```

Choose **Connect to Codex**, sign in through your browser, then select your ChatGPT workspace and model. Use `/workspace` to choose a local project.

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

Switching conversations keeps background work running. Drag images into the composer to attach them.

You can send new instructions while the assistant is working. They appear in the conversation immediately and reach the model after the current tool or model response finishes. Remaining tools from the old response are marked as not executed, and an unstarted approval is withdrawn so the assistant can reconsider. Send does not cancel a running operation; use Stop for that. After a stop or failure, unconsumed messages remain saved with the conversation and are included when you send your next message, without automatically restarting work.

Choose a separate **Search model** in **Settings → General → Web Search**. It defaults to GPT-6 Luna and applies to searches in existing and new conversations. Searches use that model's default reasoning level, independently of the chat model and reasoning setting.

Usage diagnostics are saved with each conversation. The provider state contains `requestUsage` records for main responses, searches, and compaction: requested/reported models, timestamps, outcomes, input/output tokens, cached input, and reasoning tokens when supplied. Missing counts remain unknown; cached input and reasoning are subsets, not additional tokens. Incomplete requests can remain `unconfirmed` when no final accounting was saved. These records are never sent back as model context.

`allowanceObservations` records fresh account-wide readings before and after each run, including stopped or failed runs. A failed reading is saved as unavailable; it never substitutes a cached display value. These readings may include concurrent activity in other apps and are not an exact per-session charge. Existing sessions remain readable; historical usage cannot be reconstructed.

### Local-first startup

Saved conversations open independently of model discovery and usage requests. On subsequent launches, Exec reads the last-known account presentation, models and usage from disk **before requesting credentials from Keychain**. The existing session files supply sidebar order, selection and the selected transcript; no second transcript cache is created. The same window, sidebar, footer and conversation objects remain mounted when the restored account matches.

This initial presentation is read-only: cached identity never authorizes sending, tools, auto-approval or session writes. Credentials and opaque conversation context must restore successfully before work can run. A missing or different account discards the old presentation and invalidates its cache; credential-read failures offer an explicit retry. After local restoration, model and usage refreshes do not block navigation or draft editing.

Exec keeps the disposable cache in `~/Library/Caches/Exec/AccountMetadata/`, including an owner-only `startup.json` with the last-used provider, account display name and opaque conversation identity—not tokens or authentication responses. This local presentation data is not encrypted. Model catalogs can be reused for up to seven days, and usage values for up to five minutes, excluding expired usage windows. Expired usage keeps its cached row layout but displays unknown values. Successful refreshes update the cache; failures retain usable cached values. Signing out removes that account's cache and startup pointer. Missing or corrupt caches fall back to normal local restoration. **Settings → Account → Refresh Models** retries discovery without restoring or blocking conversations.

## Access and storage

- Auto-approval starts on for workspace conversations. Turn it off with `/auto-approve` to review edits and shell commands. Commands run with your user permissions, outside a sandbox, and can affect files beyond the workspace. Stopping does not undo changes.
- Requested files, workspace instructions, attachments, tool results, and screenshots may be sent to the provider. Screenshots require macOS Screen Recording permission. Web searches send queries to the provider; page fetching contacts websites directly.
- Credentials stay in Keychain. Conversations and managed images are stored in `~/Library/Application Support/Exec/`, without app-level encryption. Unsent drafts and attachments do not survive restarts.
- On first launch, Exec renames the former `Application Support/Harness/` folder to `Exec/`, preserving its contents and permissions. Quit older copies before upgrading. If both folders exist, startup reports a conflict rather than merging or overwriting data; back up both folders before resolving it. Historical tool-result text may still mention the old absolute image paths, but saved image attachments use relative paths and remain readable. Older builds do not know about the new location.
- Settings remain in the `local.swift-harness` UserDefaults domain, and credentials retain the same Keychain service. These compatibility identifiers (including the bundle ID) are intentionally unchanged so existing settings and sign-in remain available.
- Exec uses a Codex-compatible backend, not OpenAI's public API. Usage limits and feature availability depend on your account and model; service support can change.

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
