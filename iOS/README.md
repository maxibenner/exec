# Exec Remote for iOS

A thin SwiftUI client for accessing the Rust backend remotely. It contains no agent runtime, shell tools, provider credentials, or local conversation database.


## Simulator

1. Start the relay as described in [`relay/README.md`](../relay/README.md).
2. Build/open the current Mac app; configure **Settings → Remote Access** with `ws://127.0.0.1:8787` enabled.
3. Pairing requires scanning a Mac pairing QR code on a physical device. Use the isolated UI fixtures below for simulator checks.

CLI simulator build:

```sh
cd iOS
xcodebuild -project ExecRemote.xcodeproj -scheme ExecRemote \
  -sdk iphonesimulator -configuration Debug -derivedDataPath .build build
```

Keep Xcode's default **Sign to Run Locally** simulator signing enabled. An unsigned simulator build can launch but cannot use its Keychain.

## Isolated UI checks

The `ExecRemote` scheme includes focused UI tests. Screenshot attachments include the native middle-row swipe state. Session controls are standalone SwiftUI buttons in a transparent bottom safe-area inset, with no toolbar or full-width bar background. 

Run from `iOS/` on an installed simulator (replace the device ID):

```sh
xcodebuild -project ExecRemote.xcodeproj -scheme ExecRemote \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath .build -resultBundlePath .build/ui-checks.xcresult \
  -parallel-testing-enabled NO test
xcrun xcresulttool export attachments --path .build/ui-checks.xcresult \
  --output-path .build/ui-screenshots
```

The tests launch with `--ui-fixture`, using only synthetic sessions and delayed fake responses. This launch mode exists only in Debug simulator builds and injects a fake transport and in-memory credential storage, exercising the real foreground/recovery lifecycle without network or Keychain access.

## Foreground synchronization

After its initial read, the store consumes `RelayClient.changes()` rather than polling. The first notice on every subscription and every epoch change trigger a catalog/library and resident-conversation catchup, closing the read/subscribe race. Later notices refresh only changed revisions. Hidden sessions in the three-entry recent cache stay warm; unopened or evicted histories are not fetched. Opening a session still displays cached data immediately and refreshes it on activation. Transcript updates retain pagination, optimistic sends, deletion tombstones, and stale-read guards.

The authenticated tunnel advertises notification support in its `ready` handshake. The client subscribes once over the existing encrypted WebSocket; API replies and coalesced notifications share that connection. Notifications contain revisions, not transcript bodies.

Subscription failures, malformed notices/pages, API rejections, and stream termination use read-only reconnects with bounded backoff (up to 30 seconds), never fallback polling or command replay. Scene suspension cancels observation and disconnects; foreground observation reconnects and catches up without discarding cached sessions or drafts. Replacement observers await their predecessor and `stopChanges()` ownership release; asynchronous stream termination cannot disconnect a shared mutation. Histories skipped for pending DELETEs remain dirty without spinning, and a failed deletion catches up on the next unchanged heartbeat.

The relay queue remains bounded at 64 waiting requests plus one active request. Synchronous per-request cancellation tokens prevent queued commands from sealing after cancellation; once dispatch is claimed, replies drain without retry, even when the caller cancels. After successful notification opt-in, one generation-scoped timer closes a half-open connection/stream after about 70 seconds without authenticated traffic (host heartbeats are 20 seconds). This is not HTTP polling and creates no task per token. Active requests retain their existing 45-second deadline rather than being cut short by an older idle deadline; legacy/unsubscribed hosts do not promise heartbeats and are not subject to this watchdog.

## Verification

From `iOS/`, run `swift test --scratch-path .build/notification-store-checks` on macOS for isolated store checks (fake transport, manually advanced retry clock, and in-memory credentials; no user Keychain or model calls). Coverage includes idle/duplicate notices, changed-only and hidden-cache refreshes, eviction, initial/reconnect/epoch catchup, coalescing during reads, explicit unsupported fallback, bounded failure backoff, suspension/cancellation, pagination, in-flight sends/deletions, and no mutation replay. From `shared/ExecRemote/`, run `swift test` for shared transport/presentation checks. Build the app with the simulator command above.

The shared package also has an opt-in end-to-end test using actual Rust backend and relay processes. Build both binaries, then run from `shared/ExecRemote/`:

```sh
EXEC_TEST_BACKEND=/absolute/path/to/exec-agent \
EXEC_TEST_RELAY=/absolute/path/to/exec-relay swift test
```

The fixture uses temporary profiles, synthetic credentials, loopback sockets, and no provider requests or user Keychain access. It verifies pairing, push notifications interleaved with mutations, shared settings, and device revocation. Without the two binary paths, this integration test is skipped. Store/transport unit tests use fake clocks and transports to exercise cancellation, reconnect, bounded buffering, and missing-heartbeat recovery.

Simulator compilation and these isolated checks do not replace physical-device lifecycle/network testing.

On a paired phone, separately check brief Wi-Fi/cellular interruptions, locking/unlocking, and foreground/background transitions during connection and an active turn. Keep the host awake for these checks; a sleeping or offline host cannot serve requests.