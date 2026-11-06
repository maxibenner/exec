import AppKit
import SwiftUI

/// A full-height diff surface: only horizontal scrolling belongs to this view.
struct DiffCodeView: NSViewRepresentable {
    let text: AttributedString

    func makeNSView(context: Context) -> DiffCodeScrollView { DiffCodeScrollView(text: text) }
    func updateNSView(_ view: DiffCodeScrollView, context: Context) { view.update(text) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffCodeScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.codeSize.width, height: nsView.codeSize.height)
    }
}

@MainActor final class DiffCodeScrollView: HorizontalContentScrollView {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }
    private let content = DocumentView()
    private let code = LinkedText.TextView()
    private var text: AttributedString
    private(set) var codeSize = CGSize.zero

    init(text: AttributedString) {
        self.text = text
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
        documentView = content
        measureCode()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ text: AttributedString) {
        guard self.text != text else { return }
        self.text = text
        measureCode()
    }

    private func measureCode() {
        let styled = NSMutableAttributedString(string: "")
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
            if let color = run.foregroundColor { attributes[.foregroundColor] = NSColor(color) }
            if let color = run.backgroundColor { attributes[.backgroundColor] = NSColor(color) }
            styled.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        code.update(styled)
        if let layout = code.layoutManager, let container = code.textContainer {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            codeSize = CGSize(width: ceil(used.width) + 20, height: ceil(used.height) + 20)
        }
        content.setFrameSize(codeSize)
        code.frame = NSRect(x: 10, y: 10, width: max(0, codeSize.width - 20),
                            height: max(0, codeSize.height - 20))
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { codeSize }
}
