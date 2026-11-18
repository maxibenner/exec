# Local performance measurements

Run scripts from `macOS/`. These tools do not make model calls or read credentials.
No third-party profiler installation is required.

## Visual alternatives

Run `./scripts/preview-indicators.sh` to open ten numbered animation experiments,
each at actual size and 3× magnification. Closing the window exits the preview.
It has no account access and does not modify the app's selected design. It uses a
separate SwiftUI Canvas renderer for experimentation, not the production AppKit
renderer; do not use this ten-animation window for performance comparisons.

## Sidebar animation checks

```sh
./scripts/probe-sidebar.sh --check --output .build/sidebar-motion.json
.build/sidebar-animation-probe --check --reduce-motion --output .build/sidebar-reduced.json
.build/sidebar-animation-probe --check --dark --narrow --output .build/sidebar-dark-narrow.json
```

Opens an isolated window containing the production sidebar, split view and chat detail,
including composer focus restoration. A fake transport and temporary preferences supply
synthetic sessions; no service, Keychain, real profile or model is accessed. Keep the
window visible while sampling. `--simple-detail` removes the chat detail for comparison.

The build script adds transparent, noninteractive geometry markers to a generated copy
of `SessionSidebar` under `.build/`. Production source is not instrumented. It also injects
an explicit Reduce Motion policy into that copy; it never changes system preferences.

The probe samples presentation-layer positions, sizes and inherited opacity roughly every
10 ms through parent/child insertion, removal and reordering, persistence echoes and rollback,
rapid child removal/reinsertion, metadata-only updates and offscreen row recycling. `--check`
requires intermediate motion/fades, correct final row counts and visible content, stable table
identity, no native selection, and preserved composer focus during child updates. It flags
abrupt sampled motion even when final geometry is correct. Reduce Motion requires no
intermediate motion. Reports contain synthetic geometry only; no screenshots are captured.
The script fails if instrumentation hooks drift, measures the allocated group height (not
just its natural content), and records source hashes beside the binary.

For repeated insert/remove bursts, use `--stress-cycles 10 --stress-parents 100`
with optional `--stress-kind children|parents|mixed`, `--stress-batch 3`,
`--stress-interval-ms 80`, `--stress-noise`, or `--stress-reuse-ids`.
`PROBE_OPTIMIZE=1 ./scripts/probe-sidebar.sh ...` builds an optimized probe.
Stress reports retain mutation timestamps and flag undersampled or ambiguous fades;
presentation-layer opacity does not prove visible text fading or GPU frame cadence.

### Polling and transcript contention

The default phases use empty transcripts and explicit catalog refreshes. They do not
establish reliability while loading or streaming conversations. Use the polling workload
for the production two-second catalog loop, 200 ms active transcript readers, 64-message
backfill, streaming suffix updates, and title wrapping during child insertion/removal:

```sh
PROBE_OPTIMIZE=1 ./scripts/probe-sidebar.sh --polling-cycles 5 \
  --polling-messages 1000 --polling-append --check --output .build/sidebar-polling.json
.build/sidebar-animation-probe --polling-cycles 4 --polling-messages 1000 \
  --polling-append --polling-navigate --check --output .build/sidebar-navigation.json
```

`--polling-append` adds messages while children change, rather than only editing the tail.
`--polling-navigate` switches between two conversations (cold first, then resident).
Compare with `--simple-detail` to isolate transcript rendering from data synchronization,
and `--reduce-motion` for immediate-layout behavior. Polling replaces the default phases
and cannot be combined with stress mode. All data remains synthetic; unexpected transport
routes fail closed. Reports include actual catalog/sync response evidence, not just intended
fixture mutations. Initial creation uses an isolated workspace, never a native picker.

A gap of 60 ms or more during a fade makes continuity **inconclusive** and fails `--check`,
even if some intermediate opacity values were seen. Presentation samples can lag during a
main-thread stall and catch up on the next tick; that adjacent jump is not proof of a visible
snap. Multiple children jumping together are correlated evidence, not independent failures.
Do not treat sampling failures, ambiguous duplicate markers, or missed workload overlaps as
passes. Stack sampling adds overhead: use a separate profiling run, not its animation verdict.

Known remaining limits: very long cold/resident transcript remounts and rapid 100-parent
navigation/reversal stress can still exceed this sampling budget. Native view attachment,
SwiftUI fitting-size layout, and TextKit measurement remain main-thread work. The loaded
append-only case is improved by preserving historical estimates; that is not proof that
navigation or arbitrary live workloads are hitch-free. Also, a child created and deleted
between catalog polls has no observed insertion state to animate. Pixel-level animation,
physical interactions, and actual service timing still need interactive validation.

### Implementation choices

The sidebar keeps SwiftUI `List`, which is already backed by a native table here. Stable
family IDs, native dragging, library-owned grey selection, and composer first-responder
ownership are preserved. Height corrections at the same width retarget the animation;
initial measurement and width changes stay immediate. Catalog grouping uses one ordered
snapshot, and transcript insertion reuses retained height estimates instead of scanning
all unmeasured Markdown again.

A grouped `NSTableView` remains a possible fallback, not an automatic simplification.
The earlier experiment (`a49b2de`, reverted by `d5443b1`) required custom layout and event
routing and was rolled back to restore layout/dragging. A replacement must independently
verify grey selection while composing, family dragging, child activation, menus,
accessibility, shortcuts and Reduce Motion. `NSOutlineView` gives native child rows but
requires extra work to preserve today's family footer/background and root-only dragging.
Do not replace the container solely to make an isolated probe pass.

