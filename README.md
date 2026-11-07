<p align="center">
  <img src="Resources/AppIcon.png" alt="Exec app icon" width="64" height="64">
</p>

# Exec

A minimal, native macOS app for AI chat and coding. Built with Swift and SwiftUI, with keyboard shortcuts for moving between conversations and slash commands for changing settings without leaving the composer.

Exec currently supports OpenAI subscriptions through ChatGPT/Codex sign-in. No API key is needed. Support for other providers is planned.

Work with local files, review edits, and run shell commands. You can also search the web, read pages, generate images, and share screenshots. Conversations save locally and can run side by side or in separate windows.

## Get started

Requires macOS 14+, a Swift 6 toolchain (Xcode or Apple Command Line Tools), and a ChatGPT account with Codex access. Build from source; builds are not notarized for distribution.

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
| Send or queue a message | Return |
| Stop current operation | Escape or ⌘. |
| Open command menu | `/` in the composer |

Slash commands: `/model`, `/reasoning`, `/auto-approve`, `/compact`, `/workspace`, `/finder`, `/terminal`.

Switching conversations keeps background work running. Drag images into the composer to attach them.

Choose a separate **Search model** in **Settings → General → Web Search**. It defaults to GPT-6 Luna and applies to searches in existing and new conversations. Searches use that model's default reasoning level, independently of the chat model and reasoning setting.

## Access and storage

- Auto-approval starts on for workspace conversations. Turn it off with `/auto-approve` to review edits and shell commands. Commands run with your user permissions, outside a sandbox, and can affect files beyond the workspace. Stopping does not undo changes.
- Requested files, workspace instructions, attachments, tool results, and screenshots may be sent to the provider. Screenshots require macOS Screen Recording permission. Web searches send queries to the provider; page fetching contacts websites directly.
- Credentials stay in Keychain. Conversations and managed images are stored in `~/Library/Application Support/Harness/` (the app's former name), without app-level encryption. Unsent drafts and attachments do not survive restarts.
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
