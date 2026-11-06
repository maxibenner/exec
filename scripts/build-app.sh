#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

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
    printf 'See README.md for configuring a stable signing certificate.\n' >&2
else
    options+=(--options runtime)
    printf 'Signing with configured identity: %s\n' "$identity"
fi

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
# Keep the build SDK distinct from the deployment target. Some Swift toolchains
# otherwise stamp the minimum OS as the SDK, opting into legacy system styling.
build_options=(-c release --sdk "$sdk_path"
    -Xlinker -platform_version -Xlinker macos
    -Xlinker "$minimum_macos" -Xlinker "$sdk_version")
swift build "${build_options[@]}" --product Exec
bin="$(swift build "${build_options[@]}" --show-bin-path)"
app="$PWD/dist/Exec.app"
mkdir -p "$PWD/dist"
staging="$(mktemp -d "$PWD/dist/.exec-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
built="$staging/Exec.app"
mkdir -p "$built/Contents/MacOS"
cp "$bin/Exec" "$built/Contents/MacOS/Exec"
cp Resources/Info.plist "$built/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
codesign "${options[@]}" --sign "$identity" --identifier "$bundle_id" "$built"
codesign --verify --strict "$built"
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
