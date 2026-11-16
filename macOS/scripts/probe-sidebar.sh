#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
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
swiftc -swift-version 6 -parse-as-library "${sources[@]}" .build/ProbeSessionSidebar.swift \
    Tools/Benchmarks/SidebarAnimationProbe.swift -o .build/sidebar-animation-probe
.build/sidebar-animation-probe "$@"
