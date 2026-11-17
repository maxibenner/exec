import AppKit
import SwiftUI

/// TextKit supplies link-only cursor rectangles while retaining normal text selection and wrapping.
struct LinkedText: NSViewRepresentable {
    let text: NSAttributedString
    @Environment(\.animatesStreamedText) private var animatesStreamedText
    @Environment(\.revealsInitialStreamedText) private var revealsInitialStreamedText
    @Environment(\.openURL) private var openURL

    init(source: AttributedString, fontSize: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular,
         foregroundColor: NSColor = .labelColor) {
        text = Self.attributed(source, fontSize: fontSize, weight: weight, foregroundColor: foregroundColor)
    }

    init(text: NSAttributedString) { self.text = text }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TextView {
        // Use the same complete-document engine as measurement. Viewport-driven
        // TextKit 2 can leave an unvisited tail estimated even in a full-height row.
        let storage = NSTextStorage()
        let layout = StreamedTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = TextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        // SwiftUI owns the frame; native self-sizing would displace text inside
        // its unflipped representable host when the two heights disagree.
        view.isVerticallyResizable = false
        view.textContainer?.heightTracksTextView = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: AppColors.nativeBlue, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        context.coordinator.open = { url in openURL(url) }
        view.animatesStreamedText = animatesStreamedText
        view.revealsInitialStreamedText = revealsInitialStreamedText
        view.update(text)
        context.coordinator.measurement.update(text)
    }

    static func dismantleNSView(_ view: TextView, coordinator: Coordinator) {
        (view.layoutManager as? StreamedTextLayoutManager)?.cancelEntrances()
    }

    static func attributed(_ source: AttributedString, fontSize: CGFloat = NSFont.systemFontSize,
                           weight: NSFont.Weight = .regular,
                           foregroundColor: NSColor = .labelColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
                : NSFont.systemFont(ofSize: fontSize, weight: weight)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: foregroundColor, .paragraphStyle: paragraph
            ]
            if intent.contains(.code) {
                attributes[.backgroundColor] = NSColor.quaternarySystemFill
                attributes[MarkdownText.codeSnippet] = String(source[run.range].characters)
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link, MarkdownDocument.allowsLink(url) {
                attributes[.link] = url
                attributes[.cursor] = NSCursor.pointingHand
            }
            text.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        return text
    }

    final class TextView: NSTextView {
        private var changingLayout = false
        private var hasReceivedText = false
        var animatesStreamedText = false
        var revealsInitialStreamedText = false
        private var wasStreaming = false
        private var wasDetached = false
        private var streamedLayout: StreamedTextLayoutManager? { layoutManager as? StreamedTextLayoutManager }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                streamedLayout?.cancelEntrances()
                hasReceivedText = false
                wasStreaming = false
                wasDetached = true
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let wasChanging = changingLayout
            changingLayout = true
            defer { changingLayout = wasChanging }
            super.setFrameSize(newSize)
            completeLayout()
        }

        override func viewDidEndLiveResize() {
            // AppKit invokes its private frame-sizing path here without going
            // through setFrameSize, including after native sidebar animations.
            let wasChanging = changingLayout
            changingLayout = true
            defer { changingLayout = wasChanging }
            super.viewDidEndLiveResize()
            completeLayout()
        }

        private func completeLayout() {
            guard let container = textContainer, let layout = layoutManager else { return }
            if container.widthTracksTextView {
                // A newly created representable has no assigned width yet.
                // Avoid laying out a large document into a synthetic 1pt column.
                guard bounds.width > 0 else { return }
                container.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
            }
            layout.ensureLayout(for: container)
        }

        override func scrollRangeToVisible(_ range: NSRange) {
            guard !changingLayout else { return }
            super.scrollRangeToVisible(range)
        }

        override func scrollToVisible(_ rect: NSRect) -> Bool {
            // TextKit's frame/selection maintenance is not reader intent. Keep
            // genuine selection, accessibility and keyboard scrolling outside
            // these synchronous layout operations working normally.
            guard !changingLayout else { return false }
            return super.scrollToVisible(rect)
        }

        struct ReadingPosition {
            let character: Int
            let lineOffset: CGFloat
        }

        func readingPosition(at y: CGFloat) -> ReadingPosition? {
            guard let layout = layoutManager, let container = textContainer,
                  y >= 0, y < layout.usedRect(for: container).maxY, layout.numberOfGlyphs > 0 else { return nil }
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
            guard glyph < layout.numberOfGlyphs else { return nil }
            var range = NSRange()
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            return ReadingPosition(character: layout.characterIndexForGlyph(at: range.location), lineOffset: y - line.minY)
        }

