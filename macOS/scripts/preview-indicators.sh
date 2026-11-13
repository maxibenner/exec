#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.build/IndicatorPreview.app"
mkdir -p "$app/Contents/MacOS"
# Never overwrite the executable inode of an already-running preview.
staging="$(mktemp -d "$PWD/.build/.indicator-preview.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
swiftc -O -swift-version 6 -parse-as-library Tools/Benchmarks/IndicatorPreview.swift -o "$staging/IndicatorPreview"
mv "$staging/IndicatorPreview" "$app/Contents/MacOS/IndicatorPreview"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IndicatorPreview</string>
<key>CFBundleIdentifier</key><string>local.exec.indicator-preview</string>
<key>CFBundleName</key><string>Indicator Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
open "$app"
