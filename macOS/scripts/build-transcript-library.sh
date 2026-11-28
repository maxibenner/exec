#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./scripts/shared-transcript.sh

name="Transcript Component Library"
staging="$(mktemp -d "$PWD/.build/.transcript-library.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/$name.app"
mkdir -p "$bundle/Contents/MacOS" dist

# Like the transcript benchmark, use the real message row without changing its production visibility.
sed 's/^private struct MessageView:/struct MessageView:/' Sources/Exec/Features/Transcript/TranscriptView.swift > "$staging/TranscriptView.swift"
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Exec ../shared/ExecRemote/Sources/ExecRemote -name '*.swift' \
        ! -name ExecApp.swift ! -name ChatView.swift ! -name SparkleUpdater.swift ! -name TranscriptView.swift | sort
)
swiftc -swift-version 6 -parse-as-library -whole-module-optimization "${exec_transcript_flags[@]}" \
    "${sources[@]}" "$staging/TranscriptView.swift" Tools/TranscriptLibrary/*.swift \
    -o "$bundle/Contents/MacOS/TranscriptComponentLibrary"
copy_exec_transcript_resources "$bundle/Contents/Resources"
ditto Tools/TranscriptLibrary/PreviewWorkspace "$bundle/Contents/Resources/PreviewWorkspace"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TranscriptComponentLibrary</string>
<key>CFBundleIdentifier</key><string>local.exec.transcript-library</string>
<key>CFBundleName</key><string>Transcript Component Library</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

identity="${SIGNING_IDENTITY:-$(git config --local --get exec.signingIdentity 2>/dev/null || true)}"
if [[ -z "$identity" || "$identity" == "-" ]]; then
    if [[ "${REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
        printf 'Stable signing requires SIGNING_IDENTITY or git config exec.signingIdentity.\n' >&2
        exit 1
    fi
    printf 'Signing the transcript preview ad hoc (no configured identity).\n' >&2
    codesign --force --sign - "$bundle"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$bundle"
fi

# Keep a running copy's executable inode intact when rebuilding.
destination="$PWD/dist/$name.app"
if [[ -e "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
mv "$bundle" "$destination"
printf '%s\n' "$destination"
