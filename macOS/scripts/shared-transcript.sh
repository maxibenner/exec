#!/bin/bash
# Source from direct swiftc harnesses after changing into macOS/.
# Build the dependency product here to reuse the app's lockfile and .build cache.
# The native build system emits the static archive and Modules/ for swiftc clients.
swift build --build-system native -c release --product ExecTranscript
exec_transcript_bin="$(swift build --build-system native -c release --show-bin-path)"
exec_transcript_flags=(-I "$exec_transcript_bin/Modules" -L "$exec_transcript_bin" -lExecTranscript)

copy_exec_transcript_resources() {
    local destination="$1"
    mkdir -p "$destination"
    ditto "$exec_transcript_bin/ExecTranscript_ExecTranscript.bundle" \
        "$destination/ExecTranscript_ExecTranscript.bundle"
}
