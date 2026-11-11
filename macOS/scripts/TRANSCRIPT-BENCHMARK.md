# Transcript container comparison

## Conclusion

A standard SwiftUI `ScrollView` / `LazyVStack` is a credible alternative, not a
clear across-the-board win. In this small synthetic comparison it used less CPU
for scrolling, similar CPU for bottom streaming, and more CPU for resizing and
offscreen updates. No production transcript code was replaced.

This benchmark was developed in a separate worktree from baseline `d799462`.
It does not include unmerged optimization work in other worktrees.

## Reproduce

From `macOS/`:

```sh
bash scripts/benchmark-transcript.sh
# Optional smaller workload:
BENCH_COUNTS=400 bash scripts/benchmark-transcript.sh
```

The harness opens a floating window for each trial. Avoid interacting with it.
It compiles with `swiftc -O`, uses synthetic messages, and never initializes the
app, account stores, updater, or providers. No credentials or model calls are
needed. All build artifacts stay in `.build/`.

The script makes a build-only copy of `TranscriptView.swift`, changing only the
access level of `MessageView` so both containers use the **same production message
renderer**, including Markdown and native text views. Production sources remain
unchanged. The alternate renderer is defined only in the standalone harness.

Environment for the recorded run:

- MacBookAir10,1, ARM64, 8 CPU cores, 16 GiB RAM.
- OS reported by Foundation: Version 27.3 (Build 26C5035r).
- Apple Swift 6.4.2, macOS SDK 27.2. These are not macOS 26 measurements.
- 1000 x 760 content viewport; resize sweep to 700 wide and back.
- 400 or 2,000 messages, alternating user text and assistant Markdown with
  headings, paragraphs, a fenced Swift block, and lists.
- Two fresh-process trials per variant per size, reversing order in trial two.

## Results

Mean **process CPU seconds consumed per phase**, not elapsed seconds or FPS.
Lower is better. The percentage compares lazy with virtual.

| Messages | Phase | Current virtual | LazyVStack | Change |
| --- | --- | ---: | ---: | ---: |
| 400 | Mount at bottom | 0.165 | 0.169 | +3% |
| 400 | Nearby scrolling | 0.558 | 0.487 | -13% |
| 400 | History jumps | 5.598 | 4.954 | -12% |
| 400 | Resize | 0.503 | 0.831 | +65% |
| 400 | Stream at bottom | 1.110 | 1.086 | -2% |
| 400 | Stream while reading history | 0.138 | 0.235 | +71% |
| 2,000 | Mount at bottom | 0.162 | 0.164 | +2% |
| 2,000 | Nearby scrolling | 0.562 | 0.491 | -13% |
| 2,000 | History jumps | 9.936 | 5.481 | -45% |
| 2,000 | Resize | 0.514 | 1.534 | +199% |
| 2,000 | Stream at bottom | 1.219 | 1.277 | +5% |
| 2,000 | Stream while reading history | 0.288 | 0.343 | +19% |

At 2,000 messages, mean history-jump elapsed time was 10.21 s virtual versus
5.92 s lazy; resize was 1.50 s versus 2.09 s. These timings include deliberate
sleeps between operations; mount includes a one-second settling allowance and
is **not** a time-to-first-frame measurement.

Peak resident memory at the end of the 400-message trials was 121.5–122.3 MiB
virtual versus 125.8–127.7 MiB lazy. At 2,000 messages it was 133.1 MiB virtual
versus 131.9–134.2 MiB lazy. This run establishes no meaningful memory advantage.
`ru_maxrss` is a process-lifetime high-water mark, not per-phase live memory.
Both variants were essentially idle in the final one-second samples.

Observed basic behavior: bottom gap after streaming was 0 px virtual and 0–1 px
lazy. Offset drift while streaming offscreen was 0 px in every final trial.
These are numerical spot checks, not full conversation-integrity verification.

Raw final measurements are in `TranscriptBenchmark-results.txt`. An earlier
exploratory run had a misplaced bottom target in the prototype; that was fixed
before the recorded final run.

## Workloads and limitations

- Nearby scrolling: 120 native clip-view scroll operations of 60 px, up and back,
  with a requested 1/60-second pause between operations.
- History jumps: 240 normalized document positions, bottom to top and back.
  Both containers estimate unseen geometry differently, so these do not visit
  an identical set of message IDs or establish real gesture smoothness/FPS.
- Resize: 60 content-width changes with bottom-following enabled.
- Bottom streaming: 80 updates, each appending a short formatted chunk, with a
  30 ms requested pause. Offscreen streaming: 40 shorter updates at 40% scroll.
- CPU includes all harness process work, not WindowServer/GPU work. Requested
  pauses can be delayed by main-thread work. This is not a GPU/energy profile.
- Only two trials on one OS/machine. External activity, caches, and allocator
  behavior can affect the measurements. Small differences are not decisive.
- No images, giant single messages, expanded tool/diff cards, sidebar/header,
  actual model streaming, selection interactions, session switches, or native
  trackpad gesture/bounce testing. There is no live-service validation here.
- The lazy prototype follows the bottom explicitly, but does not implement
  production sent-message shortcuts, restoration on conversation switches, or
  all the expansion/selection/anchor semantics. It is not a complete replacement.

## Rough code reduction

The existing implementation has 447 lines in `TranscriptView.swift` and 113 in
`TranscriptLayout.swift`: **560 lines total**, counting comments and blank lines.
The custom representable/container/row-host machinery (lines 29–399) is 371
lines; the separate layout cache adds 113, for **484 lines of custom machinery**.

The benchmark's `LazyTranscript` is **37 lines** and reuses `MessageView` and
`TranscriptState`. Comparing only these sections gives a theoretical reduction
of **447 lines**. A rough minimal replacement could therefore remove around
**400–450 lines** (roughly 70–80% of that two-file implementation), before
restoring omitted behavior and adapting callers. This is not a production-ready
net diff: robust anchor restoration, message navigation, expansion behavior,
selection, and regression coverage will eat into those savings. Shared Markdown,
message rendering, and tool code remain regardless of the container.

## Verification

- Optimized harness compiled and completed all eight final trials.
- `./scripts/test.sh`: 237 checks passed.
- `./scripts/build-app.sh`: release build and configured stable signing passed.
- No production UI was changed or launched against user stores by this harness.

Recommended next step: try a fuller lazy-container prototype with real tool/diff
fixtures and manual gesture/selection checks, especially resize stability, before
replacing the production implementation. Rerun against the final optimization
branch, rather than treating this older baseline as its performance result.
