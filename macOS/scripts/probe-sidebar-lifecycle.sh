#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/lifecycle-probe
# Synthetic data and harness-owned windows only: no desktop capture, accessibility
# permission, live service, Keychain, or system preference changes.
# Navigation APIs drive production views and native editor ownership. Physical
# mouse/keyboard gestures remain a manual check; no fabricated event assertions.
# --completed / --catalog-first vary lifecycle ordering. --checks runs focused tests.
# Run distinct cases explicitly; failures are never retried. No mixed-version baseline.
sed '/@main struct TestRunner/,$d' Tests/ExecTests/Runner.swift > .build/lifecycle-probe/Checks.swift
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Exec ../shared/ExecRemote/Sources/ExecRemote ../shared/ExecTranscript/Sources/ExecTranscript \
        -name '*.swift' ! -name ExecApp.swift ! -name SparkleUpdater.swift | sort
)
swiftc -swift-version 6 -parse-as-library "${sources[@]}" \
    .build/lifecycle-probe/Checks.swift Tests/ExecTests/SessionLifecycleTests.swift \
    Tools/Benchmarks/SidebarLifecycleProbe.swift -o .build/lifecycle-probe/run
.build/lifecycle-probe/run "$@"
