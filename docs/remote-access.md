# Remote access (handshake v2)

## Ownership

`backend/` remains the single headless agent/API. The bundled Mac app launches it and gracefully closes it on quit. Remote access is entirely backend-owned: a future standalone process can use the same pairing endpoints and relay connector without any SwiftUI process. `relay/` is an opaque WebSocket switch. `shared/ExecRemote/` contains provider-neutral JSON, invitation validation, and the encrypted Swift client; `iOS/` contains only presentation and device credential storage. `shared/ExecTranscript/` supplies the Markdown parser, tool presentation, and SwiftUI tool cards used by both apps; iOS keeps UIKit list virtualization and selectable native TextKit rendering.

The local HTTP listener and its ephemeral administrator/native credentials are unchanged. The relay adapter calls the existing handler with a distinct, fixed remote authorization policy; it never fabricates or exports an administrator credential. Accepted API mutations are tracked by the existing service task tracker and settle despite observer loss. Accepted pairing/configuration/revocation transactions are separately tracked by remote access: one task retains the state mutex across invitation consumption, atomic persistence and memory settlement, even if its socket/HTTP waiter is cancelled. At most four hello authorizations may be outstanding, including disconnected waiters; excess hellos are rejected before spawning a transaction or queueing on the state mutex. Accepted transactions retain their admission slot through settlement. Administrator configuration/revocation uses the service's separate bounded mutation budget, so a hello flood cannot exclude it. Shutdown stops the connector, waits for its accepted transactions and API handlers, then closes the manager.

## Pairing and encryption

- Local-administrator-only API: `GET/PUT /v1/remote`, `POST /v1/remote/invitations` with `{}`, `DELETE /v1/remote/devices/:id`.
- Configuration is `{relay, enabled, localDevelopment}`. Production requires a root `wss://host[:port]` URL; no credentials, query, fragment, or custom path. Local `ws://` requires explicit opt-in and a private/loopback address.
- Each invitation pins the host's X25519 public key, route and relay URL, identifies invitation format version 1, and includes a 256-bit single-use secret expiring in five minutes. Generating a replacement invalidates the old invitation. The act of generating/sharing/scanning that secret authorizes pairing; there is no separate Mac confirmation prompt.
- The host stores its private identity, relay credential and paired public keys in `PROFILE/remote.json`, owned/private `0600`, using atomic replacement and sync. It is **plaintext private credential storage**, like the existing backend provider store, not Keychain encryption. The phone stores its private identity in its own Keychain. Invitations are in-memory only on the host and never logged.
- The host sends a new 256-bit challenge per client connection, advertising wire handshake `version: 2`. Each side establishes an independent **RFC 9180 Auth-mode HPKE** context (X25519 / HKDF-SHA256 / ChaCha20Poly1305). Client-to-host `info` is `exec-remote-v2:client:<challenge>`. Host-to-client `info` is `exec-remote-v2:host:<challenge>:<clientEncapsulatedKey>`, where the final component is the standard padded base64 of the fresh 32-byte KEM output in the initial client packet. The host authenticates/decrypts that packet before using its context. CryptoKit and Rust `hpke` implement cryptography and ordered sequence counters. The encrypted hello proves possession of the device key and carries the invitation, if pairing. Encrypted ready contains `ready: true` and `version: 2`.
- Captured frames cannot be replayed into another challenge or out of sequence. Even if a malicious relay replays an old challenge and encrypted ready, the new client's independently generated KEM output changes the response context and ready fails authentication. Never reuse contexts after disconnection. This is application framing around standardized HPKE, **not an independently audited secure-messaging protocol**. HPKE Auth mode does not provide forward secrecy against later compromise of the recipient's static private key; protect host profiles/device credentials accordingly.
- TLS still matters: the host's relay-registration credential and metadata must be protected between endpoints and relay. Local development weakens that outer transport only. The relay sees routing, timing, sizes and connection metadata, not API payloads.
- Revocation/disable closes established sessions. A command already accepted before revocation can still complete; revocation is not cancellation or rollback. At most eight devices may be paired.

Remote routes are deny-by-default: health, models, library reads/targeted patches, conversation list/create/read/delete, directory-only workspace browsing, text turns/steering/cancel/approvals and selected per-conversation metadata/settings writes. No remote provider management, native registration/desktop grants, pairing administration, file-content browsing or arbitrary HTTP proxying. Tools still execute with the backend user's privileges; pairing grants significant control of that host, not a sandbox.

### Protocol and deployment compatibility

- **Upgrade both agent and Swift client together.** Wire v1 is rejected; there is no downgrade or legacy fallback. A v2 client rejects v1/unknown challenges before sending its hello; a v2 host cannot authenticate a v1 hello. Authenticated ready must also declare v2.
- Invitation **format** remains version 1. Existing invitations (if still active) and saved paired-host/device identities remain valid with updated software; changing the handshake does not require clearing pairing stores. Backend `remote.json`, relay `/v1/*` endpoint paths and opaque envelope format are unchanged.
- Production relays now require `EXEC_RELAY_ALLOWED_ROUTES` (comma-separated admitted route hashes, at most 64). Enable/configure remote access before generating an invitation to obtain the host's non-secret `route` without disclosing its private token or invitation secret. Restart the relay process when changing admission; Compose environment changes require container recreation, not a plain restart. Without configuration startup fails closed. For Compose, [bootstrap only the private agent with `--no-deps`](api.md#token-files-containers-and-local-administration), obtain the route via the interactive admin CLI, then configure the allowlist and start relay/proxy. Only `EXEC_RELAY_LOCAL_DEVELOPMENT=1` on an actual loopback bind permits arbitrary registrations; never publicly proxy that development listener. See [relay deployment](../relay/README.md).
- The 1 MiB wire-message limit includes the serialized envelope and JSON escaping, not just opaque data. Oversize/queue-overflow offenders are closed individually; other clients and the host connection remain usable. Queues remain bounded and ephemeral. A route-knowing peer can still consume client slots or traffic/CPU; admission is not a promise of DoS resistance, and deployment connection limits remain useful defense in depth.

