# Local performance measurements

Run scripts from `macOS/`. These tools do not make model calls or read credentials.
No third-party profiler installation is required.

## Visual alternatives

Run `./scripts/preview-indicators.sh` to open ten numbered animation experiments,
each at actual size and 3× magnification. Closing the window exits the preview.
It has no account access and does not modify the app's selected design. It uses a
separate SwiftUI Canvas renderer for experimentation, not the production AppKit
renderer; do not use this ten-animation window for performance comparisons.

## Indicator comparison

```sh
./scripts/profile-indicator.sh
```

Builds an optimized, isolated SwiftUI host around the production indicator. The small
window floats above other windows to keep samples visible. It measures hidden,
animated, frozen, and animated-again phases, 10 seconds each after 2 seconds of settling.
Output includes whole-process CPU, active layer animations, and animation starts during
measurement. Expect 15 active animations while visible and animated, zero when frozen.
CPU 100% means one core. The frozen view uses production Reduce Motion rendering without
changing OS settings. If macOS Reduce Motion is enabled, animated phases also remain
static; check the active-animation count and visibility before interpreting results.

This is not a full Exec session: it excludes transcript layout, tools, streaming,
providers, and WindowServer/GPU work. Startup and instrumentation overhead can affect
results. Compare repeated phases rather than attributing every change to the animation.
Core Animation replaces the old timer/draw probes: there is no per-frame application
callback. The app precomputes and caches opacity curves at 30 samples/second over their
shared ~419-second period, preserving the independent-neuron pattern without a loop seam.
This trades some startup/memory work for reduced steady-state app CPU; the compositor
still does work. System-wide energy/GPU costs are not established by this benchmark.

## Whole-session CPU and memory

Find the running app PID in Activity Monitor, or with `pgrep -x Exec`, then:

```sh
./scripts/profile-session.sh PID 30
./scripts/profile-session.sh PID 30 --sample
```

The second form additionally captures a 10-second native stack sample (or the shorter
requested duration). It adds overhead; first measure without sampling. Reports go to
a private temporary directory printed by the script, not the repository. The first
`top` sample lacks an interval baseline and should be ignored. CPU, memory, thread
count and accumulated CPU time cover the target process only, not tools/child processes,
WindowServer, or the GPU. `top` also includes system-wide summary statistics.

For meaningful comparisons, measure the same app build and window arrangement during:
idle; a tool waiting on `sleep`; response streaming; and transcript scrolling. Avoid
comparing a cold launch with a warmed-up session. These reports are process-wide, not
attributed to a particular chat when multiple sessions are running. No automatic
inference, tool execution, or retry is performed by the profiling scripts.

## Instruments probes

The app has opt-in **Indicator animations started** and **Indicator animations stopped**
events in the `Exec` Points of Interest log. They record layer counts only—no user content.
They are disabled unless the process starts with `EXEC_PROFILE_INDICATOR=1`.

For a profiling run, quit Exec normally first, then launch the built executable:

```sh
EXEC_PROFILE_INDICATOR=1 ./dist/Exec.app/Contents/MacOS/Exec
```

Attach Instruments Time Profiler and Points of Interest to that process. The normal
app may perform its usual startup/account operations; unlike the standalone benchmark,
this is not an isolated test. Do not launch a second instance against the same stores.
Turning probes on requires a new process; merely rebuilding does not affect a running app.
Stack samples can include local paths, process metadata, and symbols. Review them before
sharing. No report is uploaded automatically.
