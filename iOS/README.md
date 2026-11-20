# Exec Remote for iOS

A thin SwiftUI client for accessing the Rust backend remotely. It contains no agent runtime, shell tools, provider credentials, or local conversation database.


## Simulator

1. Start the relay as described in [`relay/README.md`](../relay/README.md).
2. Build/open the current Mac app; configure **Settings → Remote Access** with `ws://127.0.0.1:8787` enabled.
3. On the Mac, create a pairing QR code and click **Copy to clipboard** beneath it. In the simulator, tap **Scan Pairing QR Code**, paste the copied text into **Pairing code** on the **Camera Unavailable** screen, and tap **Pair Device**. Manual entry uses the same invitation validation and connection flow as scanning on a physical device.

Launch without `--ui-fixture` to connect to the real backend. Use the isolated UI fixtures below for checks without network or Keychain access.

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

The tests launch with `--ui-fixture`, using only synthetic sessions and delayed fake responses. This launch mode exists only in Debug simulator builds and injects a fake transport and in-memory credential storage, exercising the real foreground/recovery lifecycle without network or Keychain access. Local display preferences use a separate UserDefaults suite, reset on each fixture launch.

`SessionUITests` also uses `--offline-actions-fixture` for offline menu/form access, one fixed top pill across navigation and settings/creation sheets, disabled offline workspace selection, and message cancellation. `--folder-disconnect-fixture` disconnects during an already-open picker read to check its neutral offline message and retained valid choice. Pill checks sample its solid fill and transparent surroundings, count instances, and compare its frame before/after navigation and keyboard presentation. Recovery checks require unchanged controls, composer, and last-row scroll endpoints, not reclaimed bottom space. `--recovering-host-fixture` rejects the initial connection, delays the next automatic observer retry by 30 seconds for offline layout checks, then recovers without a menu action. Adding `--delayed-host-failure-fixture` delays that first failure by ten seconds so the composer can retain keyboard focus through both pill transitions. `--delayed-startup-fixture` starts without cached data and delays the first successful connection by ten seconds, checking pending startup without waiting away a banner flash and comparing root/sheet geometry after success. `--delete-fails` checks action-error dismissal by downward swipe, with taps, horizontal/upward drags and short drags leaving the notice intact. `--session-title-fixture` delays conversation reads by five seconds and returns snapshot titles different from the catalog. It checks titles while reads are pending, switching sessions before a read finishes, and cached reopening. These are pending/settled-state checks, not frame-by-frame measurements of navigation animations.

`SettingsUITests` uses `--settings-fixture` for shell cards with descriptive and blank titles. Additional flags cover an offline host (`--settings-offline`), delayed save acknowledgement (`--slow-settings-save`), a rejected first save followed by a background library edit (`--settings-save-fails`), and accepted saves whose subsequent read fails (`--settings-refresh-fails`). A second save would succeed after the simulated rejection, so an automatic retry would incorrectly dismiss the sheet and fail the draft-preservation check.

`TranscriptUITests` uses `--transcript-fixture --transcript-markdown` with `--ui-fixture` for interleaved paragraphs, a multiline fence, a deliberately wide aligned table, and literal user Markdown. Its block regression checks one selectable multiline code region and drags across the visible table row to fully reveal the last column without changing text geometry or the transcript's vertical position. Queries use the observable text regions because UIKit flattens the non-element block and horizontal scroll wrappers in the accessibility hierarchy; before/after `debugDescription` output records the hierarchy in the test log. Use `build-for-testing` instead of `test` to compile these checks without launching a simulator.

## Screenshot-free native transcript checks

`NativeTranscriptTests` is a hostless simulator unit-test target. It compiles only the native transcript and scroll state with the existing shared packages—not the app, store or credential code. Its synthetic grouped tools exercise disclosure anchoring, streaming, inset changes, collapse and follow-state transitions. Layer assertions verify all 15 accent dots remain exactly `#007AFF` in light/dark appearance even with a red ancestor tint. These tests use no UI automation or screenshot attachments:

```sh
cd iOS
xcodebuild -project ExecRemote.xcodeproj -scheme ExecRemote \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath .build -only-testing:NativeTranscriptTests \
  -parallel-testing-enabled NO test
```

Store tests additionally use a manually released thinking-delay clock and fake change notifications for cancellation, response gaps, operation replacement, session switching, hidden streaming and suspension. Native tests drive the disclosure action and scroll-state input directly; physical touch/momentum, interactive keyboard dismissal and on-device Reduce Motion still need manual validation.

## Settings

**Descriptive shell titles** is local to the iPhone, defaults off, and works offline. It changes shell-card summaries, including cached transcripts; missing or blank descriptions fall back to the command. Expanded commands and output are unchanged. The four settings share the General group; System Prompt stays separate. Shared agent controls still require a connection.

**Apply** appears when the system prompt was edited. It dismisses immediately and sends one store-owned `PATCH /v1/library` in the background; failure reopens the preserved draft without retrying. An unchanged **Done** closes without writing. Background library refreshes do not overwrite a dirty draft. An unchanged sheet can close offline; an unsaved prompt cannot be dismissed by swiping or applied while offline.

