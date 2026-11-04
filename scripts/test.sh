#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Harness Tests/HarnessTests -name '*.swift' ! -name HarnessApp.swift ! -name ChatView.swift | sort
)
swiftc -swift-version 6 -parse-as-library "${sources[@]}" -o .build/harness-checks
.build/harness-checks
