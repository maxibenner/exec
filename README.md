<p align="center">
  <img src="Resources/AppIcon.png" alt="Exec app icon" width="128" height="128">
</p>

# Exec

A native macOS app for chatting and coding with Codex. Built with Swift and SwiftUI—no extra runtimes, command-line agents, or third-party dependencies.

Use your **ChatGPT/Codex sign-in**, not an API key. Access and usage limits depend on your OpenAI account.

## What you can do

- **Chat your way.** Stream formatted replies, share images, and choose your model and reasoning level.
- **Work on projects.** Let Exec read files, make edits with inline diffs, and run shell commands.
- **Research and create.** Search the web with source links, read public web pages, generate images, and share desktop or window screenshots.
- **Keep work separate.** Run multiple conversations at once, each with its own workspace and settings, or detach a conversation into its own window.
- **Pick up where you left off.** Conversations save locally, and long chats automatically compact their model context.

## Get started

Requires **macOS 14+**, a **Swift 6 toolchain** (Xcode or Apple Command Line Tools), and a ChatGPT account with Codex access. Currently, Exec is built from source; builds are not notarized for distribution.

From the project directory:

```sh
./scripts/build-app.sh
open dist/Exec.app
```

1. Choose **Connect to Codex** and sign in through your browser.
2. Select your authorized ChatGPT workspace and a model.
3. Start chatting, or choose **Workspace…** beside the composer to work on a local project.

Quit any running copy before opening a rebuilt app. If sign-in cannot start, check that another sign-in is not using local port **1455**.

### Everyday controls

| Action | Control |
| --- | --- |
| New conversation | **⌘N** |
| Send a message (or queue it during a reply) | **Return** |
| Stop the current operation | **Escape** or **⌘.** |
| Detach a conversation | **⌘D** |
| Change model, reasoning, or approvals | Type **/** in the composer |
| Attach images | Drag them into the composer |
| Rename or delete a conversation | Right-click its sidebar row |

Switching conversations does not stop background work. Use the account menu at the bottom of the sidebar to refresh models, reconnect, or sign out.

## Before you give Exec access

- **Auto-approval starts on for workspace conversations.** Use `/auto-approve` to turn it off if you want to review edits and shell commands first. Shell commands run with your user permissions, **not in a sandbox**, and can affect files outside the workspace. Stopping an operation does not undo changes.
- **Only share what you intend to send.** Requested project files, workspace instructions, attached images, and tool results may be sent to the connected provider. Screenshots can include sensitive information and require macOS Screen Recording permission. Web searches send queries to the provider; page fetching contacts the website directly.
- **Credentials stay in Keychain.** Conversations and managed images are saved in `~/Library/Application Support/Harness/` (the app’s former name), without app-level encryption. Unsent drafts and attachments are not saved across restarts.
- **Service support can change.** Exec uses a Codex-compatible backend integration, not the public API. Search, image generation, and other features depend on account and model support. Automated tests do not verify live-service availability; some features still need live validation.

## Building and development

For consistent Keychain access across rebuilds, configure a stable signing certificate before building:

```sh
security find-identity -v -p codesigning
git config --local exec.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```

Without a configured identity, builds use ad-hoc signing and may prompt for Keychain access again after rebuilding. Never commit signing keys or credentials.

To run the checks and build:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Tests use isolated stores and fake transports—not your Keychain or live model calls. You can also open `Package.swift` in Xcode.
