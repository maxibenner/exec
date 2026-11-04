#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Pin a certificate once in local Git config, or explicitly override it per build.
# Never pick an arbitrary certificate or fall back after a signing failure.
identity="${SIGNING_IDENTITY:-$(git config --local --get harness.signingIdentity 2>/dev/null || true)}"
options=(--force)
if [[ -z "$identity" || "$identity" == "-" ]]; then
    if [[ "${REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
        printf 'Stable signing requires SIGNING_IDENTITY or git config harness.signingIdentity.\n' >&2
        exit 1
    fi
    identity="-"
    printf 'WARNING: Ad-hoc development signing; rebuilds may trigger Keychain prompts.\n' >&2
    printf 'See README.md for configuring a stable signing certificate.\n' >&2
else
    options+=(--options runtime)
    printf 'Signing with configured identity: %s\n' "$identity"
fi

swift build -c release --product Harness
bin="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Harness.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Harness" "$app/Contents/MacOS/Harness"
cp Resources/Info.plist "$app/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
codesign "${options[@]}" --sign "$identity" --identifier "$bundle_id" "$app"
codesign --verify --strict "$app"
printf '\nBuilt %s\nRun: open "%s"\n' "$app" "$app"
