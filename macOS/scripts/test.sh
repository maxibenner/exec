#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    # Settings tests inject update actions; never start the live updater in tests.
    find Sources/Exec Tests/ExecTests -name '*.swift' ! -name ExecApp.swift ! -name ChatView.swift ! -name SparkleUpdater.swift | sort
)
swiftc -swift-version 6 -parse-as-library "${sources[@]}" -o .build/exec-checks
.build/exec-checks
