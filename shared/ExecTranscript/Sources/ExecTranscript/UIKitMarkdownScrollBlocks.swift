#if canImport(UIKit)
import UIKit

/// Decline predominantly vertical drags so the virtualized transcript, not an
/// inner block, continues to own reading/following gestures.
@MainActor private final class MarkdownHorizontalScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.y) >= abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

@MainActor class MarkdownScrollPart: MarkdownPartView, UIContextMenuInteractionDelegate {
    let scroll: UIScrollView = MarkdownHorizontalScrollView()
    var blockTitle = "Copy Block"
    var blockText = ""
    var message = ""
    override init() {
        super.init()
        addSubview(scroll)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.isDirectionalLockEnabled = true
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = false
        accessibilityContainerType = .semanticGroup
        layer.cornerRadius = 8; layer.cornerCurve = .continuous; clipsToBounds = true
        addInteraction(UIContextMenuInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func fitScroll(width: CGFloat, height: CGFloat, contentWidth: CGFloat, top: CGFloat = 0) {
        let oldOffset = scroll.contentOffset.x
        scroll.frame = CGRect(x: 0, y: top, width: width, height: height)
        scroll.contentSize = CGSize(width: contentWidth, height: height)
        scroll.alwaysBounceHorizontal = contentWidth > width
        let offset = min(max(0, oldOffset), max(0, contentWidth - width))
        if scroll.contentOffset.x != offset || scroll.contentOffset.y != 0 {
            scroll.contentOffset = CGPoint(x: offset, y: 0)
        }
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        // Let TextKit's own long press/selection menu win over the surface menu.
        var hit = hitTest(location, with: nil)
        while let current = hit, current !== self {
            if current is UITextView { return nil }
            hit = current.superview
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: self.blockTitle) { [weak self] _ in UIPasteboard.general.string = self?.blockText },
                UIAction(title: "Copy Message") { [weak self] _ in UIPasteboard.general.string = self?.message }
            ])
        }
    }
}

