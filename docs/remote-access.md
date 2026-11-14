# Remote access v1

## Ownership

`backend/` remains the single headless agent/API. The bundled Mac app launches it and gracefully closes it on quit. Remote access is entirely backend-owned: a future standalone process can use the same pairing endpoints and relay connector without any SwiftUI process. `relay/` is an opaque WebSocket switch. `shared/ExecRemote/` contains provider-neutral JSON, invitation validation, and the encrypted Swift client; `iOS/` contains only presentation and device credential storage. `shared/ExecTranscript/` supplies the Markdown parser, tool presentation, and SwiftUI tool cards used by both apps; iOS keeps UIKit list virtualization and selectable native TextKit rendering.

The local HTTP listener and its ephemeral administrator/native credentials are unchanged. The relay adapter calls the existing handler with a distinct, fixed remote authorization policy; it never fabricates or exports an administrator credential. Accepted mutations are tracked by the existing service task tracker and settle despite observer loss. Shutdown stops the connector and awaits those handlers before closing the manager.

## Pairing and encryption

- Local-administrator-only API: `GET/PUT /v1/remote`, `POST /v1/remote/invitations` with `{}`, `DELETE /v1/remote/devices/:id`.
- Configuration is `{relay, enabled, localDevelopment}`. Production requires a root `wss://host[:port]` URL; no credentials, query, fragment, or custom path. Local `ws://` requires explicit opt-in and a private/loopback address.
- Each invitation pins the host's X25519 public key, route, relay URL and protocol version, plus a 256-bit single-use secret expiring in five minutes. Generating a replacement invalidates the old invitation. The act of generating/sharing/scanning that secret authorizes pairing; there is no separate Mac confirmation prompt.
- The host stores its private identity, relay credential and paired public keys in `PROFILE/remote.json`, owned/private `0600`, using atomic replacement and sync. It is **plaintext private credential storage**, like the existing backend provider store, not Keychain encryption. The phone stores its private identity in its own Keychain. Invitations are in-memory only on the host and never logged.
- The host sends a new 256-bit challenge per client connection. Each side establishes an independent **RFC 9180 Auth-mode HPKE** context (X25519 / HKDF-SHA256 / ChaCha20Poly1305), with `exec-remote-v1:client:<challenge>` or `exec-remote-v1:host:<challenge>` as `info`. CryptoKit and Rust `hpke` implement the cryptography and ordered sequence counters. The initial client packet proves possession of its device key and carries the invitation, if pairing. The authenticated host response confirms acceptance.
- Captured frames cannot be replayed into another challenge or out of sequence. Never reuse contexts after disconnection. This is application framing around standardized HPKE, **not an independently audited secure-messaging protocol**. HPKE Auth mode does not provide forward secrecy against later compromise of the recipient's static private key; protect host profiles/device credentials accordingly.
- TLS still matters: the host's relay-registration credential and metadata must be protected between endpoints and relay. Local development weakens that outer transport only. The relay sees routing, timing, sizes and connection metadata, not API payloads.
- Revocation/disable closes established sessions. A command already accepted before revocation can still complete; revocation is not cancellation or rollback. At most eight devices may be paired.

Remote routes are deny-by-default: health, models, library reads/targeted patches, conversation list/create/read/delete, directory-only workspace browsing, text turns/steering/cancel/approvals and selected per-conversation metadata/settings writes. No remote provider management, native registration/desktop grants, pairing administration, file-content browsing or arbitrary HTTP proxying. Tools still execute with the backend user's privileges; pairing grants significant control of that host, not a sandbox.

### Host folder selection and deletion

`POST /v1/workspaces/browse` accepts `{path?: absolute host path, showHidden?: false}` and returns `{path, parent, directories: [{name, path}], truncated}`. Omitted/null path starts in the host home folder. It lists directories only, skips symlink entries, validates UTF-8/absolute paths, and bounds scanning/results. This is available to authenticated local and paired clients, never the public relay. The iOS sheet uses native navigation and list controls rather than the device-local Files picker.

Remote `DELETE /v1/conversations/:id` uses the existing durable deletion handler; active work still rejects with 409. The iOS list uses standard full-swipe destructive actions without an extra confirmation dialog. Mac catalog refresh removes deleted conversations. An unsent Mac-local draft is retained as an explicitly read-only **Unsent draft** entry for copying, never resubmitted or silently discarded by another device's deletion.

## Synchronization and load

The Mac keeps its existing per-conversation NDJSON subscriptions and refreshes the shared catalog/defaults every two seconds. The iOS client polls the catalog, defaults and selected snapshot every 1.5 seconds while foregrounded. Both fetch authoritative state after reconnection. `PATCH /v1/library` validates only explicitly supplied fields and merges against the latest configuration under the manager's catalog lock; conflicting busy writes are rejected, not retried. `PUT` remains supported for existing trusted clients.

Polling is deliberately the first-version approach, not a second state replication/event log. Long transcripts cost more bandwidth while observed; incremental remote event subscriptions/conditional reads can be added later. With no phone connected there are **no API updates over the relay**, only keepalives. Backgrounding iOS stops its polling/socket. No durable queue, offline commands, inference retries, or resend-on-reconnect exists.

## Verification

Run from repo root (macOS commands explicitly enter `macOS/`):

```sh
cargo test --manifest-path backend/Cargo.toml --locked
cargo test --manifest-path relay/Cargo.toml --locked
cargo build --manifest-path backend/Cargo.toml --locked --bin exec-agent
cargo build --manifest-path relay/Cargo.toml --locked
EXEC_TEST_BACKEND="$PWD/backend/target/debug/exec-agent" \
EXEC_TEST_RELAY="$PWD/relay/target/debug/exec-relay" \
swift test --package-path shared/ExecRemote
(cd macOS && ./scripts/test.sh && ./scripts/build-app.sh)
```

The Swift integration test starts real local Rust/relay subprocesses with an isolated temporary profile and synthetic transport keys. It verifies cross-language encrypted pairing, two-way settings visibility, administrative-route denial, reconnect without invitation reuse and active-session revocation. No Keychain, user profile, live credentials or inference is used. Rust crypto tests cover wrong identity, challenge replay and duplicate frames; pairing tests cover consumption, persistence and revocation. Relay tests exercise opaque forwarding and idle behavior.

Successful local checks do not verify TestFlight signing/upload, camera hardware/OS permissions, internet deployment, Linux container operation or an independent security audit.

Protocol reference: [RFC 9180](https://www.rfc-editor.org/rfc/rfc9180.html). CryptoKit API: [authenticated HPKE sender](https://developer.apple.com/documentation/cryptokit/hpke/sender/init(recipientkey:ciphersuite:info:authenticatedby:)).
