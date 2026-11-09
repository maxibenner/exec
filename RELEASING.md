# Releasing Exec

## Update hosting

Sparkle is embedded in the macOS app. It reads the HTTPS feed at:

https://maxibenner.github.io/exec/appcast.xml

GitHub Pages serves `docs/` from `main`; release archives live in GitHub Releases, not in Git. In repository **Settings → Pages**, select **Deploy from a branch → main → /docs**. `docs/.nojekyll` disables Jekyll processing. No separate update service or CI secrets are needed. Do not change the Pages domain/path without preserving the URL used by already-installed apps.

The first updater-enabled release is `0.1.0 (3)`. Do not publish the older, pre-Sparkle build: it cannot update itself. People running an older build must install it manually once. Subsequent updates can be installed from Settings → Updates or the sidebar badge. Exec probes the feed silently on launch and later activations (at most once per six hours during a run); only an explicit user action opens the update flow. Badge dismissal is remembered per build. Sparkle's automatic prompting, downloading, and unattended installation remain disabled by default.

## Signing keys

There are two separate identities:

- **Apple Developer ID Application** signs Exec and all embedded Sparkle helpers. Explicitly set `SIGNING_IDENTITY` to the release certificate's SHA-1 for both build and installer commands. The local `exec.signingIdentity` may be an **Apple Development** certificate: stable development signing is not valid for notarization. Do not change the development setting or select an arbitrary identity. The bundle identifier remains unchanged for compatibility with existing installations.
- **Sparkle EdDSA** signs update archives. Its private key stays in the login Keychain under account `exec-sparkle`. Only its public key (`SUPublicEDKey`) is committed in `macOS/Resources/Info.plist`.

Sparkle 2.10.1 is pinned in `macOS/Package.swift` and `Package.resolved`. After `swift package resolve`, its tools are in `macOS/.build/artifacts/sparkle/Sparkle/bin/`. `generate_keys --account exec-sparkle -p` prints only the public key. Keep a secure backup of the private key outside this repository; do not regenerate or replace it casually, and never commit or log private keys or Keychain exports. Future release machines need the same signing key. See [Sparkle's documentation](https://sparkle-project.org/documentation/) for secure key backup/transfer and key rotation.

The app's public key must match the release-signing key. `prepare-update.sh` checks this before generating an archive. Losing the key requires a deliberate recovery/rotation plan, not just replacing the public key in the next build.

## Prepare a release

1. Start from a clean, committed source tree. Set `CFBundleShortVersionString` to a stable `x.y.z` version and increase the integer `CFBundleVersion` for **every release**. Do not reuse a released version/tag or overwrite its assets.
2. From `macOS/`, run:

   ```sh
   ./scripts/test.sh
   SIGNING_IDENTITY="<Developer ID Application SHA-1>" REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
   ```

   The build script embeds Sparkle, signs each nested helper inside out, enables hardened runtime, and verifies the complete bundle. It builds for the host architecture; an Apple Silicon build is not an Intel/universal release.

3. Preserve a copy of `dist/Exec.app` in a release-specific directory and record the source commit. Submit an archive of that copy using `xcrun notarytool submit --keychain-profile exec-notary`. Do not automatically retry an interrupted submission: query its existing ID/history first.
4. Wait for **Accepted**, inspect the notarization log, then staple the ticket to the preserved app with `xcrun stapler staple`. Do not rebuild or modify the signed app afterward.
5. Prepare the Sparkle ZIP and candidate feed from that preserved app:

   ```sh
   ./scripts/prepare-update.sh /absolute/path/to/notarized/Exec.app
   ```

   This validates the bundle signature, notarization ticket, updater configuration, increasing build number, and local Sparkle public key. It generates a fresh `dist/update-<version>-<build>.<suffix>/` directory containing a ZIP, SHA-256 checksum, and candidate `appcast.xml`. The feed includes an EdDSA archive signature, version/build, OS/hardware requirements, and a URL under the matching GitHub release tag. Deltas are disabled for simplicity. Nothing is uploaded or published.

6. Build the drag-and-drop installer from the same stapled app:

   ```sh
   SIGNING_IDENTITY="<Developer ID Application SHA-1>" ./scripts/prepare-installer.sh /absolute/path/to/notarized/Exec.app
   ```

   The script uses only macOS tools. It creates `dist/installer-<version>-<build>.<suffix>/Exec-macOS-<architecture>.dmg`, with Exec on the left and an Applications shortcut on the right, fixed icon positions/size, and a saved Finder window layout. It validates the input app, signs and verifies the compressed DMG, and never modifies the source app. It needs a logged-in graphical session and permission to automate Finder. Each mount has a unique name to avoid confusing Finder with another mounted installer. Do not recreate the layout manually.

   If preparation fails, its working directory and any mount are preserved for inspection; detach the exact printed mount path before cleanup. There are no automatic retries or forced unmounts.

7. Notarize and staple the **DMG itself** (the app's ticket does not cover it):

   ```sh
   xcrun notarytool submit "$DMG" --keychain-profile exec-notary --no-wait --output-format json
   # Save the returned ID, then query that submission; do not resubmit on timeout.
   xcrun notarytool info "$SUBMISSION_ID" --keychain-profile exec-notary
   xcrun notarytool log "$SUBMISSION_ID" --keychain-profile exec-notary "$LOG_PATH"
   # Only after Accepted and inspecting the log:
   xcrun stapler staple "$DMG"
   xcrun stapler validate "$DMG"
   codesign --verify --strict "$DMG"
   spctl --assess --type open --context context:primary-signature "$DMG"
   (cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
   ```

   Set `DMG` to the generated absolute path, and preserve the submission ID and log alongside release artifacts. Mount the final read-only DMG to verify its saved layout, `/Applications` shortcut, app version and stapled app ticket. The appcast uses the Sparkle ZIP, **not** the DMG.

## Publish in this order

1. Review the candidate feed and verify its version, signature, architecture, and asset URL. Keep previous entries/URLs intact. Record release notes in the GitHub release.
2. Create the matching `v<version>` release at the **source commit used for the build**. Upload the versioned ZIP, its checksum, and the DMG with its checksum. Always name the uploaded DMG **`Exec-macOS-arm64.dmg`** for Apple Silicon releases so the README's `/releases/latest/download/Exec-macOS-arm64.dmg` link continues to work. Renaming the finished DMG does not change its signature or notarization ticket; generate its checksum file using the uploaded filename. Publish the release before publishing the feed.
3. Confirm the public ZIP URL works and matches the generated checksum. Do not alter or replace a ZIP after its signature has been generated.
4. Copy the candidate `appcast.xml` to `docs/appcast.xml`, commit it, and push `main`. GitHub Pages deploys the feed. Confirm the live feed matches the reviewed file.
5. Test **Settings → Updates → Check for Updates…** from a previous updater-enabled release installed in Applications. Confirm download, signature verification, installation, and relaunch. Also test cancellation and an unavailable feed. Local signing checks and mock tests do not verify the live install flow.

Never advertise an unreleased or unnotarized update in the feed. Keep signing/notarization credentials out of GitHub Pages, release assets, logs, and Git. This setup does not automatically publish a release or install updates without user interaction.
