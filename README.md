# Harness

A small native macOS chat harness. SwiftUI, Foundation, Security, Network and CryptoKit only. No Codex executable, Node runtime, agent framework or third-party dependencies.

## Run

Requires macOS 14+ and a Swift 6 toolchain (Xcode or Apple Command Line Tools).

```sh
./scripts/build-app.sh
open dist/Harness.app
```

Quit an already-running copy before reopening the rebuilt app. Choose **Connect to Codex**, sign in in your default browser, select your authorized ChatGPT workspace, select an available model, and send a message. OpenAI still enforces your account's Codex access and usage limits. This app does not fall back to API-key billing or another authentication flow.

- **⌘Return:** send.
- **Stop:** cancel sign-in or the current request.
- **New:** clear the conversation once the current operation ends.
- **Account menu:** reconnect or sign out. Sign out before changing accounts/workspaces.

The callback requires local port **1455**. If another app is signing in on that port, finish or close that sign-in and retry. The app never terminates another listener or forwards callbacks to it.

The build script creates an ad-hoc signed local app, not a notarized distribution. Keychain may ask for permission again after rebuilding it. Open `Package.swift` in Xcode if you prefer IDE development; the script is sufficient without Xcode.

## Structure

```text
Sources/Harness/
  App/                SwiftUI and observable conversation state
  Core/               ChatProvider, messages, models and stream events
  Providers/OpenAI/   Codex OAuth, identity verification and Responses transport
  Storage/            Small Keychain utility
```

`ChatStore` depends only on `ChatProvider`. To add a provider, implement that protocol and inject it in `HarnessApp`. Authentication, model discovery, connection-button text, wire formats, and opaque conversation data belong to the provider. There is no provider registry, plugin system, or generic OAuth layer.

## Connection

Uses the direct Codex protocol used by Pi's `openai-codex` provider:

1. Start a loopback-only listener and open OpenAI's `/oauth/authorize` browser flow with PKCE, state and nonce.
2. Exchange the authorization code at `/oauth/token` with the same `http://localhost:1455/auth/callback` URI.
3. Verify the ID token's signature and identity claims. Read the account ID used for Codex request routing.
4. Store this app's session in Keychain and serialize rotating refreshes.
5. Fetch the Codex model catalog using the separately pinned Codex compatibility version (`0.162.1`), not Harness's app version. Stream requests to `https://chatgpt.com/backend-api/codex/responses` with the account header, `store: false` and `stream: true`.

The app identifies itself as `swift_harness` in the originator header. It doesn't run Pi or Codex, read their credential files, or reuse the previous dynamic-registration connection's credentials. Its Keychain account is `openai.codex.session`; any old `openai.registration` record remains untouched and unused.

Sign-out attempts remote revocation before deleting local credentials. If revocation cannot be confirmed, the app reports that explicitly. Credentials and authorization URLs are not logged.

This is a Codex-compatible backend integration, not the public API-key Responses API contract. Provider changes may require updates. Successful local builds/tests do not establish subscription eligibility or successful sign-in.

Network/SSE processing runs off the main actor. UI text updates are batched. Only completed turns enter follow-up context; partial/failed replies stay visible but are not sent back. Opaque Responses output, including encrypted reasoning, is preserved for follow-up turns.

## Tests

```sh
./scripts/test.sh
```

The dependency-free runner works with Command Line Tools alone. Checks cover Codex OAuth/request fields, callback validation, account routing metadata, SSE framing/Unicode/size limits, terminal events, RSA signature/claim validation, conversation history, failed turns and cancellation. Tests do not contact OpenAI or access Keychain.

Browser sign-in has been exercised by the user; a read-only live check confirmed model discovery with the saved session. **Manual validation still required:** first response and follow-up, Stop, restart/session restoration, refresh and sign-out. No live sign-in or inference is performed by the build or test scripts.

## Deliberate v1 limits

- One connected account and one in-memory conversation.
- No tools, workspace file operations, shell commands, Markdown renderer or history database.
- No automatic request retries or context compaction; start a new conversation if context grows too large.
- No distribution signing or usage dashboard.

## Protocol references

- Pi 1.4.0's `@earendil-works/pi-ai`: `auth/oauth/openai-codex.js` and `api/openai-codex-responses.js`.
- [Codex browser authentication implementation](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs)
- [Codex model catalog implementation](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/models.rs)
