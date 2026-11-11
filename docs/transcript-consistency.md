# Transcript consistency investigation

## Scope and verification

Investigated application source at `6ee072a` on macOS 27.3 (26C5035r), arm64, Swift 6.4.2. This is an investigation, not a production fix. No files under `Sources/` were changed.

Work included:

- Reading the virtual transcript, row hosting, text measurement, Markdown rendering, composer inset, sidebar, and existing regression tests.
- Native-window probes using synthetic long prose, 300–500-line submissions, Unicode, unbroken tokens, historical rows, width changes, selection, and asynchronous Markdown rendering.
- An integration probe using the actual `ChatWindowLayout`, `ConversationView`, composer, an isolated temporary session store, and `FakeProvider`; no live inference or user Keychain access.
- An initial full `./scripts/test.sh` run: **237 checks passed**.
- A final full test invocation: **failed at the existing sidebar-visibility assertion in `StartupWindowTests.swift:248`**, before reaching the later transcript checks. It expected the sidebar to remain collapsed after a presentation change. No production code or existing tests had changed. This is a repeatability problem observed during the investigation, not a clean final suite result; the failed invocation was not retried.
- `./scripts/build-app.sh`: **passed**, including the configured stable signing identity and strict signature verification. The signed application was not launched against the user's sessions.

The results below are native geometry observations, not screenshot-based visual verification. Exact point values and AppKit behavior may differ on other macOS versions. Physical trackpad momentum/rubber-banding, scrollbar dragging, and the user's specific affected transcripts remain unverified.

## Summary

| Finding | Confidence | Likely symptom |
| --- | --- | --- |
| Live native text height diverges from the height assigned by SwiftUI | Reproduced without changing the rendering engine | Persistent blank areas inside long user rows; apparent holes |
| Offscreen height estimates severely underestimate multiline submissions | Reproduced | Scrollbar thumb/position repeatedly recalculating |
| Anchors preserve pixels inside a message, not the text being read | Geometry reproduced; semantic position independently measured | Reading position changes during sidebar/window reflow |
| Raw Markdown placeholder and parsed output can have radically different heights | Reproduced | A large height correction/snap after asynchronous rendering |
| Sidebar collapse/visibility is not consistently stable in the integration harness | Observed, plus existing test failure; exact cause unresolved | Transient width reversal and transcript reflow |
| Native text resizing can override bottom pinning in legacy TextKit mode | Reproduced only after explicitly forcing that mode | Conditional scroll jump and loss of follow-latest; not established as the everyday production path |

The evidence does **not** support treating all of this as the computer simply catching up. There is a persistent inner-view geometry defect, alongside predictable estimation/reflow effects and an unresolved sidebar-state issue.

## 1. Persistent blank region inside a long user message

**Priority: high.**

Minimal fixture: one user message containing `String(repeating: "x\n", count: 300)`, in a 900 × 650 transcript viewport with a 140-point composer inset.

After layout settled:

| Measurement | Observed |
| --- | ---: |
| Native message row height | 5,732 pt |
| Text height assigned by its SwiftUI representable host | 5,716 pt |
| Actual native text view height at the bottom | 4,906 pt |
| Actual text top relative to the row | 818 pt |
| Intended user-bubble top padding | 8 pt |

Scrolling to the top and waiting two seconds did not repair it: the text top remained **815 pt** below the row top. A 650-point viewport at the start of that row therefore contains no text, even though the row is mounted and the underlying message is present.

A separate 300-line numbered-text fixture without a trailing newline also exhibited the mismatch. This is not solely a trailing-newline case. Long single-paragraph prose was a useful negative control: its native text frame matched the assigned height, with normal 8-point top/bottom padding.

### Mechanism established by inspection

- `LinkedText.swift:17–30` makes a selectable native text view and sets `isVerticallyResizable = true`.
- `LinkedText.swift:112–160` independently measures the content with `LinkedTextMeasurement` and returns that height to SwiftUI.
- The live native view can subsequently choose a different height from the one assigned by its representable host.
- In the observed view hierarchy, the intermediate `AppKitPlatformViewHost` is unflipped while the text view is flipped. The native text view retains origin zero in its shorter frame, translating the height difference into a large top displacement in the row.
- The outer `MessageHost` still has the expected row height. Comparing its frame against `fittingSize` does not detect the inner text displacement.

A **diagnostic-only intervention** disabled native vertical self-resizing and restored the text view's frame to its parent's bounds. The text top returned from 815 pt to **8 pt**, with no change to the message, row height, or document height.

That local experiment identifies conflicting ownership of text sizing as a strong repair target. It is not a validated production fix: selection, links, streaming, accessibility, long text, and other supported OS versions still need regression checks before changing this behavior.

### Relationship to the report