### Host folder selection and deletion

`POST /v1/workspaces/browse` accepts `{path?: absolute host path, showHidden?: false}` and returns `{path, parent, directories: [{name, path}], truncated}`. Omitted/null path starts in the host home folder. It lists directories only, skips symlink entries, validates UTF-8/absolute paths, and bounds scanning/results. This is available to authenticated local and paired clients, never the public relay. The iOS sheet uses native navigation and list controls rather than the device-local Files picker.

Remote `DELETE /v1/conversations/:id` uses the existing durable deletion handler; active work still rejects with 409. The iOS list uses standard full-swipe destructive actions without an extra confirmation dialog. Mac catalog refresh removes deleted conversations. An unsent Mac-local draft is retained as an explicitly read-only **Unsent draft** entry for copying, never resubmitted or silently discarded by another device's deletion.

## Request delivery outcomes

`RelayClient` supplies `RemoteFailure.kind` from delivery evidence, not error text or connection status:

- `.notDispatched`: disconnected preflight, full queue, oversized/unencodable request, pre-handoff sealing/encoding failure, or a queued request discarded when the connection ends. No command reached the socket handoff.
- `.rejected`: a complete authenticated API error explicitly contains `"delivery":"rejected"`. The backend adds this optional, backward-compatible metadata only at proven pre-effect service gates; it is not inferred from status codes.
- `.uncertain`: any failure after handing the active request to the socket, including send failure, lost/malformed reply or request timeout. API errors without recognized metadata also remain uncertain, including legacy errors, 500s and storage-recovery 409s. The safe API diagnostic is preserved.

Active and queued requests on the same lost connection can therefore have different kinds. No outcome authorizes automatic command replay. Queued cancellation still prevents sealing; cancellation after dispatch detaches the caller while the ordered pump drains the accepted response and advances HPKE. Reconnection never carries old commands forward.

`GET /v1/library` returns 409 during a pending write rather than an old value. Only a fresh settled successful read may recover a lost client-write acknowledgement; a failed storage acknowledgement requires profile reload before authoritative reads succeed. See [API settlement and error metadata](api.md).

## Synchronization and load

The Mac keeps its existing per-conversation NDJSON subscriptions and refreshes the shared catalog/defaults every two seconds. The iOS client polls the catalog, defaults and selected snapshot every 1.5 seconds while foregrounded. Both fetch authoritative state after reconnection. `PATCH /v1/library` validates only explicitly supplied fields and merges against the latest configuration under the manager's catalog lock; conflicting busy writes are rejected, not retried. `PUT` remains supported for existing trusted clients.

Polling is deliberately the first-version approach, not a second state replication/event log. Long transcripts cost more bandwidth while observed; incremental remote event subscriptions/conditional reads can be added later. With no phone connected there are **no API updates over the relay**, only keepalives. Backgrounding iOS stops its polling/socket. No durable queue, offline commands, inference retries, or resend-on-reconnect exists.

## Verification

Run from repo root (macOS commands explicitly enter `macOS/`):

```sh
(cd backend && cargo test --locked --lib remote:: && cargo build --locked --bin exec-agent)
(cd relay && cargo test --locked && cargo build --locked && cargo clippy --locked --all-targets -- -D warnings && cargo fmt --check)
EXEC_TEST_BACKEND="$PWD/backend/target/debug/exec-agent" \
EXEC_TEST_RELAY="$PWD/relay/target/debug/exec-relay" \
swift test --package-path shared/ExecRemote
(cd macOS && ./scripts/test.sh && ./scripts/build-app.sh)
```

The Swift integration test starts real local Rust/relay subprocesses with an isolated temporary profile, loopback development admission and synthetic transport keys. It verifies cross-language v2 encrypted pairing, two healthy clients surviving a route-knowing oversize sender, two-way settings visibility, administrative-route denial, reconnect without invitation reuse and active-session revocation. No Keychain, user profile, live credentials or inference is used. Rust tests cover wrong identity, challenge/sequence replay, recorded ready against a fresh client context, delayed pairing writes across repeated hello/disconnect cycles beyond the four-transaction bound, settlement/revocation/restart and shutdown, and per-client queue overflow. Swift synthetic sockets replay a recorded challenge/ready and verify failure before API dispatch. Relay tests cover allowlisted admission (including self-issued-token slot exhaustion attempts), serialized size boundaries/escaping, two-client isolation and idle behavior. Relay Compose tests check the static bootstrap contract and optionally render configuration with the installed Docker CLI/Compose plugin, without contacting a daemon or registry; unset/empty allowlists must fail the actual startup validator and synthetic configured routes must pass.

Successful local checks do not verify TestFlight signing/upload, camera hardware/OS permissions, internet deployment, Linux container operation or an independent security audit.

Protocol reference: [RFC 9180](https://www.rfc-editor.org/rfc/rfc9180.html). CryptoKit API: [authenticated HPKE sender](https://developer.apple.com/documentation/cryptokit/hpke/sender/init(recipientkey:ciphersuite:info:authenticatedby:)).
