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
MACOSX_DEPLOYMENT_TARGET="$minimum_macos" CARGO_TARGET_DIR="$PWD/.build/agent-rust" CARGO_PROFILE_RELEASE_STRIP=none \
    "$cargo" build --manifest-path ../agent-rust/Cargo.toml --locked --release --bin exec-agent
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    # Settings tests inject update actions; never start the live updater in tests.
    find Sources/Exec Tests/ExecTests -name '*.swift' ! -name ExecApp.swift ! -name ChatView.swift ! -name SparkleUpdater.swift | sort
)
swiftc -swift-version 6 -parse-as-library "${sources[@]}" -o .build/exec-checks
.build/exec-checks