        func position(of reading: ReadingPosition) -> CGFloat? {
            guard let layout = layoutManager, reading.character < (textStorage?.length ?? 0) else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: reading.character)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + reading.lineOffset
        }

        // Full-height selectable text is not a scroll surface. Preserve the
        // original event (including phases/momentum) through normal delivery.
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }

        override func autoscroll(with event: NSEvent) -> Bool {
            if let horizontal = enclosingScrollView as? HorizontalContentScrollView {
                return horizontal.autoscrollSelection(with: event)
            }
            return super.autoscroll(with: event)
        }

        func update(_ text: NSAttributedString) {
            // Only the transcript can distinguish a new live row from mounted
            // history. Queue its first entrance before attachment/first drawing.
            let canAnimate = hasReceivedText
                ? (animatesStreamedText || wasStreaming) && window != nil
                : animatesStreamedText && revealsInitialStreamedText && !wasDetached
            hasReceivedText = true
            wasStreaming = animatesStreamedText
            guard attributedString() != text else { return }
            let wasChanging = changingLayout
            changingLayout = true
            defer { changingLayout = wasChanging }
            let selection = selectedRange()
            let edit = RenderedTextEdit(from: string, to: text.string)
            streamedLayout?.prepareEdit(from: string, to: text.string, edit: edit, animatesNewText: canAnimate)
            textStorage?.setAttributedString(text)
            completeLayout()
            // Streaming updates must not clear an in-progress selection.
            let start = min(edit.map(selection.location, afterInsertion: selection.length > 0), text.length)
            let end = min(edit.map(NSMaxRange(selection)), text.length)
            setSelectedRange(NSRange(location: start, length: max(0, end - start)))
            invalidateIntrinsicContentSize()
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event)
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if index < textStorage?.length ?? 0,
               let code = textStorage?.attribute(MarkdownText.codeSnippet, at: index, effectiveRange: nil) as? String {
                let item = NSMenuItem(title: "Copy Code", action: #selector(copyCode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = code
                menu?.insertItem(item, at: 0)
            }
            return menu
        }

        @objc private func copyCode(_ sender: NSMenuItem) {
            guard let code = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
        context.coordinator.measurement.size(width: proposal.width)
    }

    static func measuredSize(of text: NSAttributedString, width: CGFloat?) -> CGSize {
        let measurement = LinkedTextMeasurement()
        measurement.update(text)
        return measurement.size(width: width)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let measurement = LinkedTextMeasurement()
        var open: ((URL) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL, MarkdownDocument.allowsLink(url) { open?(url) }
            return true // Never let AppKit open a URL outside the allowlist.
        }
    }
}

/// Separate from the live text view: sizing probes must never change displayed wrapping.
@MainActor
final class LinkedTextMeasurement {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()
    private var sizes: [CGFloat?: CGSize] = [:]

    init() {
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
    }

    func update(_ text: NSAttributedString) {
        guard !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        sizes.removeAll(keepingCapacity: true)
    }

    func size(width: CGFloat?) -> CGSize {
        if let cached = sizes[width] { return cached }
        container.containerSize = CGSize(width: max(1, width ?? 10_000), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let result = CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
        // Resizing a window must not accumulate an unbounded set of widths.
        if sizes.count >= 8 { sizes.removeAll(keepingCapacity: true) }
        sizes[width] = result
        return result
    }
}

// Scoped to live assistant text; measurement and other selectable text stay static.
private struct AnimatesStreamedTextKey: EnvironmentKey {
    static let defaultValue = false
}
private struct RevealsInitialStreamedTextKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var revealsInitialStreamedText: Bool {
        get { self[RevealsInitialStreamedTextKey.self] }
        set { self[RevealsInitialStreamedTextKey.self] = newValue }
    }
    var animatesStreamedText: Bool {
        get { self[AnimatesStreamedTextKey.self] }
        set { self[AnimatesStreamedTextKey.self] = newValue }
    }
}

/// One contiguous rendered edit, with unchanged prefix/suffix retained. This
/// also recognizes insertion before a code cell's retained paragraph terminator.
struct RenderedTextEdit {
    let oldRange: NSRange
    let newRange: NSRange
    var delta: Int { newRange.length - oldRange.length }

