import AppKit

@MainActor
struct LinkedTextTests {
    func measuresWrappingAcrossWidthsAndUpdates() throws {
        // Markdown must not reserve an extra empty line after ordinary replies.
        let source = "That confirms the fix is the latest commit. One more call below to check whether the placement stays consistent."
        let rendered = MarkdownText.render(MarkdownDocument.parse(source))
        let plain = LinkedText.attributed(AttributedString(source))
        try expect(rendered.string == source)
        for width: CGFloat in [390, 750] {
            try expect(LinkedText.measuredSize(of: rendered, width: width).height ==
                       LinkedText.measuredSize(of: plain, width: width).height)
        }
        let paragraphs = MarkdownText.render(MarkdownDocument.parse("First paragraph.\n\nSecond paragraph."))
        try expect(paragraphs.string == "First paragraph.\nSecond paragraph.")
        let firstStyle = paragraphs.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        let lastStyle = paragraphs.attribute(.paragraphStyle, at: paragraphs.length - 1, effectiveRange: nil) as! NSParagraphStyle
        try expect(firstStyle.paragraphSpacing == 10 && lastStyle.paragraphSpacing == 0)
        for source in ["```\ncode\n```", "| A | B |\n| --- | --- |\n| one | two |"] {
            let boxed = MarkdownText.render(MarkdownDocument.parse(source))
            try expect(boxed.string.hasSuffix("\n"))
            try expect(LinkedText.measuredSize(of: boxed, width: 750).height > 0)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let text = NSMutableAttributedString(
            string: "I couldn’t retrieve issue #7: the public lookup returned 404, which can happen if the repository is private. The local workspace does contain the project, so I can inspect the relevant code once I have the issue details.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                         .paragraphStyle: paragraph])
        text.addAttribute(.link, value: URL(string: "https://example.com/7")!,
                          range: NSRange(location: 19, length: 8))
        let wide = LinkedText.measuredSize(of: text, width: 750)
        let narrow = LinkedText.measuredSize(of: text, width: 390)
        try expect(narrow.height > wide.height)
        try expect(LinkedText.measuredSize(of: text, width: 750) == wide)

        // Compare the reserved height against actual TextKit layout at each final width.
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 750, height: 1000))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        for width: CGFloat in [750, 390, 600] {
            view.setFrameSize(NSSize(width: width, height: 1000))
            let container = view.textContainer!
            let layout = view.layoutManager!
            layout.ensureLayout(for: container)
            let measured = LinkedText.measuredSize(of: text, width: width)
            try expect(measured.height == ceil(layout.usedRect(for: container).height))
        }

        let measurement = LinkedTextMeasurement()
        measurement.update(text)
        try expect(measurement.size(width: 390) == narrow)
        try expect(measurement.size(width: 750) == wide)
        try expect(measurement.size(width: 390) == narrow)
        // Evict old widths, then verify recomputation still agrees with fresh layout.
        for width in 400...420 { _ = measurement.size(width: CGFloat(width)) }
        try expect(measurement.size(width: 390) == narrow)

        text.append(text.copy() as! NSAttributedString)
        measurement.update(text)
        try expect(measurement.size(width: 390).height > narrow.height)
        text.addAttribute(.font, value: NSFont.systemFont(ofSize: 24), range: NSRange(location: 0, length: text.length))
        measurement.update(text)
        try expect(measurement.size(width: 390) == LinkedText.measuredSize(of: text, width: 390))
    }
}
