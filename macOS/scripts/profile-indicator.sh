#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -O -swift-version 6 -parse-as-library \
    Sources/Exec/App/WorkingIndicator.swift \
    Sources/Exec/App/WorkingIndicatorProbe.swift \
    scripts/IndicatorBenchmark.swift -o .build/indicator-benchmark
EXEC_PROFILE_INDICATOR=1 .build/indicator-benchmark