    init(from old: String, to new: String) {
        let before = old as NSString, after = new as NSString
        // Keep appends inside partial graphemes on the append path.
        if after.length >= before.length, after.substring(to: before.length) == old {
            oldRange = NSRange(location: before.length, length: 0)
            newRange = NSRange(location: before.length, length: after.length - before.length)
            return
        }
        var prefix = 0, suffix = 0
        for (a, b) in zip(old, new) {
            guard String(a).utf16.elementsEqual(String(b).utf16) else { break }
            prefix += String(a).utf16.count
        }
        for (a, b) in zip(old.reversed(), new.reversed()) {
            let length = String(a).utf16.count
            guard String(a).utf16.elementsEqual(String(b).utf16),
                  prefix + suffix + length <= min(before.length, after.length) else { break }
            suffix += length
        }
        oldRange = NSRange(location: prefix, length: before.length - prefix - suffix)
        newRange = NSRange(location: prefix, length: after.length - prefix - suffix)
    }

    func map(_ offset: Int, afterInsertion: Bool = false) -> Int {
        // A nonempty selection starts after inserted delimiters, but its end
        // stays before appended text. A caret keeps its existing affinity.
        if afterInsertion, oldRange.length == 0, offset == oldRange.location { return NSMaxRange(newRange) }
        if offset <= oldRange.location { return offset }
        if offset >= NSMaxRange(oldRange) { return offset + delta }
        return newRange.location + min(offset - oldRange.location, newRange.length)
    }
}

/// Timing is independent of model cadence: each arrival gets its own bounded
/// stagger, never a place in a queue behind earlier words.
struct StreamedWordFades {
    static let duration: TimeInterval = 0.36
    static let stagger: TimeInterval = 0.025
    static let maximumDelay: TimeInterval = 0.1

    struct Entrance {
        var range: NSRange
        var started: TimeInterval
        var waitingForPaint = false

        func opacity(at now: TimeInterval) -> CGFloat {
            guard !waitingForPaint else { return 0 }
            return min(1, max(0, (now - started) / StreamedWordFades.duration))
        }
    }

    private(set) var entrances: [Entrance] = []

    mutating func expire(at now: TimeInterval) {
        entrances.removeAll { !$0.waitingForPaint && now - $0.started >= Self.duration }
    }

    mutating func reset() { entrances.removeAll(keepingCapacity: true) }

    mutating func beginDrawing(_ range: NSRange, at now: TimeInterval) {
        for index in entrances.indices where entrances[index].waitingForPaint &&
            NSIntersectionRange(entrances[index].range, range).length > 0 {
            entrances[index].started += now // Pending starts contain only the stagger.
            entrances[index].waitingForPaint = false
        }
    }

    mutating func edit(from old: String, to new: String, edit: RenderedTextEdit,
                       animatesNewText: Bool, at now: TimeInterval) {
        let oldLength = (old as NSString).length
        // Remap surviving glyphs rather than cancelling all fades when Markdown
        // removes delimiters or changes a block. Never replay unchanged history.
        if edit.oldRange.location != oldLength || edit.oldRange.length != 0 {
            entrances = entrances.flatMap { entrance -> [Entrance] in
                let prefix = NSIntersectionRange(entrance.range, NSRange(location: 0, length: edit.oldRange.location))
                let suffix = NSIntersectionRange(entrance.range,
                    NSRange(location: NSMaxRange(edit.oldRange), length: oldLength - NSMaxRange(edit.oldRange)))
                var retained: [Entrance] = []
                if prefix.length > 0 { var part = entrance; part.range = prefix; retained.append(part) }
                if suffix.length > 0 {
                    var part = entrance
                    part.range = NSRange(location: suffix.location + edit.delta, length: suffix.length)
                    retained.append(part)
                }
                return retained
            }
        }
        if animatesNewText, edit.newRange.length > 0,
           old.isEmpty || edit.newRange.location > 0 || NSMaxRange(edit.oldRange) < oldLength {
            append((new as NSString).substring(to: NSMaxRange(edit.newRange)),
                   after: edit.newRange.location, at: now, waitingForPaint: true)
        }
        entrances.sort { $0.range.location < $1.range.location }
    }

