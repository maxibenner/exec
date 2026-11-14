# Exec Remote for iOS

A thin SwiftUI client. It contains no agent runtime, shell tools, provider credentials, or local conversation database. The transcript uses a native **UITableView**, diffable updates, reusable self-sizing cells, and selectable UITextView text—not a SwiftUI scroll/lazy stack. Navigation, forms, pickers, sheets, and camera scanning use system components.

Requires iOS 17+ and Xcode with an iOS SDK. Open `ExecRemote.xcodeproj`; its package dependencies are local: `../shared/ExecRemote` (API/transport) and `../shared/ExecTranscript` (native transcript presentation).

## Simulator

1. Start the relay as described in [`relay/README.md`](../relay/README.md).
2. Build/open the current Mac app; configure **Settings → Remote Access** with `ws://127.0.0.1:8787` and **Local development relay** enabled.
3. Run the `ExecRemote` scheme on an iPhone simulator.
4. On Mac, create a pairing QR code and choose **Copy Pairing Invitation**. Paste into the iOS pairing field and tap **Pair**. The Simulator has no camera.
5. Open an existing conversation, or create one and tap **Choose Folder** to browse directories **on the agent host**. Folder Options also allows entering an absolute path or showing hidden folders.

CLI simulator build:

```sh
cd iOS
xcodebuild -project ExecRemote.xcodeproj -scheme ExecRemote \
  -sdk iphonesimulator -configuration Debug -derivedDataPath .build build
```

Keep Xcode's default **Sign to Run Locally** simulator signing enabled. An unsigned simulator build can launch but cannot use its Keychain. In Xcode 27, the simulator UI is **Device Hub** (`Xcode.app/Contents/Applications/DeviceHub.app`).

## Device / TestFlight

1. Open the project in Xcode; select your Apple Developer team and an available bundle identifier under Signing & Capabilities. The placeholder is `app.exec.remote`; no team/profile is committed.
2. For a physical local test, use the Mac's LAN relay address, not `127.0.0.1`; grant camera/local-network access. For internet testing, deploy the relay behind your TLS reverse proxy and use `wss://`.
3. Create the matching App Store Connect app record. Set the marketing version/build number, select a generic iOS device, and **Product → Archive**.
4. Distribute through Organizer to App Store Connect and add TestFlight testers. You must complete Apple's encryption/export-compliance questions: this app uses authenticated HPKE end-to-end encryption in addition to TLS. No exemption is predeclared in the plist.
5. Provide accurate app privacy information and any required compliance documentation. This repository cannot supply your team credentials, upload authorization, or Apple review approval.

The app icon is an opaque 1024px derivative of the existing Exec artwork. Device signing, camera permission UX, TestFlight upload/review, and a public TLS proxy deployment require separate verification.

## First-version scope

- QR/pasted invitation pairing, one saved host, per-device identity stored in Keychain (`WhenUnlockedThisDeviceOnly`, not synced).
- Conversation list with native expanding red swipe-to-delete (including full-swipe deletion, no confirmation dialog), text transcript/tool summaries, host folder selection, new conversations, send, stop, explicit approval/denial, and shared default settings. Active conversations must be stopped before deletion.
- Native multiline composer with system Liquid Glass on iOS 26+, and system material on older supported iOS versions.
- Foreground snapshot polling every 1.5 seconds; reconnect fetches authoritative state. Sends/approvals/settings changes are never automatically retried. Following an uncertain send, inspect the refreshed conversation before manually sending again.
- Shared settings are agent-owned; selected conversation, scroll position and drafts are local. Drafts are currently in memory, not durable across process termination.
- Native selectable Markdown (headings, emphasis, lists, quotes, fenced code, safe links and text tables), using the same bounded parser as macOS. Tool cards, headers and input/result summaries are shared with the Mac; expansion state survives cell reuse and pending-to-completed tool updates.
- iOS uses UIKit TextKit rather than AppKit text tables. Tool edit diffs are selectable monospace text; desktop diff decorations, image viewing/upload, steering UI, push notifications and background execution are not included.
- Quit/sleep/offline Mac means the hosted agent is unavailable. The Mac app still owns its bundled helper's lifecycle. Standalone installation is not part of this feature.

Revoke on the Mac to remove authorization. **Forget Host** only removes the phone's local credential.
