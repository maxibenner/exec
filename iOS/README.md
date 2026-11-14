# Exec Remote for iOS

A thin SwiftUI client. It contains no agent runtime, shell tools, provider credentials, or local conversation database. The transcript uses a native **UITableView**, diffable updates, reusable self-sizing cells, and selectable UITextView text—not a SwiftUI scroll/lazy stack. Navigation, forms, pickers, sheets, and camera scanning use system components.

Requires iOS 17+ and Xcode with an iOS SDK. Open `ExecRemote.xcodeproj`; its package dependencies are local: `../shared/ExecRemote` (API/transport) and `../shared/ExecTranscript` (native transcript presentation).

## Simulator

1. Start the relay as described in [`relay/README.md`](../relay/README.md).
2. Build/open the current Mac app; configure **Settings → Remote Access** with `ws://127.0.0.1:8787` and **Local development relay** enabled.
3. Run the `ExecRemote` scheme on an iPhone simulator.
4. On Mac, create a pairing QR code and choose **Copy Pairing Invitation**. Paste into the iOS pairing field and tap **Pair**. The Simulator has no camera.
5. Open an existing conversation, or create one and tap **Choose Folder** to browse directories **on the agent host**. The current path appears above the folder list; **back up** navigates to its parent. New Chat groups Model and its supported Reasoning options together; selecting reasoning overrides only that new session's effort.

CLI simulator build:

```sh
cd iOS
xcodebuild -project ExecRemote.xcodeproj -scheme ExecRemote \
  -sdk iphonesimulator -configuration Debug -derivedDataPath .build build
```

Keep Xcode's default **Sign to Run Locally** simulator signing enabled. An unsigned simulator build can launch but cannot use its Keychain. In Xcode 27, the simulator UI is **Device Hub** (`Xcode.app/Contents/Applications/DeviceHub.app`).

## Isolated UI checks

The `ExecRemote` scheme includes three focused UI tests for navigation underlap/keyboard geometry, optimistic deletion failure recovery, and an accepted deletion followed by a failed refresh. Screenshot attachments include the native middle-row swipe state. The app target is named `ExecRemoteMobile` to disambiguate it from the `ExecRemote` Swift package; the scheme, app product and bundle identifier are unchanged.

Run from `iOS/` on an installed simulator (replace the device ID):

```sh
xcodebuild -project ExecRemote.xcodeproj -scheme ExecRemote \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath .build -resultBundlePath .build/ui-checks.xcresult \
  -parallel-testing-enabled NO test
xcrun xcresulttool export attachments --path .build/ui-checks.xcresult \
  --output-path .build/ui-screenshots
```

The tests launch with `--ui-fixture`, using only synthetic sessions and delayed fake responses. This launch mode exists only in Debug simulator builds and injects a fake transport and in-memory credential storage, exercising the real foreground/recovery lifecycle without network or Keychain access. It is not compiled into device/Release builds. Debug builds target only the active simulator architecture so local packages and the app agree. Results do not verify live-relay behavior or physical-device rendering.

## Device / TestFlight

1. Open the project in Xcode. Debug and Release use automatic signing for Numbers Office LLC (team `88P8NTGNTW`), bundle identifier `com.numbersoffice.exec.remote`, and initial version/build `1.0 / 1`. Sign in with an Apple Developer account authorized for that team; provisioning profiles and credentials are not committed. Use your own team and bundle identifier for independent builds.
2. For a physical local test, use the Mac's LAN relay address, not `127.0.0.1`; grant camera/local-network access. For internet testing, deploy the relay behind your TLS reverse proxy and use `wss://`.
3. Create the matching App Store Connect app record. Set the marketing version/build number, select a generic iOS device, and **Product → Archive**.
4. Distribute through Organizer to App Store Connect and add TestFlight testers. You must complete Apple's encryption/export-compliance questions: this app uses authenticated HPKE end-to-end encryption in addition to TLS. No exemption is predeclared in the plist.
5. Provide accurate app privacy information and any required compliance documentation. This repository cannot supply your team credentials, upload authorization, or Apple review approval.

The app icon is an opaque 1024px derivative of the existing Exec artwork. Device signing, camera permission UX, TestFlight upload/review, and a public TLS proxy deployment require separate verification.

## First-version scope

