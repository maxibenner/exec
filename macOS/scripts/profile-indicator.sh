#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -O -swift-version 6 -parse-as-library \
    Sources/Exec/Features/Transcript/WorkingIndicator.swift \
    Sources/Exec/Features/Transcript/WorkingIndicatorProbe.swift \
    Tools/Benchmarks/IndicatorBenchmark.swift -o .build/indicator-benchmark
EXEC_PROFILE_INDICATOR=1 .build/indicator-benchmark