Relevant Apple guidance: [transaction/animation mechanics](https://developer.apple.com/videos/play/wwdc2023/10156/),
[SwiftUI update and list performance](https://developer.apple.com/videos/play/wwdc2023/10160/),
and [AppKit/SwiftUI sizing](https://developer.apple.com/videos/play/wwdc2022/10074/).
These explain mechanisms and measurement priorities, not a diagnosis of this particular app.

The lifecycle probe checks navigation, native editor ownership, and automatic child
cleanup using the same isolated transport as the regression tests:

```sh
./scripts/probe-sidebar-lifecycle.sh --catalog-first
.build/lifecycle-probe/run --completed
```

The probe invokes navigation APIs on production views; physical mouse/keyboard
interaction remains a manual check. `--catalog-first` observes catalog removal before
the child's next read fails; the default observes read failure first. `--completed`
starts with a settled child instead of a running child. `--checks` runs the focused
lifecycle regressions.
Each invocation is a distinct case; failed runs are never automatically retried.

Analyze an existing report with:

```sh
.build/sidebar-animation-probe --analyze-report .build/sidebar-motion.json --check
```

These checks do **not** synthesize a physical drag, measure frame rate/GPU costs, or prove
behavior on another macOS version. Manually check native dragging (including groups with
children), selection, context menus and resizing before release. The normal regression suite
separately checks stable row identity, final sizing and synchronous reorder persistence.

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

## Transcript container benchmark

```sh
./scripts/benchmark-transcript.sh
BENCH_COUNTS="100 400" ./scripts/benchmark-transcript.sh
```

Compiles the production message renderer with a test-only lazy-container alternative.
Each mode/trial runs in a fresh process. Measures nearby scrolling, history jumps,
resizing and bottom/offscreen streaming with synthetic messages. It does not read
profiles or call providers. Raw measurements are printed, not committed.

The lazy alternative is an experiment, not a production renderer. Results do not
establish real gesture smoothness, GPU/energy use, selection correctness, or behavior
with large tool cards/images. Compare repeated trials on the same machine and build;
do not treat historical measurements as current performance guarantees.

## Transcript streaming motion probe

```sh
./scripts/probe-transcript-streaming.sh .build/transcript-streaming-results
.build/transcript-streaming-probe --reduce-motion .build/transcript-streaming-reduced
```

Opens one isolated native transcript at a time with synthetic long Markdown/text,
never a profile, provider, Keychain or account. Runs light/dark × 430/900pt ×
fast/slow/bursty cases. The script injects only a test-local Reduce Motion policy
into a generated transcript copy; it does not change system preferences.

Reports include actual presentation-layer offsets and converted native positions,
logical scroll positions, current-offset overlap checks, same-frame coalescing,
upward direction/settling, bounded offset, overscan geometry, tool-card opacity,
passive/rejected hit-test stability, pre-delivery press/drag/context-menu rebasing,
manual pause/resume (including the 2pt opt-out),
resize/insets, Reduce Motion changes, history geometry and remount/navigation.
Interaction checks compare actual displayed link glyphs with the native character
and hit view at the same window point, including the old incorrect character,
unpainted pending growth, selection notifications and a displayed native button.
They also verify the next committed presentation anchor, reader opt-out and safe
range clamping. Only this diagnostic interaction phase freezes a sampled layer's
clock; overlap, settling and status-only completion run on the normal clock.
Completion checks retain the original animation start/from/duration/deadline with
a nonzero presentation offset, while final Markdown corrections settle immediately.
Synthetic events pass through the app's local monitors and stop at the probe window
before opening links/menus; no system events are posted. `--smoke` runs the first
matrix case for targeted diagnosis.
A separate first-paint phase compares **every alpha pixel** in streamed TextKit
output against an ordinary native text-view/layout-manager reference, including
partial final text and an unfinished code fence. PNGs are offscreen TextKit renders,
not desktop/window screenshots. Bitmap work is separate from motion sampling so
rasterization does not consume the animation being measured. JSON/PNG outputs and
build products remain under `.build/`; no reports are committed.

Following still pins synchronously. Only actual incoming growth receives a single
180ms ease-out document-layer translation, incorporating the current presentation
offset. Arrivals before paint coalesce. The compensation is capped at 72pt; larger
bursts snap the excess, and sustained arrivals can retain a bounded visual offset.
There is no text fade, reveal queue or Markdown cross-dissolve. Passive hit testing
has no motion side effects. Reader presses/drags/menu gestures inside the transcript
rebase the displayed compensation into native scrolling before target delivery,
then opt out of following and retain a reading anchor. The presentation viewport,
not queued compensation/model geometry, is used even before paint. Native selection
notifications and keyboard/wheel/scroller input use the same rebase. The new origin
is clamped to the valid scroll range; preservation is necessarily limited at a
boundary or when content itself reflows. Reduce Motion and detach still cancel
immediately. Geometry-preserving status-only completion finishes existing motion
without restarting; changed Markdown structure/styles and layout corrections settle.
Tool entrances and the separate 200ms send anchor remain independent.

The fixture is deterministic; compositor sampling cadence is not. These checks do
not establish physical gesture feel, live provider pacing, GPU frame rate or final
composited pixel/clipping correctness. Overscan geometry and full TextKit pixels
are checked separately; manual inspection of the final composited viewport,
physical selection/link/menu gestures, VoiceOver actions and arbitrary bursty
streams remains necessary. Programmatic selection exercises the shared native
notification path, not end-to-end assistive-technology interaction.
