#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
# Activates synthetic UI. Do not type/click during the probe. No live backend,
# credentials, Keychain, screen capture, production instrumentation or retries.
# Default smoke: three slow forks, initially hidden sidebar, actual display 0.
# Options: --screen=N --speed=fast|slow --sidebar=hidden|visible --forks=2...20
# Optional --move-to=N moves the same scene after fork one (e.g. between scales).
# Reuse .build/composer-scene-probe for DISTINCT cases after this compilation.
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Exec Tests/ExecTests ../shared/ExecRemote/Sources/ExecRemote ../shared/ExecTranscript/Sources/ExecTranscript \
        -name '*.swift' ! -name ExecApp.swift ! -name SparkleUpdater.swift ! -name Runner.swift | sort
)
swiftc -swift-version 6 -parse-as-library "${sources[@]}" Tools/Benchmarks/ComposerSceneProbe.swift -o .build/composer-scene-probe
.build/composer-scene-probe "$@"
