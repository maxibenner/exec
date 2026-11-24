#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    printf 'Usage: %s [--dev]\n' "$0"
    printf '  --dev  Build Exec Dev with a separate profile, port, and bundle ID; disable updates.\n'
}
if [[ "$#" -gt 1 ]]; then usage >&2; exit 2; fi
dev=0
case "${1:-}" in
    '') ;;
    --dev) dev=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
app_name="Exec"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
helper_id="app.exec.agent"
if [[ "$dev" == 1 ]]; then
    app_name="Exec Dev"
    bundle_id="local.exec.dev"
    helper_id="$bundle_id.agent"
fi

# Pin a certificate once in local Git config, or explicitly override it per build.
# Never pick an arbitrary certificate or fall back after a signing failure.
identity="${SIGNING_IDENTITY:-$(git config --local --get exec.signingIdentity 2>/dev/null || true)}"
options=(--force)
if [[ -z "$identity" || "$identity" == "-" ]]; then
    if [[ "${REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
        printf 'Stable signing requires SIGNING_IDENTITY or git config exec.signingIdentity.\n' >&2
        exit 1
    fi
    identity="-"
    printf 'WARNING: Ad-hoc development signing; rebuilds may trigger Keychain prompts.\n' >&2
    printf 'See ../docs/development.md for configuring a stable signing certificate.\n' >&2
else
    options+=(--options runtime --timestamp)
    printf 'Signing with configured identity: %s\n' "$identity"
fi

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
# Build the backend from the same checkout, never a stale or separately installed agent.
cargo="${CARGO:-$(command -v cargo || true)}"
if [[ -z "$cargo" && -x "$HOME/.cargo/bin/cargo" ]]; then cargo="$HOME/.cargo/bin/cargo"; fi
if [[ -z "$cargo" ]]; then printf 'Rust/Cargo is required to bundle the Exec backend.\n' >&2; exit 1; fi
agent_target="$PWD/.build/backend"
# Rust 1.93's Mach-O debug stripping can produce unloadable proc-macro dylibs on
# newer macOS. Keep symbols rather than modifying/re-signing compiler artifacts.
MACOSX_DEPLOYMENT_TARGET="$minimum_macos" CARGO_TARGET_DIR="$agent_target" CARGO_PROFILE_RELEASE_STRIP=none \
    "$cargo" build --manifest-path ../backend/Cargo.toml --locked --release --bin exec-agent
# Keep the build SDK distinct from the deployment target. Some Swift toolchains
# otherwise stamp the minimum OS as the SDK, opting into legacy system styling.
build_options=(-c release --sdk "$sdk_path"
    -Xlinker -platform_version -Xlinker macos
    -Xlinker "$minimum_macos" -Xlinker "$sdk_version"
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
swift build "${build_options[@]}" --product Exec
bin="$(swift build "${build_options[@]}" --show-bin-path)"
app="$PWD/dist/$app_name.app"
mkdir -p "$PWD/dist"
staging="$(mktemp -d "$PWD/dist/.exec-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
built="$staging/$app_name.app"
mkdir -p "$built/Contents/MacOS" "$built/Contents/Resources"
cp "$bin/Exec" "$built/Contents/MacOS/$app_name"
# SwiftPM's syntax queries and their license notices must travel with the app.
ditto "$bin/ExecTranscript_ExecTranscript.bundle" "$built/Contents/Resources/ExecTranscript_ExecTranscript.bundle"
cp "$agent_target/release/exec-agent" "$built/Contents/MacOS/exec-agent"
codesign "${options[@]}" --sign "$identity" --identifier "$helper_id" "$built/Contents/MacOS/exec-agent"
cp Resources/Info.plist "$built/Contents/Info.plist"
if [[ "$dev" == 1 ]]; then
    plist="$built/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $app_name" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $app_name" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ExecProfileName string $app_name" "$plist"
    /usr/libexec/PlistBuddy -c 'Add :ExecAgentPort integer 8766' "$plist"
    /usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$plist"
fi
# Compile the layered glass icon and the compatibility ICNS for older macOS.
# Use an absolute input path: the asset compiler service can outlive a worktree.
xcrun actool "$PWD/Resources/Glass_Icon.icon" \
    --compile "$built/Contents/Resources" \
    --output-partial-info-plist "$staging/IconInfo.plist" \
    --app-icon Glass_Icon --platform macosx \
    --minimum-deployment-target "$minimum_macos" --target-device mac \
    --output-format human-readable-text
# SwiftPM links the binary framework but does not assemble a distributable app.
framework="$built/Contents/Frameworks/Sparkle.framework"
mkdir -p "$built/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$built/Contents/Resources/Sparkle-LICENSE.txt"
# Sign inside out, including Sparkle's helpers, with the same identity as Exec.
# Never use --deep for signing; the downloader can have its own entitlements.
codesign "${options[@]}" --sign "$identity" "$framework/Versions/B/XPCServices/Installer.xpc"
codesign "${options[@]}" --sign "$identity" --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
codesign "${options[@]}" --sign "$identity" "$framework/Versions/B/Autoupdate"
codesign "${options[@]}" --sign "$identity" "$framework/Versions/B/Updater.app"
codesign "${options[@]}" --sign "$identity" "$framework"
codesign "${options[@]}" --sign "$identity" --identifier "$bundle_id" "$built"
codesign --verify --deep --strict "$built"
# Never truncate a running, signed executable: macOS can kill it for invalid code pages.
# Publish only after signing succeeds; old processes keep their original executable inode.
if [[ -e "$app" ]]; then mv "$app" "$staging/Previous.app"; fi
if ! mv "$built" "$app"; then
    if [[ -e "$staging/Previous.app" ]]; then
        if ! mv "$staging/Previous.app" "$app"; then
            printf 'Could not restore the previous build. It remains at %s\n' "$staging/Previous.app" >&2
            trap - EXIT
        fi
    fi
    exit 1
fi
printf '\nBuilt %s\nRun: open "%s"\n' "$app" "$app"
if [[ "$dev" == 1 ]]; then
    printf 'Isolated profile: ~/Library/Application Support/Exec Dev/Agent; loopback port: 8766.\n'
    printf 'Credentials are not copied automatically; production remains unchanged.\n'
fi
