import AppKit
import SwiftUI

/// TextKit supplies link-only cursor rectangles while retaining normal text selection and wrapping.
struct LinkedText: NSViewRepresentable {
    let text: NSAttributedString
    @Environment(\.openURL) private var openURL

    init(source: AttributedString, fontSize: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular) {
        text = Self.attributed(source, fontSize: fontSize, weight: weight)
    }

    init(text: NSAttributedString) { self.text = text }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TextView {
        // Use the same complete-document engine as measurement. Viewport-driven
        // TextKit 2 can leave an unvisited tail estimated even in a full-height row.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
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
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        context.coordinator.open = { url in openURL(url) }
        view.update(text)
        context.coordinator.measurement.update(text)
    }

    static func attributed(_ source: AttributedString, fontSize: CGFloat = NSFont.systemFontSize,
                           weight: NSFont.Weight = .regular) -> NSAttributedString {
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
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
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
                container.containerSize = NSSize(width: max(1, bounds.width), height: .greatestFiniteMagnitude)
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
            guard attributedString() != text else { return }
            let wasChanging = changingLayout
            changingLayout = true
            defer { changingLayout = wasChanging }
            let selection = selectedRange()
            textStorage?.setAttributedString(text)
            completeLayout()
            // Streaming updates must not clear an in-progress selection.
            let start = min(selection.location, text.length)
            setSelectedRange(NSRange(location: start, length: min(selection.length, text.length - start)))
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