@MainActor final class MarkdownCodePart: MarkdownScrollPart {
    let text = MarkdownSelectableTextView()
    private let language = UILabel()
    private var naturalWidth: CGFloat = 0
    // Compare configuration against uncolored attributes, never textStorage's syntax colors.
    private var baseContent = NSAttributedString(string: "")
    private var highlightingLanguage: String?
    private var highlighting: CodeHighlighting!
    override init() {
        super.init()
        configure()
        highlighting = CodeHighlighting { [weak self] in self?.applyHighlighting($0) }
    }
    init(highlightingDelay: Duration, worker: @escaping CodeHighlighting.Worker) {
        super.init()
        configure()
        highlighting = CodeHighlighting(delay: highlightingDelay, worker: worker) { [weak self] in
            self?.applyHighlighting($0)
        }
    }
    private func configure() {
        accessibilityIdentifier = "markdown-code-block"
        scroll.accessibilityIdentifier = "markdown-code-scroll"
        text.accessibilityIdentifier = "markdown-code-text"
        backgroundColor = .secondarySystemBackground
        scroll.addSubview(text); addSubview(language)
        language.textColor = .secondaryLabel
        blockTitle = "Copy Code Block"
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func update(_ block: MarkdownBlock, quoted: Bool, message: String, traits: UITraitCollection) {
        guard case .codeBlock(let label) = block.kind else { return }
        let font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        let content = UIKitMarkdownText.inline(block.text, style: .footnote, code: true, quote: quoted, traits: traits)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3; paragraph.lineBreakMode = .byClipping
        paragraph.tabStops = []
        paragraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)]).width
        content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
        if content.length == 0 { text.font = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
        let contentChanged = !baseContent.string.utf8.elementsEqual(content.string.utf8) || !baseContent.isEqual(to: content)
        if contentChanged {
            baseContent = NSAttributedString(attributedString: content)
            text.setContent(content)
            naturalWidth = ceil(content.size().width) + 1
            measuredWidth = -1
        }
        let captionFont = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        if language.text != label || language.font != captionFont { measuredWidth = -1 }
        language.text = label; language.font = captionFont
        blockText = content.string; self.message = message
        text.blockTitle = blockTitle; text.blockText = blockText; text.message = message
        let normalizedLanguage = CodeHighlighter.normalizedLanguage(label)
        if contentChanged || highlightingLanguage != normalizedLanguage {
            highlightingLanguage = normalizedLanguage
            highlighting.update([.init(source: content.string, language: normalizedLanguage,
                                       range: NSRange(location: 0, length: content.length))])
        }
    }
    private func applyHighlighting(_ tokens: [SyntaxToken]) {
        let storage = text.textStorage
        guard storage.length == baseContent.length,
              storage.string.utf8.elementsEqual(baseContent.string.utf8) else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        baseContent.enumerateAttribute(.foregroundColor, in: whole) { color, range, _ in
            if let color { storage.addAttribute(.foregroundColor, value: color, range: range) }
            else { storage.removeAttribute(.foregroundColor, range: range) }
        }
        for token in tokens {
            let range = token.range
            guard range.location >= 0, range.length > 0, range.location <= storage.length,
                  range.length <= storage.length - range.location else { continue }
            storage.addAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.kind), range: range)
        }
        storage.endEditing()
        // No setContent, measurement invalidation, selection, or scroll mutation here.
    }
    override func height(for width: CGFloat) -> CGFloat {
        if measuredWidth != width {
            measuredWidth = width
            let captionHeight: CGFloat = language.text?.isEmpty == false ? ceil(language.font.lineHeight) + 8 : 0
            language.frame = CGRect(x: 12, y: 8, width: max(1, width - 24), height: max(0, captionHeight - 8))
            let contentWidth = max(width, naturalWidth + 24)
            let textHeight = ceil(text.sizeThatFits(CGSize(width: max(1, contentWidth - 24), height: .greatestFiniteMagnitude)).height)
            text.frame = CGRect(x: 12, y: 10, width: max(1, contentWidth - 24), height: textHeight)
            fitScroll(width: width, height: textHeight + 22, contentWidth: contentWidth, top: captionHeight)
            measuredHeight = captionHeight + textHeight + 22
        }
        return measuredHeight
    }
}

