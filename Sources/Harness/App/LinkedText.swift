import AppKit
import SwiftUI

/// TextKit supplies link-only cursor rectangles while retaining normal text selection and wrapping.
struct LinkedText: NSViewRepresentable {
    let source: AttributedString
    var fontSize: CGFloat = NSFont.systemFontSize
    var weight: NSFont.Weight = .regular
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = { url in openURL(url) }
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
            if intent.contains(.code) { attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link, MarkdownDocument.allowsLink(url) {
                attributes[.link] = url
                attributes[.cursor] = NSCursor.pointingHand
            }
            text.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        if view.attributedString() != text {
            view.textStorage?.setAttributedString(text)
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        Self.measuredSize(of: nsView.attributedString(), width: proposal.width)
    }

    static func measuredSize(of text: NSAttributedString, width: CGFloat?) -> CGSize {
        // SwiftUI probes multiple widths, not necessarily ending with the displayed width.
        // Never resize the live container here: a probe can leave its wrapping narrower
        // than the frame whose height SwiftUI measured, drawing over the next block.
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width ?? 10_000),
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: ((URL) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL, MarkdownDocument.allowsLink(url) { open?(url) }
            return true // Never let AppKit open a URL outside the allowlist.
        }
    }
}
