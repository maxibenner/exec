#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
source ./scripts/shared-transcript.sh
swiftc -O -swift-version 6 -parse-as-library "${exec_transcript_flags[@]}" \
    Sources/Exec/Features/Transcript/WorkingIndicator.swift \
    Sources/Exec/Features/Transcript/WorkingIndicatorProbe.swift \
    Tools/Benchmarks/IndicatorBenchmark.swift -o .build/indicator-benchmark
copy_exec_transcript_resources .build
EXEC_PROFILE_INDICATOR=1 .build/indicator-benchmark