@MainActor final class MarkdownTablePart: MarkdownScrollPart {
    private let grid = MarkdownTableGrid()
    private var cells: [MarkdownSelectableTextView] = []
    private var columnCount = 0
    private var naturalWidths: [CGFloat] = []
    private var lineHeight: CGFloat = 0
    override init() {
        super.init()
        accessibilityIdentifier = "markdown-table-block"
        scroll.accessibilityIdentifier = "markdown-table-scroll"
        scroll.addSubview(grid)
        blockTitle = "Copy Table"
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func update(_ block: MarkdownBlock, quoted: Bool, message: String, traits: UITraitCollection) {
        guard case .table(let columns) = block.kind, !columns.isEmpty else { return }
        let count = columns.count * block.children.count
        if columnCount != columns.count {
            cells.forEach { $0.removeFromSuperview() }; cells = []
            measuredWidth = -1
        }
        if cells.count != count { measuredWidth = -1 }
        while cells.count > count { cells.removeLast().removeFromSuperview() }
        while cells.count < count {
            let cell = MarkdownSelectableTextView()
            grid.addSubview(cell); cells.append(cell)
        }
        columnCount = columns.count
        let font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        lineHeight = ceil(font.lineHeight)
        var strings: [String] = []
        var headers: [Bool] = []
        for (rowIndex, row) in block.children.enumerated() {
            let header = row.kind == .tableHeaderRow
            headers.append(header)
            var values: [String] = []
            for column in columns.indices {
                let source = row.children.first { $0.kind == .tableCell(columnIndex: column) }?.text ?? AttributedString()
                let content = UIKitMarkdownText.inline(source, style: .footnote, bold: header, quote: quoted, traits: traits)
                let paragraph = NSMutableParagraphStyle()
                switch columns[column].alignment {
                case .right: paragraph.alignment = .right
                case .center: paragraph.alignment = .center
                default: paragraph.alignment = .left
                }
                paragraph.lineBreakMode = .byClipping
                content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
                let cell = cells[rowIndex * columnCount + column]
                if content.length == 0 { cell.font = font }
                cell.accessibilityIdentifier = "markdown-table-cell-\(rowIndex)-\(column)"
                if cell.setContent(content) { measuredWidth = -1 }
                values.append(content.string)
            }
            strings.append(values.joined(separator: "\t"))
        }
        grid.headers = headers
        blockText = strings.joined(separator: "\n"); self.message = message
        for cell in cells { cell.blockTitle = blockTitle; cell.blockText = blockText; cell.message = message }
        if measuredWidth == -1 {
            naturalWidths = columns.indices.map { column in
                stride(from: column, to: cells.count, by: columnCount).reduce(CGFloat(64)) { width, index in
                    max(width, ceil(cells[index].attributedText.size().width) + 21)
                }
            }
        }
    }
    override func height(for width: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        if measuredWidth != width {
            measuredWidth = width
            let extra = max(0, width - naturalWidths.reduce(0, +)) / CGFloat(columnCount)
            let widths = naturalWidths.map { $0 + extra }
            var rowHeights: [CGFloat] = []
            var y: CGFloat = 0
            for row in 0..<(cells.count / columnCount) {
                var height = lineHeight
                for column in 0..<columnCount {
                    let cell = cells[row * columnCount + column]
                    height = max(height, ceil(cell.sizeThatFits(CGSize(width: widths[column] - 20, height: .greatestFiniteMagnitude)).height))
                }
                height += 16
                var x: CGFloat = 0
                for column in 0..<columnCount {
                    cells[row * columnCount + column].frame = CGRect(x: x + 10, y: y + 8, width: widths[column] - 20, height: height - 16)
                    x += widths[column]
                }
                rowHeights.append(height); y += height
            }
            let contentWidth = widths.reduce(0, +)
            grid.frame = CGRect(x: 0, y: 0, width: contentWidth, height: y)
            grid.columnWidths = widths; grid.rowHeights = rowHeights; grid.setNeedsDisplay()
            // Leave room for the horizontal indicator, outside the final row.
            measuredHeight = y + 8
            fitScroll(width: width, height: measuredHeight, contentWidth: contentWidth)
        }
        return measuredHeight
    }
}

/// One lightweight drawing surface for headers and shared grid edges, rather
/// than a layer/view for every border. Cell contents remain real selectable text.
@MainActor private final class MarkdownTableGrid: UIView {
    var columnWidths: [CGFloat] = []
    var rowHeights: [CGFloat] = []
    var headers: [Bool] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: MarkdownTableGrid, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func draw(_ rect: CGRect) {
        var y: CGFloat = 0
        UIColor.secondarySystemFill.setFill()
        for (index, height) in rowHeights.enumerated() {
            if headers[index] { UIRectFill(CGRect(x: 0, y: y, width: bounds.width, height: height)) }
            y += height
        }
        let edges = UIBezierPath()
        var x: CGFloat = 0
        for width in columnWidths.dropLast() {
            x += width; edges.move(to: CGPoint(x: x, y: 0)); edges.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        y = 0
        for height in rowHeights.dropLast() {
            y += height; edges.move(to: CGPoint(x: 0, y: y)); edges.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        edges.append(UIBezierPath(rect: bounds.insetBy(dx: 0.25, dy: 0.25)))
        UIColor.separator.setStroke(); edges.lineWidth = 0.5; edges.stroke()
    }
}
#endif