- QR/pasted invitation pairing, one saved host, per-device identity stored in Keychain (`WhenUnlockedThisDeviceOnly`, not synced).
- Native full-width grouped session list on the system grouped background, sorted by last activity with primary-label daily sections (Today, Yesterday, then dates). Neutral rows show a title above a single time/workspace row, without folder icons. The centered All Sessions navigation header and bottom toolbar use system styling; options are bottom-left and new chat bottom-right. Native destructive swipe actions support full-swipe deletion. Rows retain the system background and animated trailing-corner mask instead of overriding it with a flat custom background. Deletions hide the row immediately and suppress stale refreshes; a failed deletion restores it, but a failed refresh after host acceptance does not. Active conversations must be stopped before deletion.
- Native multiline composer with system Liquid Glass on iOS 26+, and system material on older supported iOS versions. The transcript extends underneath the top navigation bar, retaining UIKit's automatic safe-area content inset. Its native table controller registers the scroll view with the SwiftUI navigation owner (not just the embedded child) for system translucency and scroll-edge styling. The transcript scrolls beneath the floating composer with measured bottom padding, following content-height and inset changes while at the bottom without interrupting reading above. Sending keeps keyboard focus; the transcript supports interactive swipe-down keyboard dismissal.
- During an active turn, an empty composer shows Stop; entering text switches to Send and submits to the host's operation-bound steering queue. Sent/queued text and the active indicator appear immediately through a display-only overlay, with stable row identity after reconciliation. Drafts clear immediately and are restored on send failure without discarding newer typing; failures never trigger automatic resubmission. An accepted send whose refresh fails retains its local row, not a restored draft. Execution/cancellation always use authoritative state, never the visual overlay.
- Foreground conversation polling every 1.5 seconds when idle, or every 0.5 seconds for the selected active/pending session (plus request latency). The host returns only the changed suffix (including the latest message for streaming edits) and current operation state. Opening a session fetches the newest 64 messages; scrolling upward fetches older pages. A host-issued prefix proof detects edits to earlier messages and resets to a fresh page rather than silently skipping history. Visible-session reads take priority over list/settings reads. Interrupted connections automatically reconnect while foregrounded and fetch authoritative state; failed connection attempts back off to at most one attempt every 30 seconds (plus request latency). Backgrounding disconnects, and returning to the foreground resumes recovery. API rejections do not discard a healthy connection. Sends/approvals/settings changes are never automatically retried. Following an uncertain send, inspect the refreshed conversation before manually sending again. The iOS app and Mac helper must both be updated for the sync endpoint.
- The last three viewed conversations are cached in memory. Reopening displays the last snapshot immediately and refreshes without first clearing the transcript. Session-opening reads belong to the store: returning to All Sessions lets an in-flight read finish into the cache without cancelling the shared connection or redisplaying the previous session. Refresh failures retain cached contents; deletion and host changes invalidate them. This is not an offline conversation database and does not survive process termination.
- Shared settings are agent-owned; selected conversation, scroll position and drafts are local. Drafts are currently in memory, not durable across process termination.
- Native selectable Markdown (headings, emphasis, lists, quotes, fenced code, safe links and text tables), using the same bounded parser as macOS. User messages are right-aligned blue bubbles without speaker labels. Tool cards start collapsed, including edit calls; explicit expansion survives cell reuse and pending-to-completed tool updates.
- The transcript's active indicator shares the Mac's neuron pulse curves and uses Core Animation, not a per-frame application timer. Animation stops offscreen/in the background and respects Reduce Motion.
- iOS uses UIKit TextKit rather than AppKit text tables. Tool edit diffs are selectable monospace text; desktop diff decorations, image viewing/upload, push notifications and background execution are not included.
- Quit/sleep/offline Mac means the hosted agent is unavailable. The Mac app still owns its bundled helper's lifecycle. Standalone installation is not part of this feature.

## Verification

From `iOS/`, run `swift test` on macOS for the store's isolated connection/recovery checks (fake transport and in-memory credentials; no user Keychain or model calls). From `shared/ExecRemote/`, run `swift test` for shared transport/presentation checks. Build the app with the simulator command above.

On a paired phone, separately check brief Wi-Fi/cellular interruptions, locking/unlocking, and foreground/background transitions during connection and an active turn. Recovery must refresh the conversation without tapping Reconnect or resending a command. Keep the host awake for these checks; a sleeping or offline host cannot serve requests.

## Completion semantics

The indicator follows the host's operation state, not the last assistant message's status. A completed message can still be followed by tool execution, queued input, or a failed persistence checkpoint. Terminal snapshots remove the indicator in the same UI update as their final transcript. Polling still introduces latency if the final text arrives in an earlier, active snapshot.

To eliminate polling latency later, forward the host's ordered operation-state events over the relay, keyed by conversation and operation ID, alongside transcript updates. Keep paged snapshots for initial load and reconnect recovery; discard stale-operation events and never retry sends to recover a stream. A separate terminal operation event is safer than a speculative `lastMessage` flag and preserves cancellation/failure semantics.

Revoke on the Mac to remove authorization. **Forget Host** only removes the phone's local credential.
