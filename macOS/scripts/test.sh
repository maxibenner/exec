#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
# Integration checks launch only this checkout's helper with temporary profiles,
# no inherited provider credentials, no Keychain and no live inference.
cargo="${CARGO:-$(command -v cargo || true)}"
if [[ -z "$cargo" && -x "$HOME/.cargo/bin/cargo" ]]; then cargo="$HOME/.cargo/bin/cargo"; fi
if [[ -z "$cargo" ]]; then printf 'Rust/Cargo is required for integration checks.\n' >&2; exit 1; fi
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
MACOSX_DEPLOYMENT_TARGET="$minimum_macos" CARGO_TARGET_DIR="$PWD/.build/backend" CARGO_PROFILE_RELEASE_STRIP=none \
    "$cargo" build --manifest-path ../backend/Cargo.toml --locked --release --bin exec-agent
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    # Settings tests inject update actions; never start the live updater in tests.
    find Sources/Exec Tests/ExecTests ../shared/ExecRemote/Sources/ExecRemote ../shared/ExecTranscript/Sources/ExecTranscript -name '*.swift' ! -name ExecApp.swift ! -name SparkleUpdater.swift | sort
)
swiftc -swift-version 6 -parse-as-library "${sources[@]}" -o .build/exec-checks
.build/exec-checks
# Posted mouse events need a separate process running NSApplication.run().
.build/exec-checks --composer-events
# Assert real intermediate presentation frames, not just final sidebar geometry.
# These use isolated synthetic sessions and never capture the user's screen.
./scripts/probe-sidebar.sh --check --verify-detectors --output .build/sidebar-motion.json
.build/sidebar-animation-probe --check --reduce-motion --output .build/sidebar-reduced.json
