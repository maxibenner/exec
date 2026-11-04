#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Harness
bin="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Harness.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Harness" "$app/Contents/MacOS/Harness"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf '\nBuilt %s\nRun: open "%s"\n' "$app" "$app"
