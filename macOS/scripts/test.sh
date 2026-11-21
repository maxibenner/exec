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
# The expanded fork matrix takes ~36s; keep separate 60s watchdogs rather than
# making the remaining event checks compete with it or increasing all timeouts.
.build/exec-checks --composer-events --filter 'Forked composers'
.build/exec-checks --composer-events --exclude-filter 'Forked composers'
# A real @main App Window catches navigation/SwiftUI flush ordering that an
# NSHostingView + NSWindow cannot. Three forks include two after sidebar reveal.
./scripts/probe-composer-scene.sh --screen=0 --speed=slow --sidebar=hidden --forks=3
# Assert real intermediate presentation frames, not just final sidebar geometry.
# These use isolated synthetic sessions and never capture the user's screen.
# Include empty catalogs, metadata echoes and native collapse/reveal lifecycles.
lifecycle=(--empty-lifecycle --parent-echo --hidden-updates --cycle-sidebar)
./scripts/probe-sidebar.sh --check --verify-detectors "${lifecycle[@]}" --output .build/sidebar-motion.json
.build/sidebar-animation-probe --check --reduce-motion --reveal-sidebar "${lifecycle[@]}" --output .build/sidebar-reduced.json
