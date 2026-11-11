# Transcript consistency repairs

This implements the repairs motivated by `transcript-consistency.md` and the fork/navigation follow-up. The original investigation remains a record of the old implementation, not a description of the current renderer.

## Changes

- **One owner of text frames.** SwiftUI owns the full-height selectable text frame. `LinkedText` explicitly constructs a TextKit 1 document, matching the independent measurement engine, disables vertical self-resizing, and completes layout at the assigned width. Cold rows no longer depend on progressively visiting TextKit 2 viewport fragments. Links, selection, code-copy menus and accessibility remain native.
- **Layout is not scroll intent.** TextKit's synchronous frame/content maintenance cannot scroll its ancestors. Native sidebar animation completion also calls a private sizing path through `viewDidEndLiveResize`; the same protection covers that callback. Selection/accessibility scroll requests outside these callbacks still reach the transcript, and wheel/momentum events retain their normal routing.
- **One owner of sidebar visibility.** The native split controller owns collapse state. The representable applies initial visibility once per controller and handles reveal requests once per request. There is no external SwiftUI column-visibility binding to replay a stale value after native toolbar/keyboard toggles.
- **Reading-character anchors.** During width-only reflow, ordinary user/assistant text preserves a character and its line-relative offset. The original character survives the whole animation rather than repeatedly rounding to a new line start. Explicit navigation and follow-latest keep their separate policies. Tool cards, gaps and other non-text regions retain pixel anchoring; changing message content invalidates the semantic anchor.
- **Better estimates, not eager history layout.** User estimates count explicit newlines and graphemes, use the bubble's effective text width, and have no 100-line cap. Assistant estimates approximate soft breaks, paragraphs and common block starts without parsing offscreen rows. Existing measured offscreen geometry remains available across width changes. Estimates are still approximate, particularly for tables, images and disclosure content.
- **Measure rendered Markdown first.** Mounted rows render/cache Markdown before their first measurement instead of showing literal source and later replacing it asynchronously. This eliminates the raw-soft-break height cliff and stale asynchronous render transitions. Parsing now runs synchronously for mounted content; the existing parser's size/structure limits and bounded cache still apply. No parsing or native layout of the entire offscreen history was added. Very large individual mounted responses still carry synchronous parsing/layout cost.

## Regression coverage

Run from `macOS/`:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Focused additions cover:

- 300–500-line submissions, Unicode, unbroken tokens, long paragraph-rich Markdown and code; native descendant frames, normal bubble padding and complete laid-out extents at multiple widths.
- A mid-message character through repeated narrow/wide reflows with selection retained, followed by explicit navigation and return to latest.
- Representative estimate error bounds, bounded document corrections while visiting a 100-row multiline history, and bounded mounting/measurement counts.
- Rendered Markdown on the first layout, without a subsequent document-height change for the 300-soft-break fixture.
- Repeated native sidebar toolbar actions and the Command-S handler at 720/980-point widths, presentation changes during animations, monotonic pane widths, and exact bottom pinning after settling.
- Actual forks of 120 alternating paragraph-rich messages through `SessionWindows` and the real `ConversationView`/composer. Checks include independent presentation/content, a laid-out visible final tail before any exploration, incremental traversal equivalence, and three direct previous-message jumps at two widths.

The regression fixtures use isolated stores/preferences and fake providers, not the user's sessions, Keychain or live inference.

## Verification and limits

The implementation worktree passed **241 checks** and the signed application build, including strict signature verification with the configured stable signing identity.

A separate copy of the retained fork integration probe was run against the repaired source, with additional assertions for native text extents and visible cold tails. All eight fixtures (soft breaks, paragraph-rich text, code, mixed collapsed tools; two window widths) completed with intact copied messages and independent presentation. The original probe/worktree was left unchanged. The paragraph-rich cold final row had complete text layout immediately; it did not require traversal to fill its allocated frame.

Screenshot capture was attempted but unavailable because Screen Recording permission was not available to the capture tool. No new screenshot-based visual verification is claimed. The user's exact affected transcripts and exact reported Command-Up screenshot sequence, physical trackpad momentum/rubber-banding, scrollbar dragging, VoiceOver interaction and other supported macOS versions remain manual checks. Native/synthetic success is not a claim about live inference or an exhaustive accessibility audit.
