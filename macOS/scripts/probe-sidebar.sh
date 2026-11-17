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
# Instrument only the diagnostic copy: transparent, noninteractive markers and
# an explicit Reduce Motion policy. Keep production source and OS settings intact.
sed \
  -e 's/@Environment(\\.accessibilityReduceMotion) private var reduceMotion/private var reduceMotion: Bool { SidebarAnimationProbe.reduceMotion }/' \
  -e '/accessibilityAddTraits(store.sidebarSelectionID == session.id/a\
                        .background(SidebarProbeMarker(id: session.id, role: "parent"))' \
  -e '/padding(.vertical, 3)/a\
                        .background(SidebarProbeMarker(id: child.id, role: "child"))' \
  -e '/padding(.top, 3).padding(.bottom, 5)/a\
                        .background(SidebarProbeMarker(id: session.id, role: "footer"))' \
  -e '/fixedSize(horizontal: false, vertical: true)/a\
                .background(SidebarProbeMarker(id: session.id, role: "group"))' \
  Sources/Exec/Features/Sessions/SessionSidebar.swift > .build/ProbeSessionSidebar.swift
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Exec ../shared/ExecRemote/Sources/ExecRemote ../shared/ExecTranscript/Sources/ExecTranscript \
        -name '*.swift' ! -name ExecApp.swift ! -name SparkleUpdater.swift ! -name SessionSidebar.swift | sort
)
# Use PROBE_OPTIMIZE=1 for release-like large catalogs; default preserves baseline.
optimization=()
if [[ "${PROBE_OPTIMIZE:-0}" == 1 ]]; then optimization=(-O); fi
# Save provenance next to this binary, not beside a later production rebuild.
shasum -a 256 .build/ProbeSessionSidebar.swift Sources/Exec/Features/Sessions/SidebarRowAnimation.swift \
    Tools/Benchmarks/SidebarAnimationProbe.swift > .build/sidebar-animation-probe.sources
printf 'PROBE_OPTIMIZE=%s\n' "${PROBE_OPTIMIZE:-0}" >> .build/sidebar-animation-probe.sources
swiftc -swift-version 6 -parse-as-library ${optimization[@]+"${optimization[@]}"} "${sources[@]}" .build/ProbeSessionSidebar.swift \
    Tools/Benchmarks/SidebarAnimationProbe.swift -o .build/sidebar-animation-probe
.build/sidebar-animation-probe "$@"
