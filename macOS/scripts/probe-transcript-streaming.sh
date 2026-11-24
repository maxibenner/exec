#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
# Test-only policy injection; never changes system accessibility preferences.
sed 's/NSWorkspace.shared.accessibilityDisplayShouldReduceMotion/TranscriptStreamingProbe.reduceMotion/g' \
    Sources/Exec/Features/Transcript/TranscriptView.swift > .build/StreamingProbeTranscriptView.swift
source ./scripts/shared-transcript.sh
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Exec ../shared/ExecRemote/Sources/ExecRemote \
        -name '*.swift' ! -name ExecApp.swift ! -name ChatView.swift ! -name SparkleUpdater.swift ! -name TranscriptView.swift | sort
)
swiftc -O -swift-version 6 -parse-as-library "${exec_transcript_flags[@]}" "${sources[@]}" .build/StreamingProbeTranscriptView.swift Tools/Benchmarks/TranscriptStreamingProbe.swift -o .build/transcript-streaming-probe
copy_exec_transcript_resources .build
.build/transcript-streaming-probe "$@"