    mutating func append(_ string: String, after oldLength: Int, at now: TimeInterval,
                         waitingForPaint: Bool = false) {
        expire(at: now)
        let text = string as NSString
        guard oldLength < text.length else { return }
        // Re-tokenize only the trailing whitespace-delimited segment and the
        // addition. It may complete a word, combining sequence or ZWJ emoji.
        let separator = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                              range: NSRange(location: 0, length: oldLength))
        // Even a space can acquire a combining mark; never start inside that
        // composed sequence when scanning the new suffix.
        let start = separator.location == NSNotFound ? 0
            : NSMaxRange(text.rangeOfComposedCharacterSequences(for: separator))
        let suffix = NSRange(location: start, length: text.length - start)
        var slot = 0
        for range in Self.wordRanges(in: text, range: suffix) {
            guard NSMaxRange(range) > oldLength else { continue }
            if range.location < oldLength {
                // An in-flight partial word keeps its original timing. After
                // it finishes, only the newly arrived suffix gets a fresh fade.
                if let index = entrances.lastIndex(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                    entrances[index].range.length = NSMaxRange(range) - entrances[index].range.location
                    continue
                }
            }
            // Reuse five slots within this burst rather than making its tail
            // one whole-chunk fade or building an arbitrarily long backlog.
            let slotCount = Int(Self.maximumDelay / Self.stagger) + 1
            let delay = Double(slot % slotCount) * Self.stagger
            let addition = text.rangeOfComposedCharacterSequences(for:
                NSRange(location: max(oldLength, range.location), length: NSMaxRange(range) - max(oldLength, range.location)))
            entrances.append(Entrance(range: addition, started: (waitingForPaint ? 0 : now) + delay,
                                      waitingForPaint: waitingForPaint))
            slot += 1
        }
    }

    private static func wordRanges(in text: NSString, range suffix: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        func addSymbols(_ range: NSRange) {
            text.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { substring, range, _, _ in
                if let substring, !substring.allSatisfy(\.isWhitespace) { ranges.append(range) }
            }
        }
        // Foundation word boundaries cover languages without spaces. Fill the
        // gaps with whole graphemes so emoji/punctuation also enter safely.
        var cursor = suffix.location
        text.enumerateSubstrings(in: suffix, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            addSymbols(NSRange(location: cursor, length: range.location - cursor))
            ranges.append(range)
            cursor = NSMaxRange(range)
        }
        addSymbols(NSRange(location: cursor, length: NSMaxRange(suffix) - cursor))
        return ranges
    }
}

/// Draw only new words with partial-opacity entrances. TextKit still owns the
/// complete storage, selection, accessibility, glyph shaping and geometry.
final class StreamedTextLayoutManager: NSLayoutManager {
    private(set) var fades = StreamedWordFades()
    private var timer: Timer?
    var hasAnimationClock: Bool { timer != nil }

    func prepareEdit(from old: String, to new: String, edit: RenderedTextEdit, animatesNewText: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cancelEntrances()
            return
        }
        invalidateEntrances()
        fades.edit(from: old, to: new, edit: edit, animatesNewText: animatesNewText,
                   at: ProcessInfo.processInfo.systemUptime)
    }

    private func startClockIfNeeded() {
        guard timer == nil, fades.entrances.contains(where: { !$0.waitingForPaint }) else { return }
        let clock = Timer(timeInterval: 1.0 / 60, target: self,
                          selector: #selector(advanceEntrance), userInfo: nil, repeats: true)
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    func cancelEntrances() {
        invalidateEntrances()
        fades.reset()
        timer?.invalidate()
        timer = nil
    }

    private func invalidateEntrances() {
        // No attributed-string rebuilding or full-document allocation per tick.
        // Include finishing ranges so their last frame is fully opaque.
        for entrance in fades.entrances {
            invalidateDisplay(forCharacterRange: entrance.range)
        }
    }

    @MainActor @objc private func advanceEntrance() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cancelEntrances()
            return
        }
        invalidateEntrances()
        fades.expire(at: ProcessInfo.processInfo.systemUptime)
        if !fades.entrances.contains(where: { !$0.waitingForPaint }) { timer?.invalidate(); timer = nil }
    }

    deinit { timer?.invalidate() }

    override func drawGlyphs(forGlyphRange range: NSRange, at origin: NSPoint) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { cancelEntrances() }
        guard !fades.entrances.isEmpty else {
            super.drawGlyphs(forGlyphRange: range, at: origin)
            return
        }
        var cursor = range.location
        let now = ProcessInfo.processInfo.systemUptime
        fades.beginDrawing(characterRange(forGlyphRange: range, actualGlyphRange: nil), at: now)
        startClockIfNeeded()
        for entrance in fades.entrances {
            let fresh = NSIntersectionRange(NSRange(location: cursor, length: NSMaxRange(range) - cursor),
                glyphRange(forCharacterRange: entrance.range, actualCharacterRange: nil))
            guard fresh.length > 0 else { continue }
            if fresh.location > cursor {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: fresh.location - cursor), at: origin)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(entrance.opacity(at: now))
            super.drawGlyphs(forGlyphRange: fresh, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            cursor = NSMaxRange(fresh)
        }
        if cursor < NSMaxRange(range) {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(range) - cursor), at: origin)
        }
    }
}
