#!/bin/bash
# Build a signed drag-and-drop DMG from an already notarized, stapled app.
# Notarization/submission remains explicit; this script never uploads or retries.
set -euo pipefail
if [[ $# != 1 || -z "${SIGNING_IDENTITY:-}" ]]; then
    printf 'Usage: SIGNING_IDENTITY=<Developer-ID-SHA-1> %s /path/to/Exec.app\n' "$0" >&2
    exit 1
fi
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
cd "$(dirname "$0")/.."
plist="$app/Contents/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
version="$(read_key CFBundleShortVersionString)"
build="$(read_key CFBundleVersion)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build" =~ ^[0-9]+$ ||
      "$(read_key CFBundleIdentifier)" != "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)" ]]; then
    printf 'Expected a versioned Exec app matching this repository.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
xcrun stapler validate "$app"
spctl --assess --type execute "$app"
case "$(lipo -archs "$app/Contents/MacOS/Exec")" in
    arm64) architecture=arm64 ;;
    x86_64) architecture=x86_64 ;;
    'x86_64 arm64'|'arm64 x86_64') architecture=universal ;;
    *) printf 'Unsupported architecture.\n' >&2; exit 1 ;;
esac
mkdir -p dist
output="$(mktemp -d "$PWD/dist/installer-$version-$build.XXXXXX")"
# The unique mount basename also gives Finder an unambiguous disk name, even
# while other release images are mounted. Do not use a generic "mount" path.
volume="Exec $version ($build) ${output##*.}"
mountpoint="$output/$volume"
mkdir "$output/staging" "$mountpoint"
printf 'Working directory: %s\n' "$output"
trap 'printf "Installer files preserved at: %s\n" "$output"' EXIT
ditto "$app" "$output/staging/Exec.app"
ln -s /Applications "$output/staging/Applications"
# Leave enough free space for Finder metadata, including on larger releases.
size_kb="$(du -sk "$output/staging" | awk '{print $1}')"
size_mb=$((size_kb / 1024 + 32))
hdiutil create -volname "$volume" -srcfolder "$output/staging" -fs HFS+ \
    -format UDRW -size "${size_mb}m" "$output/installer-writable.dmg"
hdiutil attach "$output/installer-writable.dmg" -mountpoint "$mountpoint" \
    -noverify -noautoopen -nobrowse
# Finder writes .DS_Store. Pass names as arguments rather than interpolating
# paths into AppleScript, and retain explicit objects for nested properties.
osascript - "$volume" <<'APPLESCRIPT'
on run arguments
    set volumeName to item 1 of arguments
    with timeout of 30 seconds
        tell application "Finder"
            tell disk volumeName
                open
                set current view of container window to icon view
                set toolbar visible of container window to false
                set statusbar visible of container window to false
                set bounds of container window to {240, 180, 840, 540}
                set viewOptions to icon view options of container window
                set arrangement of viewOptions to not arranged
                set icon size of viewOptions to 112
                set text size of viewOptions to 14
                set background color of viewOptions to {65535, 65535, 65535}
                close
                open
                set position of item "Exec.app" to {150, 150}
                set position of item "Applications" to {450, 150}
            end tell
            set selection to {}
            delay 3
            tell disk volumeName
                close
                open
                delay 2
                close
            end tell
        end tell
    end timeout
end run
APPLESCRIPT
# A failure leaves the image mounted for inspection; do not force detach or
# silently retry. The operator can inspect and detach this exact path.
test -f "$mountpoint/.DS_Store"
test "$(readlink "$mountpoint/Applications")" = /Applications
codesign --verify --deep --strict "$mountpoint/Exec.app"
xcrun stapler validate "$mountpoint/Exec.app"
sync
hdiutil detach "$mountpoint"
dmg="$output/Exec-macOS-$architecture.dmg"
hdiutil convert "$output/installer-writable.dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$dmg"
codesign --verify --strict "$dmg"
signature_details="$(codesign -dvv "$dmg" 2>&1)"
if ! grep -q '^Authority=Developer ID Application:' <<< "$signature_details"; then
    printf 'DMG must be signed with a Developer ID Application certificate.\n' >&2
    exit 1
fi
hdiutil verify "$dmg"
printf '\nCreated: %s\n' "$dmg"
printf 'Next: notarize this DMG, inspect its log, staple and validate it, then create its SHA-256 checksum.\n'
printf 'Do not publish or checksum it before stapling. Nothing has been uploaded.\n'
