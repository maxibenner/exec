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
- **Account menu:** refresh the model list, reconnect or sign out. Sign out before changing accounts/workspaces.
- Failed/stopped replies remain visible and are labeled as excluded from follow-up context.

The callback requires local port **1455**. If another app is signing in on that port, finish or close that sign-in and retry. The app never terminates another listener or forwards callbacks to it.

Open `Package.swift` in Xcode if you prefer IDE development; the script is sufficient without Xcode. The app is not notarized for distribution.

### Stable signing and Keychain prompts

By default, local builds use ad-hoc signing and print a warning: a rebuild can change the identity Keychain recognizes. To use a stable certificate:

1. Create an **Apple Development** signing certificate in Xcode → Settings → Accounts → Manage Certificates, or import an existing code-signing certificate and its private key into your login keychain.
2. List available identities: `security find-identity -v -p codesigning`.
3. Pin the chosen certificate locally (this configuration is not committed):

```sh
git config --local harness.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```

For a one-off override, set `SIGNING_IDENTITY` to the certificate name or SHA-1. The build keeps the same bundle identifier and enables hardened runtime for certificate-signed builds. It verifies the signature and never falls back to ad-hoc signing after a configured certificate fails. `REQUIRE_STABLE_SIGNING=1` rejects an unconfigured/ad-hoc build before compilation.

The switch from ad-hoc signing may require one more Keychain approval. Locked keychains or changed permissions can still prompt. This Mac had no valid signing identity at implementation time, so certificate-signed rebuilds still need to be verified after installing a certificate.

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

Sign-out attempts remote revocation before deleting local credentials, including when offline. If revocation cannot be confirmed, the app reports that explicitly. A failed Keychain deletion is reported rather than claiming successful local sign-out. Credentials and authorization URLs are not logged.

Refreshes are shared and not automatically retried. Before a rotating-token exchange, a marker is saved so a crash or lost response cannot replay the old refresh token on restart. An uncertain exchange requires **Reconnect**. If newly rotated tokens cannot be saved, they remain in memory and only the Keychain write is retried; unlock Keychain and retry before quitting.

API requests use an ephemeral URLSession with no shared cookies or disk cache, a 60-second inactivity timeout and a 10-minute resource timeout. Stop cancels the active stream/request. Authentication, permission, rate-limit and network errors have actionable messages; failed model discovery can be retried with **Refresh models** without browser sign-in.

This is a Codex-compatible backend integration, not the public API-key Responses API contract. Provider changes may require updates. Successful local builds/tests do not establish subscription eligibility or successful sign-in.

Network/SSE processing runs off the main actor. UI text updates are batched. Only completed turns enter follow-up context; partial/failed replies stay visible but are not sent back. Opaque Responses output, including encrypted reasoning, is preserved for follow-up turns.

## Tests

```sh
./scripts/test.sh
```

The dependency-free runner works with Command Line Tools alone. The focused checks cover authentication/identity validation, refresh and restart, token-rotation failures, offline sign-out, opaque follow-up context, SSE errors and cancellation. The added lifecycle checks use an in-memory credential store and an intercepted URLSession—not the user's Keychain or live model calls.

The user has verified live sign-in and messaging. Automated lifecycle checks are not a substitute for these final manual checks:

- Relaunch: account restores; conversation intentionally starts empty.
- Send a contextual follow-up, stop a reply, then send again: only completed turns should be remembered.
- Disconnect the network during a reply: an error appears without committing a partial turn; reconnect and retry manually.
- Let the session expire and send again: refresh succeeds, or the app clearly asks to reconnect.
- Sign out: local credentials are removed; offline sign-out warns if revocation is unconfirmed.
- Rebuild with the same certificate and reopen: verify Keychain access remains stable.

No live sign-in, token rotation, revocation or inference is performed by the build or test scripts.

## Deliberate v1 limits

- One connected account and one in-memory conversation.
- No tools, workspace file operations, shell commands, Markdown renderer or history database.
- No automatic request retries or context compaction; start a new conversation if context grows too large.
- No distribution signing or usage dashboard.

## Protocol references

- Pi 1.4.0's `@earendil-works/pi-ai`: `auth/oauth/openai-codex.js` and `api/openai-codex-responses.js`.
- [Codex browser authentication implementation](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs)
- [Codex model catalog implementation](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/models.rs)
