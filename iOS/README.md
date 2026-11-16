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

## Verification

From `iOS/`, run `swift test` on macOS for the store's isolated connection/recovery checks (fake transport and in-memory credentials; no user Keychain or model calls). From `shared/ExecRemote/`, run `swift test` for shared transport/presentation checks. Build the app with the simulator command above.

On a paired phone, separately check brief Wi-Fi/cellular interruptions, locking/unlocking, and foreground/background transitions during connection and an active turn. Keep the host awake for these checks; a sleeping or offline host cannot serve requests.