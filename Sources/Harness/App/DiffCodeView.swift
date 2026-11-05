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

private struct DiffCodeContent: View {
    let text: AttributedString

    var body: some View {
        Text(text).font(.system(.body, design: .monospaced))
            .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(10)
    }
}

@MainActor final class DiffCodeScrollView: NSScrollView {
    private let code: NSHostingView<DiffCodeContent>
    private var text: AttributedString
    private(set) var codeSize = CGSize.zero

    init(text: AttributedString) {
        self.text = text
        code = NSHostingView(rootView: DiffCodeContent(text: text))
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        verticalScrollElasticity = .none
        documentView = code
        measureCode()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ text: AttributedString) {
        guard self.text != text else { return }
        self.text = text
        code.rootView = DiffCodeContent(text: text)
        measureCode()
    }

    private func measureCode() {
        codeSize = code.fittingSize
        code.setFrameSize(codeSize)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { codeSize }

    override func scrollWheel(with event: NSEvent) {
        // SwiftUI's horizontal ScrollView can swallow vertical wheel/trackpad
        // events. Route vertical gestures directly to the enclosing transcript.
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    scroll.scrollWheel(with: event)
                    return
                }
                ancestor = view.superview
            }
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