This directly establishes an apparent transcript hole and excess space **inside** a submitted user element. The most reliable reproduction placed the excess space **above** the text, not specifically after the final line. The user's exact end-of-bubble whitespace case remains unconfirmed and should not be conflated with this reproduction.

## 2. Scrollbar recalculation is substantially amplified by weak estimates

**Priority: medium, after correctness of live text sizing.**

`TranscriptLayout.swift:107–111` estimates height from UTF-8 byte count divided by a width-derived character count. It does not count explicit newlines and caps the estimate at 100 lines.

For the 300-line user fixture at row width 820:

- Estimated height: **136 pt**.
- Measured row height: **5,732 pt**, approximately **42 times** the estimate.

The user bubble also has its own narrower text width (`TranscriptView.swift:420–430`, maximum outer width 600 plus padding), whereas the estimate uses the full row width. Byte count is additionally a poor proxy for rendered width for Unicode. Tool rows uniformly start at 80 pt regardless of eventual disclosure content.

A stress transcript of 100 identical 300-line user rows initially had a document height of **49,744 pt** after the bottom rows were measured. Visiting historical positions in steps of ten rows increased it to **575,768 pt**, with no message edits. The scroller's reported knob proportion changed from **0.01307** to **0.001129**.

This is a deliberately extreme synthetic transcript, not a claim about normal chat size. It demonstrates why the thumb can keep changing as history is explored. Offscreen rows are intentionally not all measured in advance, so some correction is inherent in this virtualized design. However, it is not just CPU delay: the implementation has no accurate measurement for those rows until they are mounted.

`TranscriptLayout.resize(to:)` also retains old-width geometry for offscreen rows. Returning to those rows after a sidebar width change can produce further corrections. Preserving measured geometry has a sound purpose—avoiding wholesale layout churn—but estimate quality should be improved without discarding that benefit.

## 3. Width changes preserve a pixel offset, not the same reading position

**Priority: medium.**

`TranscriptLayout.Anchor` contains only message ID and a pixel offset (`TranscriptLayout.swift:6–8,69–77`). This preserves a row's position, but not a particular line or character within a very long wrapped message.

Using a 31,000-character user paragraph and a viewport top at y = 2,000:

| Viewport width | Preserved scroll y | Independently calculated character at top |
| --- | ---: | ---: |
| 900 pt | 2,000 pt | 9,556 |
| 620 pt | 2,000 pt | 8,209 |
| 900 pt again | 2,000 pt | 9,556 |

The character calculation used a separate text layout with the same attributed source and actual displayed text width; it did not access the live view's legacy layout manager.

Thus the scroll offset can be numerically stable while the reader moves about **1,347 characters backward** when the sidebar narrows the text. Repeated open/close cycles reflow between those positions. This is a limitation of the current anchoring policy, distinct from a missing-row bug or loss of bottom pinning.

For untouched, bottom-pinned prose, 900 → 620 → 420 → 900 width changes stayed at the bottom in the retained probe. Normal selection did not break that result.

## 4. Asynchronous Markdown changes can cause very large height corrections

**Priority: medium; improve after the live text geometry issue.**

`MarkdownView.swift:9–34` initially displays literal attributed source when rendered Markdown is not cached, then asynchronously replaces it with parsed text. Soft line breaks can collapse into spaces during parsing.

For an assistant message with the same 300 single-newline-separated `x` lines:

- Initial measured row height: **5,716 pt**.
- Parsed row height: **73 pt**.
- Document height with the 140-point inset: **5,908 → 650 pt**.

The eventual correction worked in this isolated case. It is nevertheless a substantial geometry transition, not minor rounding. Raw source is acting as both a visual placeholder and a temporary measurement. It is a confirmed mechanism for snapping after rendering catches up, but does not by itself prove a persistent bottom-gap defect.

## 5. Sidebar state/width reversal needs its own follow-up

**Priority: medium; cause unresolved.**

The full-view integration probe mounted the actual sidebar and conversation, then called the native split controller's `toggleSidebar` action. At a 720-point window width, some samples recorded transcript width **480 → 720 → 480** during a toggle sequence rather than a stable transition. With the long paragraph, document height moved **10,893 → 6,542 → 10,893 pt**. Bottom following remained enabled in those samples.

Separately, the final unchanged regression-suite invocation failed at `StartupWindowTests.swift:248`: after toggling the sidebar closed and changing presentation state, the sidebar was not collapsed as expected. The initial full-suite run had passed this check.

These observations justify investigating synchronization between `NavigationSplitView` visibility, native collapse state, and view updates. They do not yet establish which component initiates the reversal, nor that a physical toolbar click has identical timing to the harness. Do not label the sidebar interaction fully verified or fixed.

## 6. Conditional native scrolling hazard, and a diagnostic caveat

An early diagnostic inspected the live `NSTextView.layoutManager` to compare glyph extents. On this system that access forces the legacy TextKit path and changes the behavior being measured.

