#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
# Stress replaces the original 13 phases; each cycle includes rapid trim/return
# and full removal. No screenshots, real preferences or live services are used.
# --stress-cycles 100 --stress-parents 200 --stress-batch 3
# --stress-kind children|parents|mixed --stress-interval-ms 80
# --stress-noise interleaves metadata, selection and composer focus changes.
# --stress-reuse-ids reuses identities across cycles as well as within a cycle.
# Reuse the compiled binary for DISTINCT cases; never automatically retry failures.
# Reports retain all samples/mutation times; console failures are bounded.
# --polling-cycles 2 --polling-messages 240 [--polling-navigate] instead uses
# production catalog/transcript polling with paged history and wrapping titles.
# Instrument only the diagnostic copy: transparent, noninteractive markers and
# an explicit Reduce Motion policy. Keep production source and OS settings intact.
sidebar=Sources/Exec/Features/Sessions/SessionSidebar.swift
require_once() {
    local count
    count=$(grep -Fc -- "$1" "$2" || true)
    if [[ "$count" != 1 ]]; then
        printf 'Probe hook must occur exactly once (found %s): %s in %s\n' "$count" "$1" "$2" >&2
        exit 1
    fi
}
for hook in '@Environment(\.accessibilityReduceMotion) private var reduceMotion' \
    'accessibilityAddTraits(store.sidebarSelectionID == session.id' \
    '.frame(height: 22, alignment: .center)' \
    '.padding(.top, 3).padding(.bottom, 5)' \
    '.modifier(SidebarAnimatedHeight(animation: rowAnimation))'; do
    require_once "$hook" "$sidebar"
done
# Group marker must measure allocated layout height, outside the height modifier;
# the inner fixed-size content can keep moving after the native row has snapped.
sed \
  -e 's/@Environment(\\.accessibilityReduceMotion) private var reduceMotion/private var reduceMotion: Bool { SidebarAnimationProbe.reduceMotion }/' \
  -e '/accessibilityAddTraits(store.sidebarSelectionID == session.id/a\
                        .background(SidebarProbeMarker(id: session.id, role: "parent"))' \
  -e '/frame(height: 22, alignment: .center)/a\
                        .background(SidebarProbeMarker(id: child.id, role: "child"))' \
  -e '/padding(.top, 3).padding(.bottom, 5)/a\
                        .background(SidebarProbeMarker(id: session.id, role: "footer"))' \
  -e '/modifier(SidebarAnimatedHeight/a\
                .background(SidebarProbeMarker(id: session.id, role: "group"))' \
  "$sidebar" > .build/ProbeSessionSidebar.swift
for role in parent child footer group; do
    require_once "role: \"$role\"" .build/ProbeSessionSidebar.swift
done
require_once 'private var reduceMotion: Bool { SidebarAnimationProbe.reduceMotion }' .build/ProbeSessionSidebar.swift
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Exec ../shared/ExecRemote/Sources/ExecRemote ../shared/ExecTranscript/Sources/ExecTranscript \
        -name '*.swift' ! -name ExecApp.swift ! -name SparkleUpdater.swift ! -name SessionSidebar.swift | sort
)
# Use PROBE_OPTIMIZE=1 for release-like large catalogs; default preserves baseline.
optimization=()
if [[ "${PROBE_OPTIMIZE:-0}" == 1 ]]; then optimization=(-O); fi
# Save provenance next to this binary, not beside a later production rebuild.
shasum -a 256 "$sidebar" "${sources[@]}" .build/ProbeSessionSidebar.swift \
    scripts/probe-sidebar.sh Tools/Benchmarks/SidebarAnimationProbe.swift > .build/sidebar-animation-probe.sources
printf 'PROBE_OPTIMIZE=%s\n' "${PROBE_OPTIMIZE:-0}" >> .build/sidebar-animation-probe.sources
git rev-parse HEAD >> .build/sidebar-animation-probe.sources
swiftc --version >> .build/sidebar-animation-probe.sources
swiftc -swift-version 6 -parse-as-library ${optimization[@]+"${optimization[@]}"} "${sources[@]}" .build/ProbeSessionSidebar.swift \
    Tools/Benchmarks/SidebarAnimationProbe.swift -o .build/sidebar-animation-probe
.build/sidebar-animation-probe "$@"
