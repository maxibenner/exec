#!/bin/bash
# Prepare (but do not publish) a Sparkle archive and feed from a notarized app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 ]]; then
    printf 'Usage: %s /path/to/notarized/Exec.app /path/to/release-notes.md\n' "$0" >&2
    exit 1
fi
app="$1"
notes="$2"
# Require notes before signing or archiving; use this same Markdown for GitHub.
if [[ "$notes" != *.md || ! -f "$notes" || ! -r "$notes" ]] || ! grep -q '[^[:space:]]' "$notes"; then
    printf 'Release notes must be a readable, nonempty Markdown (.md) file.\n' >&2
    exit 1
fi
plist="$app/Contents/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
version="$(read_key CFBundleShortVersionString)"
build="$(read_key CFBundleVersion)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build" =~ ^[0-9]+$ ]]; then
    printf 'Expected a stable x.y.z version and an integer build number.\n' >&2
    exit 1
fi
if [[ "$(read_key CFBundleIdentifier)" != "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)" ||
      "$(read_key SUPublicEDKey)" != "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)" ||
      "$(read_key SUFeedURL)" != "https://maxibenner.github.io/exec/appcast.xml" ]]; then
    printf 'The app does not match this repository\x27s updater configuration.\n' >&2
    exit 1
fi
# A release must advance the build, even if the marketing version is unchanged.
latest="$(xmllint --xpath 'string(//channel/item[1]/*[local-name()="version"])' ../docs/appcast.xml)"
if [[ -n "$latest" ]] && { [[ ! "$latest" =~ ^[0-9]+$ ]] || (( 10#$build <= 10#$latest )); }; then
    printf 'Build must be newer than the published feed (current: %s).\n' "$latest" >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
xcrun stapler validate "$app"
spctl --assess --type execute "$app"
architectures="$(lipo -archs "$app/Contents/MacOS/Exec")"
case "$architectures" in
    arm64) architecture=arm64 ;;
    x86_64) architecture=x86_64 ;;
    'x86_64 arm64'|'arm64 x86_64') architecture=universal ;;
    *) printf 'Unsupported architecture: %s\n' "$architectures" >&2; exit 1 ;;
esac
swift package resolve
tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
# Only the public key is printed/read. Private key material stays in Keychain.
public_key="$("$tools/generate_keys" --account exec-sparkle -p)"
if [[ "$public_key" != "$(read_key SUPublicEDKey)" ]]; then
    printf 'The Keychain update-signing key does not match this app.\n' >&2
    exit 1
fi
mkdir -p dist
output="$(mktemp -d "$PWD/dist/update-$version-$build.XXXXXX")"
archive="Exec-$version-macOS-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
cp ../docs/appcast.xml "$output/appcast.xml"
# Sparkle discovers notes by archive basename and safely embeds their Markdown.
cp "$notes" "$output/${archive%.zip}.md"
"$tools/generate_appcast" --account exec-sparkle --maximum-deltas 0 --maximum-versions 0 \
    --embed-release-notes \
    --versions "$build" --download-url-prefix "https://github.com/maxibenner/exec/releases/download/v$version/" \
    --link https://github.com/maxibenner/exec "$output"
xmllint --noout "$output/appcast.xml"
(cd "$output" && shasum -a 256 "$archive" > "$archive.sha256")
printf '\nPrepared: %s\n' "$output"
printf 'Upload the ZIP and checksum to the public v%s GitHub release first.\n' "$version"
printf 'Then review appcast.xml, copy it to docs/appcast.xml, and commit/push the feed.\n'
printf 'Nothing has been published by this script.\n'
