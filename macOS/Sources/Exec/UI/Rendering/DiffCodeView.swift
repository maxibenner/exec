import AppKit
import SwiftUI

/// A full-height diff surface: only the code scrolls horizontally, not the gutter.
struct DiffCodeView: NSViewRepresentable {
    let diff: DiffView.RenderedDiff

    func makeNSView(context: Context) -> DiffCodeSurface { DiffCodeSurface(diff: diff) }
    func updateNSView(_ view: DiffCodeSurface, context: Context) { view.update(diff) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffCodeSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.codeSize.width, height: nsView.codeSize.height)
    }
}

@MainActor final class DiffCodeSurface: NSView {
    static let codeInset: CGFloat = 10

    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }
    let scrollView = HorizontalContentScrollView(frame: .zero)
    private let content = DocumentView()
    private let code = LinkedText.TextView()
    private let gutter = GutterView()
    private var diff: DiffView.RenderedDiff?
    private(set) var codeSize = CGSize.zero

    init(diff: DiffView.RenderedDiff) {
        super.init(frame: .zero)
        code.isEditable = false
        code.isSelectable = true
        code.drawsBackground = false
        code.textContainerInset = .zero
        code.textContainer?.lineFragmentPadding = 0
        code.textContainer?.widthTracksTextView = false
        code.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        content.addSubview(code)
        scrollView.documentView = content
        gutter.code = code
        addSubview(gutter)
        addSubview(scrollView)
        update(diff)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ diff: DiffView.RenderedDiff) {
        guard self.diff !== diff else { return }
        self.diff = diff
        code.update(diff.text)
        guard let layout = code.layoutManager, let container = code.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let inset = Self.codeInset
        let codeWidth = ceil(used.width), codeHeight = ceil(used.height)
        let documentSize = CGSize(width: codeWidth + 2 * inset, height: codeHeight + 2 * inset)
        content.setFrameSize(documentSize)
        code.frame = NSRect(x: inset, y: inset, width: codeWidth, height: codeHeight)
        gutter.update(diff)
        codeSize = CGSize(width: documentSize.width + gutter.width, height: documentSize.height)
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { codeSize }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { needsLayout = true }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        let width = min(gutter.width, bounds.width)
        gutter.frame = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: bounds.minX + width, y: bounds.minY,
                                  width: bounds.width - width, height: bounds.height)
    }

    private final class GutterView: NSView {
        private typealias RenderedDiff = DiffView.RenderedDiff
        private let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: RenderedDiff.font, .foregroundColor: NSColor.secondaryLabelColor
        ]
        private let markerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        private let markerWidth: CGFloat = 12
        private let spacing: CGFloat = 8
        private var rows: [Int: RenderedDiff.GutterEntry] = [:]
        private(set) var width: CGFloat = 0
        weak var code: NSTextView?

        override var isFlipped: Bool { true }

        func update(_ diff: DiffView.RenderedDiff) {
            rows = diff.gutter
            let digits = String(repeating: "0", count: diff.numberDigits) as NSString
            let numberWidth = ceil(digits.size(withAttributes: numberAttributes).width)
            width = rows.isEmpty ? 0 : numberWidth + spacing + markerWidth
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let code, let layout = code.layoutManager, let container = code.textContainer else { return }
            let origin = convert(code.textContainerOrigin, from: code)
            let visibleCode = NSRect(x: 0, y: dirtyRect.minY - origin.y,
                                     width: max(1, code.bounds.width), height: dirtyRect.height)
            let visibleGlyphs = layout.glyphRange(forBoundingRect: visibleCode, in: container)
            layout.enumerateLineFragments(forGlyphRange: visibleGlyphs) { rect, _, _, glyphs, _ in
                let index = layout.characterIndexForGlyph(at: glyphs.location)
                guard let row = self.rows[index] else { return }
                let baseline = origin.y + rect.minY + layout.location(forGlyphAt: glyphs.location).y
                self.draw(row, baseline: baseline, layout: layout)
            }
        }

        private func draw(_ row: RenderedDiff.GutterEntry, baseline: CGFloat, layout: NSLayoutManager) {
            let markerLeft = bounds.maxX - markerWidth
            if let number = row.number {
                let label = String(number) as NSString
                label.draw(at: NSPoint(x: bounds.minX, y: baseline - layout.defaultBaselineOffset(for: RenderedDiff.font)),
                           withAttributes: numberAttributes)
            }
            if row.kind == .added || row.kind == .removed {
                let isAddition = row.kind == .added
                let mark = (isAddition ? "+" : "−") as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: markerFont, .foregroundColor: isAddition ? RenderedDiff.addition : RenderedDiff.removal
                ]
                let x = markerLeft + (markerWidth - mark.size(withAttributes: attributes).width) / 2
                mark.draw(at: NSPoint(x: x, y: baseline - layout.defaultBaselineOffset(for: markerFont)),
                          withAttributes: attributes)
            }
        }
    }
}
