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
            streamedLayout?.prepareEdit(oldLength: (string as NSString).length, edit: edit, animatesNewText: canAnimate)
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

/// Each arrival starts on its first paint, split by actual TextKit visual lines.
/// Lines fade uniformly, with a bounded ordered delay, never a serial queue.
struct StreamedLineFades {
    static let duration: TimeInterval = 0.36
    static let stagger: TimeInterval = 0.025
    static let maximumDelay: TimeInterval = 0.1

    struct Entrance {
        var range: NSRange
        let batch: Int
        var started: TimeInterval = 0
        var waitingForPaint = true

        func opacity(at now: TimeInterval) -> CGFloat {
            guard !waitingForPaint else { return 0 }
            return min(1, max(0, (now - started) / StreamedLineFades.duration))
        }
    }

    private(set) var entrances: [Entrance] = []
    private var nextBatch = 0

    mutating func expire(at now: TimeInterval) {
        entrances.removeAll { !$0.waitingForPaint && now - $0.started >= Self.duration }
    }

    mutating func reset() { entrances.removeAll(keepingCapacity: true) }

    mutating func beginDrawing(_ range: NSRange, at now: TimeInterval,
                               lines: (NSRange) -> [NSRange]) {
        let batches = Set(entrances.filter {
            $0.waitingForPaint && NSIntersectionRange($0.range, range).length > 0
        }.map(\.batch))
        // Start the whole batch on one epoch, even if AppKit draws separate
        // dirty ranges. Later drawing must not reschedule its remaining lines.
        for batch in batches {
            var index = 0
            entrances = entrances.flatMap { entrance -> [Entrance] in
                guard entrance.batch == batch else { return [entrance] }
                return lines(entrance.range).map { range in
                    defer { index += 1 }
                    return Entrance(range: range, batch: batch,
                        started: now + min(Double(index) * Self.stagger, Self.maximumDelay),
                        waitingForPaint: false)
                }
            }
        }
    }

    mutating func edit(oldLength: Int, edit: RenderedTextEdit,
                       animatesNewText: Bool, at now: TimeInterval) {
        expire(at: now)
        // Retain prefix/suffix timing through rendered Markdown edits. A new
        // continuation gets its own fade, not the nearly finished previous one.
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
           oldLength == 0 || edit.newRange.location > 0 || NSMaxRange(edit.oldRange) < oldLength {
            entrances.append(Entrance(range: edit.newRange, batch: nextBatch))
            nextBatch += 1
        }
        entrances.sort { $0.range.location < $1.range.location }
    }
}

/// Opacity affects only fresh glyphs. TextKit immediately owns the complete
/// storage, selection, accessibility, shaping and geometry; no reveal mask.
final class StreamedTextLayoutManager: NSLayoutManager {
    private(set) var fades = StreamedLineFades()
    private var timer: Timer?
    var hasAnimationClock: Bool { timer != nil }

    func prepareEdit(oldLength: Int, edit: RenderedTextEdit, animatesNewText: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cancelEntrances()
            return
        }
        invalidateEntrances()
        fades.edit(oldLength: oldLength, edit: edit, animatesNewText: animatesNewText,
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
        fades.beginDrawing(characterRange(forGlyphRange: range, actualGlyphRange: nil), at: now) { fresh in
            var lines: [NSRange] = []
            let glyphs = self.glyphRange(forCharacterRange: fresh, actualCharacterRange: nil)
            self.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
                let characters = self.characterRange(forGlyphRange: line, actualGlyphRange: nil)
                let portion = NSIntersectionRange(fresh, characters)
                if portion.length > 0 { lines.append(portion) }
            }
            return lines
        }
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