## Sessions and transcripts

New Session presents Workspace, Model selection, then Tools. The flat Tools list follows the Mac's visible order without group headings; Wait and Delegate stay enabled and are not listed. Other tool selections start from the host defaults and apply only to the new session. Workspace browsing uses the native disabled state while offline and re-enables after connection recovery. An already-open picker shows a small centered grey **Connect to the host first.** message if disconnected, without an error row; it retains its last valid folder choice and reloads on reconnection. Directory navigation retains the last displayed valid folder while reads finish.

Session cards show a one-line title and grey spinner at the top, then workspace left/time right in the footer. Child sessions are smaller grey buttons inside their parent card, between its title and metadata. They are independently selectable, without their own status or delete action. Parent cards retain native swipe deletion. Adjacent transcript tool cards share one uninterrupted hosting surface/background and identify running tools; a native blue working indicator appears after an uninterrupted 500 ms response gap and fades in over 0.4 seconds. It uses fixed sRGB `#007AFF`, independent of appearance or accent tint, and freezes its pulses under Reduce Motion. Streaming text, running tools, approval, cancellation and terminal operations suppress it; resident hidden sessions track gaps without restarting their delay when reopened. Scene suspension/disconnection clears pending indicator work. iOS user bubbles use a consistent width and fixed iMessage blue.

Assistant Markdown stays inside each virtualized message cell. Ordinary paragraphs share selectable TextKit regions; tables use natural-width columns at the existing Dynamic Type footnote size, with bold headers, Markdown alignment and horizontal scrolling rather than font shrinking. Fenced code uses one continuous rounded surface and one selectable multiline text view, scrolling horizontally for long lines. Native selection works within each text region/cell; its menu adds **Copy Code Block**, **Copy Table** (tab-separated), and **Copy Message** (the original Markdown) to copy across region boundaries. User bubbles remain literal plain text. Block scroll offsets survive updates while their message cell is resident, and reset on cell reuse.

Primary action buttons use blue glass backgrounds with white labels on supported iOS versions. A non-dismissible **Host connection lost** pill appears only after a connection or synchronization failure, never merely during startup, a pending healthy reconnect or intentional scene suspension. Its failure state survives retries and unrelated action errors until authentication succeeds, the host is forgotten or a new host is paired. One transparent, scene-owned, non-key window at normal level + 1 keeps the solid red-tinted capsule above all app pages and sheets, below system status/alert levels. This is app-only, not an overlay over other apps or iOS permission alerts. A native attachment outside the root navigation stack owns its lifetime, with cleanup on root teardown or scene disconnection. All touches pass through, keyboard focus stays in the primary window, and status-bar appearance remains delegated to the primary app hierarchy. The pill sits six points below the scene's safe-area top, beneath the Dynamic Island/status area, regardless of pages, sheets or keyboard; it never changes content/composer geometry or scroll insets. It slides down from the top and fades over 0.2 seconds, without animation under Reduce Motion. Normal reconnect is automatic while active and on return to the foreground; Session Options retains Settings and Forget Host, not a redundant Reconnect action. Forgetting and manual pairing remain available. Action failures remain separate red-tinted notices with selectable text. They have no close button: swipe downward to dismiss, or use the accessibility escape action. Taps and horizontal/upward drags do not dismiss them. Connection-only failures do not create action notices. These are in-app notices, not system completion notifications.

Menus and New Session remain available during reconnects and unrelated commands. Actual writes use separate creation, shared-library and conversation locks; acknowledgements release their locks before readback. Accepted operation IDs make Stop available without waiting for the sent bubble to reconcile. Duplicate/conflicting commands and cancelling operations remain guarded.

Send can retain **one unsent message** while disconnected, loading a session, or waiting for a preceding send acknowledgement. It appears as a normal user bubble at 68% opacity, without changing the composer height; the native text-selection menu and accessibility actions offer **Cancel Queued Message**. It expires silently after 30 seconds; expiry, cancellation, leaving the session, or backgrounding without a send-time grant removes the bubble and returns its text to the composer ahead of anything typed since, without a draft notice or toast. Its actual rendered height directly updates transcript clearance when restored text expands it, keeping the last reply reachable above the composer. Before automatic dispatch, a fresh read validates the original session and operation. Dispatch makes the same row fully opaque, and reconciliation preserves its identity. A changed/finished operation returns the message to the draft rather than converting steering into a new turn. Unknown intent never binds to an unobserved active operation. Once handed to the transport, a command is never automatically replayed, including after a lost acknowledgement; a failed send also returns its dependent unsent message to the draft.

The conversation header and grouped-list swipe actions use native automatic appearances, including the system top scroll-edge blur/fade. No custom swipe backgrounds or navigation-bar color overrides are applied. New sends reserve response space and anchor the visible user bubble eight points below the navigation bar; streaming changes coalesce instead of jumping per layout. Reading history keeps its viewport and only an explicit downward scroll to the bottom resumes following. Expanding or collapsing a tool captures its header before the grouped cell is remeasured and enters reading mode. Streaming, keyboard/composer insets and automatic bottom clamping do not rearm following. On opening, the transcript is positioned without animated scrolling, then fades in over 0.2 seconds. Subsequent streaming, keyboard and disclosure updates do not restart that fade. Reduce Motion reveals content and aligns immediately.

