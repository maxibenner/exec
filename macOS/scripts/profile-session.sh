#!/bin/bash
# Read-only process measurements using built-in macOS tools.
set -euo pipefail
pid="${1:-}"
seconds="${2:-30}"
mode="${3:-}"
if [[ ! "$pid" =~ ^[1-9][0-9]*$ || ! "$seconds" =~ ^[1-9][0-9]*$ ]] || (( seconds > 900 )) || [[ -n "$mode" && "$mode" != "--sample" ]]; then
    echo "Usage: $0 PID [seconds: 1-900] [--sample]" >&2
    exit 1
fi
kill -0 "$pid"
output="$(mktemp -d "${TMPDIR:-/tmp}/exec-session-profile.XXXXXX")"
printf 'Local diagnostics: %s\n' "$output"
printf 'CPU 100%% = one core. Ignore the first top sample (no interval baseline).\n'
printf 'Only the target process is measured, not child processes or WindowServer.\n'
sampler=""
if [[ "$mode" == "--sample" ]]; then
    sample_seconds=10
    if (( seconds < sample_seconds )); then sample_seconds="$seconds"; fi
    /usr/bin/sample "$pid" "$sample_seconds" 10 -file "$output/stacks.txt" > "$output/sample-status.txt" 2>&1 &
    sampler=$!
    printf 'Stack sampling enabled; it adds overhead and may record local paths/symbols.\n'
fi
# Select numeric fields only: no command arguments, environment, or conversation content.
/usr/bin/top -l "$((seconds + 1))" -s 1 -pid "$pid" \
    -stats pid,cpu,mem,threads,time > "$output/process.txt"
if [[ -n "$sampler" ]]; then
    if ! wait "$sampler"; then
        printf 'Stack sampling failed; see sample-status.txt. Process measurements are separate.\n' >&2
    fi
fi
tail -n 15 "$output/process.txt"
printf '\nFull report: %s/process.txt\nNo automatic upload. Review stack samples before sharing.\n' "$output"