After explicitly forcing that mode, shrinking the long prose viewport from 900 to 620 pt:

1. The transcript correctly restored the new bottom to y = **6,946**.
2. Native text resizing moved the clip to y = **6,868**.
3. `followsLatest` became false, leaving **78 pt** below the viewport.

The captured native stack included:

```text
NSTextView _setFrameSize:forceScroll:
NSTextView _centeredScrollRectToVisible:forceCenter:
NSView scrollRectToVisible:
NSClipView ... scrollToPoint:
```

`TranscriptView.swift:171–183` interprets bounds changes outside its own `updating` section as scrolling once viewport size matches `lastSize`. This can mistake a native layout-driven scroll for user intent.

**Qualification:** the untouched rendering path and ordinary programmatic text selection stayed bottom-pinned in the control. Application-source inspection did not find a call to the linked transcript text view's legacy layout manager; the direct `.layoutManager` use in `DiffCodeView` concerns a different view. This is a conditional robustness issue, not proof that legacy TextKit explains the user's ordinary sidebar symptoms. The retained diagnostic explicitly separates the modes to avoid repeating that inference error.

## What did not reproduce / what appears sound

- No persistent excess document height from composer insets alone. Explicitly shrinking the inset from 320 to 100 pt removed exactly 220 pt and retained bottom pinning.
- In the actual composer/fake-send integration at both 980- and 720-point window widths, a 300-line draft increased the measured composer inset to about **242.31 pt**; sending returned it to **131 pt**. The transcript stayed at its computed bottom. This does not rule out a gesture/async timing-specific problem.
- The filtered empty assistant-placeholder tests, disclosure-size tests, navigation/anchor tests, row-reuse tests, and short-message live-resize tests all passed in the initial suite.
- A mixed-history probe did not identify missing native row hosts in its sampled visible ranges. The confirmed blank-region case had a mounted row with displaced text, rather than absent message data.
- No evidence of transcript persistence or provider-history corruption was found in these layout experiments. They are not an exhaustive integrity audit.

## Why the current tests miss important cases

- Several tests assert `row.frame.height == row.fittingSize.height`. Both can agree while the descendant native text view has a different height and origin.
- The bubble fixtures are substantially smaller than the 300–500-line pasted submissions tested here.
- Some resize tests use short code lines that explicitly do not wrap, or widths above the user bubble's effective width cap.
- Most tests check settled geometry; they do not assess semantic reading position or document/scrollbar movement during successive measurements.
- There is already a relevant sidebar-state test, but the initial pass and final failure show that its behavior is not repeatably green in this environment.

## Recommended repair order and acceptance checks

1. **Make live text frame ownership consistent.** Validate descendant text coordinates, not just outer row fitting sizes. Long multiline submissions should retain normal padding at both ends and expose all text while scrolling.
2. **Resolve sidebar visibility reversals.** Check real toolbar/keyboard actions, presentation updates, and small-window animation frames. A toggle should converge on its requested state without a full-width excursion and reversal.
3. **Improve long-message reading anchors.** Preserve a text/line position during width-only reflow where practical, while keeping bottom following and explicit navigation separate.
4. **Improve initial estimates and Markdown transitions.** Account for explicit line breaks and actual user-text width; avoid the worst raw-versus-parsed height cliffs. Do not replace virtualization with eagerly measuring the entire conversation.
5. **Protect scroll intent.** Ensure native layout-driven bounds changes cannot silently disable following, without breaking deliberate scrolling, text selection, accessibility, or rubber-banding.

Small, focused regression additions should cover a long multiline bubble's inner frame, a long wrapped row read mid-message during sidebar reflow, bottom pinning across an actual toggle, and bounded document-height corrections for representative histories. Exact OS-specific diagnostic numbers should not become hard-coded acceptance values.

## Reproducing the retained native probe

The probe is intentionally outside `Tests/ExecTests`, so the normal runner and shipped app do not compile it. It logs measurements rather than declaring known defects to be passing regressions. It briefly opens synthetic native windows and includes two explicitly labeled interventions: resetting one native text frame and forcing legacy TextKit in a separate test.

From `macOS/`, run with Bash:

```bash
mkdir -p .build
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Sources/Exec -name '*.swift' \
        ! -name ExecApp.swift ! -name ChatView.swift ! -name SparkleUpdater.swift | sort
)
swiftc -swift-version 6 -parse-as-library "${sources[@]}" \
    Tests/Diagnostics/TranscriptConsistencyProbe.swift \
    -o .build/transcript-consistency-probe
.build/transcript-consistency-probe
```

This retained probe covers the persistent multiline offset, diagnostic frame repair, normal and selected-text width changes, semantic anchor mapping, composer inset shrink, explicit legacy-mode behavior, historical height corrections, and asynchronous Markdown shrink. The full-view fake-provider sidebar/submission experiments were separate investigation harnesses, not additions to the permanent regression suite.