## Foreground synchronization

After its initial read, the store consumes `RelayClient.changes()` rather than polling. The first notice on every subscription and every epoch change trigger a catalog/library and resident-conversation catchup, closing the read/subscribe race. Later notices refresh only changed revisions. Hidden sessions in the three-entry recent cache stay warm; unopened or evicted histories are not fetched. Opening a session still displays cached data immediately and refreshes it on activation. Transcript updates retain pagination, optimistic sends, deletion tombstones, and stale-read guards.

The authenticated tunnel advertises notification support in its `ready` handshake. The client subscribes once over the existing encrypted WebSocket; API replies and coalesced notifications share that connection. Notifications contain revisions, not transcript bodies.

Subscription failures, malformed notices/pages, API rejections, and stream termination use read-only reconnects with bounded backoff (up to 30 seconds), never fallback polling or command replay. Temporary scene inactivity (for example, Control Center) keeps the same connection and observer. Backgrounding stops observation and disconnects promptly when no user send is pending; foreground observation catches up without discarding cached sessions or drafts. Replacement observers await their predecessor and `stopChanges()` ownership release; asynchronous stream termination cannot disconnect a shared mutation. Histories skipped for pending DELETEs remain dirty without spinning, and a failed deletion catches up on the next unchanged heartbeat.

The relay queue remains bounded at 64 waiting requests plus one active request. Synchronous per-request cancellation tokens prevent queued commands from sealing after cancellation; once dispatch is claimed, replies drain without retry, even when the caller cancels. After successful notification opt-in, one generation-scoped timer closes a half-open connection/stream after about 70 seconds without authenticated traffic (host heartbeats are 20 seconds). This is not HTTP polling and creates no task per token. Active requests retain their existing 45-second deadline rather than being cut short by an older idle deadline; legacy/unsubscribed hosts do not promise heartbeats and are not subject to this watchdog.

## Last-send background handoff

The Send button captures its text and requests a short `UIApplication.beginBackgroundTask` assertion **before** scheduling asynchronous work. Locking/backgrounding can then give already-admitted input time to reach the host. One assertion covers the outstanding sends, including a dependent queued followup; it ends on acknowledgement/failure or OS expiration, never on completion of the model answer or a transcript download. Host-accepted operations continue independently; background teardown does not send a host Cancel command.

A queued message may make one initial attempt within its original 30-second deadline, after a fresh read validates its original target. An offline queue gets at most one background connection attempt, not a retry loop. Expiration or denied background time cancels unsent work and restores the draft ahead of newer text. Delivery that cannot be confirmed is marked uncertain and reconciled on foreground return, **never automatically resent**. An expired queue cannot resume hours later.

This is best effort, **not a delivery guarantee**: iOS may deny or expire time, terminate the app, or lose network access; the relay and host must be reachable and the host awake. There is no permanent background socket, background polling, push notification, or new background mode/entitlement. Reconnection uses the already-loaded pairing key in memory; Keychain accessibility remains `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Unsent drafts remain in memory, not a durable outbox surviving process termination.

## Verification

From `iOS/`, run `swift test --scratch-path .build/notification-store-checks` on macOS for isolated store checks (fake transport, manually advanced retry clock, and in-memory credentials; no user Keychain or model calls). Coverage includes idle/duplicate notices, changed-only and hidden-cache refreshes, eviction, initial/reconnect/epoch catchup, coalescing during reads, explicit unsupported fallback, bounded failure backoff, suspension/cancellation, pagination, in-flight sends/deletions, and no mutation replay. Handoff tests inject grants, expiration, held transport replies and clocks for inactive/background ownership, ACK-bound release, denied/expired time, queued validation/deadlines, foreground/stale-callback races, draft ordering and no replay. From `shared/ExecRemote/`, run `swift test` for shared transport/presentation checks. Build the app with the simulator command above.

The shared package also has an opt-in end-to-end test using actual Rust backend and relay processes. Build both binaries, then run from `shared/ExecRemote/`:

```sh
EXEC_TEST_BACKEND=/absolute/path/to/exec-agent \
EXEC_TEST_RELAY=/absolute/path/to/exec-relay swift test
```

The fixture uses temporary profiles, synthetic credentials, loopback sockets, and no provider requests or user Keychain access. It verifies pairing, push notifications interleaved with mutations, shared settings, and device revocation. Without the two binary paths, this integration test is skipped. Store/transport unit tests use fake clocks and transports to exercise cancellation, reconnect, bounded buffering, and missing-heartbeat recovery.

Simulator compilation and these isolated checks do not replace physical-device lifecycle/network testing.

On a paired phone, separately check brief Wi-Fi/cellular interruptions, locking/unlocking, and foreground/background transitions during connection and an active turn. Keep the host awake for these checks; a sleeping or offline host cannot serve requests.