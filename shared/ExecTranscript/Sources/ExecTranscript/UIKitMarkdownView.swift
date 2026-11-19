#if canImport(UIKit)
import UIKit

/// One self-sized message body. Ordinary paragraphs share a TextKit view;
/// only tables and fences introduce horizontal scrolling. No nested vertical
/// scroller, asynchronous sizing, or per-line code views.
@MainActor public final class UIKitMarkdownView: UIView {
    private struct Key: Hashable { let id: Int; let kind: MarkdownBlockLayout.Kind }
    private struct Entry {
        let key: Key
        let view: MarkdownPartView
        let indent: CGFloat
        let marker: UILabel?
    }
    private var entries: [Entry] = []
    private var blocks: [MarkdownBlock] = []
    private var source = ""
    private var layoutWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: UIKitMarkdownView, _: UITraitCollection) in
            view.update(view.blocks, source: view.source, width: view.layoutWidth)
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    public func update(_ blocks: [MarkdownBlock], source: String, width: CGFloat) {
        self.blocks = blocks; self.source = source
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        var next: [Entry] = []
        var text: [MarkdownBlockLayout.Element] = []
        func append(_ elements: [MarkdownBlockLayout.Element]) {
            guard let first = elements.first else { return }
            let key = Key(id: first.block.id, kind: first.kind)
            let part: MarkdownPartView
            switch first.kind {
            case .text:
                let view = previous[key]?.view as? MarkdownTextPart ?? MarkdownTextPart()
                view.update(UIKitMarkdownText.render(elements, width: width, traits: traitCollection), message: source)
                part = view
            case .code:
                let view = previous[key]?.view as? MarkdownCodePart ?? MarkdownCodePart()
                view.update(first.block, quoted: first.quoted, message: source, traits: traitCollection)
                part = view
            case .table:
                let view = previous[key]?.view as? MarkdownTablePart ?? MarkdownTablePart()
                view.update(first.block, quoted: first.quoted, message: source, traits: traitCollection)
                part = view
            }
            let marker: UILabel?
            if first.kind != .text, let prefix = first.marker {
                let label = previous[key]?.marker ?? UILabel()
                label.text = prefix.replacingOccurrences(of: "\t", with: "")
                label.font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
                label.textColor = first.quoted ? .secondaryLabel : .label
                label.isAccessibilityElement = false
                marker = label
            } else { marker = nil }
            next.append(Entry(key: key, view: part, indent: first.kind == .text ? 0 : CGFloat(first.indent), marker: marker))
        }
        for element in MarkdownBlockLayout.elements(blocks) {
            if element.kind == .text { text.append(element) }
            else {
                append(text); text.removeAll(keepingCapacity: true)
                append([element])
            }
        }
        append(text)
        let retained = Dictionary(uniqueKeysWithValues: next.map { ($0.key, $0) })
        for old in entries {
            if retained[old.key] == nil { old.view.removeFromSuperview() }
            if let marker = old.marker, retained[old.key]?.marker !== marker { marker.removeFromSuperview() }
        }
        entries = next
        for entry in entries {
            if entry.view.superview !== self { addSubview(entry.view) }
            if let marker = entry.marker, marker.superview !== self { addSubview(marker) }
        }
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Copy Message") { [weak self] _ in
            guard let self else { return false }
            UIPasteboard.general.string = self.source
            return true
        }]
        setLayoutWidth(width)
    }

    /// Width changes remeasure existing views, without reparsing or replacing
    /// their text/selection. Heights are ready before the table's anchor pass.
    public func setLayoutWidth(_ width: CGFloat) {
        layoutWidth = max(1, width)
        var y: CGFloat = 0
        for entry in entries {
            if y > 0 { y += 10 }
            let indent = min(entry.indent, max(0, layoutWidth - 100))
            let available = layoutWidth - indent
            let height = entry.view.height(for: available)
            entry.view.frame = CGRect(x: indent, y: y, width: available, height: height)
            entry.marker?.frame = CGRect(x: max(0, indent - 24), y: y + 8, width: 24, height: entry.marker?.font.lineHeight ?? 0)
            y += height
        }
        if contentHeight != y { contentHeight = y; invalidateIntrinsicContentSize() }
    }
    public func reset() {
        entries.forEach { $0.view.removeFromSuperview(); $0.marker?.removeFromSuperview() }
        entries = []; blocks = []; source = ""; contentHeight = 0
        accessibilityCustomActions = nil
        invalidateIntrinsicContentSize()
    }
    public override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: contentHeight) }
    public override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, abs(bounds.width - layoutWidth) > 0.5 { setLayoutWidth(bounds.width) }
    }
}

@MainActor class MarkdownPartView: UIView {
    var measuredWidth: CGFloat = -1
    var measuredHeight: CGFloat = 0
    init() { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func height(for width: CGFloat) -> CGFloat { preconditionFailure("Implement native block measurement") }
}

@MainActor final class MarkdownTextPart: MarkdownPartView {
    let text = MarkdownSelectableTextView()
    override init() { super.init(); addSubview(text) }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func update(_ content: NSAttributedString, message: String) {
        if text.setContent(content) { measuredWidth = -1 }
        text.message = message
    }
    override func height(for width: CGFloat) -> CGFloat {
        if measuredWidth != width {
            measuredWidth = width
            measuredHeight = ceil(text.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
        text.frame = CGRect(x: 0, y: 0, width: width, height: measuredHeight)
        return measuredHeight
    }
}

/// Native selection/link handling remains available inside each text region.
/// Block/message copy actions cover the boundaries between separate regions.
@MainActor final class MarkdownSelectableTextView: UITextView, UITextViewDelegate {
    var blockTitle: String?
    var blockText = ""
    var message = ""
    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false; isSelectable = true; isScrollEnabled = false
        backgroundColor = .clear; delegate = self
        textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        dataDetectorTypes = []
        adjustsFontForContentSizeCategory = false // The owner rebuilds attributed fonts on trait changes.
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    @discardableResult func setContent(_ content: NSAttributedString) -> Bool {
        guard attributedText?.isEqual(to: content) != true else { return false }
        let selection = selectedRange
        attributedText = content
        selectedRange = NSRange(location: min(selection.location, content.length), length: min(selection.length, max(0, content.length - selection.location)))
        return true
    }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        MarkdownDocument.allowsLink(URL)
    }
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions = suggestedActions
        if let blockTitle {
            actions.append(UIAction(title: blockTitle) { [weak self] _ in UIPasteboard.general.string = self?.blockText })
        }
        actions.append(UIAction(title: "Copy Message") { [weak self] _ in UIPasteboard.general.string = self?.message })
        return UIMenu(children: actions)
    }
}
#endif
