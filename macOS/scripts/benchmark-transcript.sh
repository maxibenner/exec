#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
# Expose the existing row only in the standalone harness; production stays unchanged.
sed 's/^private struct MessageView:/struct MessageView:/' Sources/Exec/Features/Transcript/TranscriptView.swift > .build/BenchmarkTranscriptView.swift
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Exec -name '*.swift' ! -name ExecApp.swift ! -name ChatView.swift ! -name SparkleUpdater.swift ! -name TranscriptView.swift | sort
)
swiftc -O -swift-version 6 -parse-as-library "${sources[@]}" .build/BenchmarkTranscriptView.swift Tools/Benchmarks/TranscriptBenchmark.swift -o .build/transcript-benchmark
# Each trial is a fresh process, avoiding shared Markdown/view caches between variants.
for count in ${BENCH_COUNTS:-400 2000}; do
    for trial in 1 2; do
        if [[ "$trial" == 1 ]]; then modes="virtual lazy"; else modes="lazy virtual"; fi
        for mode in $modes; do
            .build/transcript-benchmark "$mode" "$count" "$trial"
        done
    done
done
