import AppKit
import SwiftUI

@MainActor struct MarkdownSelectionTests {
    func selectsAndCopiesAcrossBlocksWithoutLosingFormatting() throws {
        _ = NSApplication.shared
        let source = """
        # Summary

        First **bold** paragraph with [a link](https://example.com).

        > Quoted paragraph.

        3. First item
        4. Second item with `inline code`

        ---

        ```swift
        let literal = "**not bold**"
        ```

        | Name | Value |
        | --- | ---: |
        | | two |

        Last paragraph.
        """
        let blocks = MarkdownDocument.parse(source)
        let cache = MarkdownCache()
        cache.insert(blocks, for: source)
        let host = NSHostingView(rootView: MarkdownView(source: source, cache: cache).frame(width: 500))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        func textViews(in view: NSView) -> [LinkedText.TextView] {
            if let text = view as? LinkedText.TextView { return [text] }
            return view.subviews.flatMap { textViews(in: $0) }
        }
        let views = textViews(in: host)
        try expect(views.count == 1) // Paragraphs, lists, code and tables share selection.
        let view = views[0]
        try expect(view.isSelectable && !view.isEditable)
        let text = view.attributedString()
        let plain = text.string as NSString
        for fragment in ["Summary", "First bold paragraph", "Quoted paragraph.", "3.\tFirst item",
                         "4.\tSecond item", "let literal = \"**not bold**\"", "two", "Last paragraph."] {
            try expect(plain.range(of: fragment).location != NSNotFound)
        }
        let bold = text.attribute(.font, at: plain.range(of: "bold").location, effectiveRange: nil) as! NSFont
        try expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        try expect(text.attribute(.link, at: plain.range(of: "a link").location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        let code = text.attribute(MarkdownText.codeSnippet, at: plain.range(of: "let literal").location, effectiveRange: nil) as? String
        try expect(code == "let literal = \"**not bold**\"\n")
        let cell = text.attribute(.paragraphStyle, at: plain.range(of: "two").location, effectiveRange: nil) as! NSParagraphStyle
        try expect(cell.textBlocks.last is NSTextTableBlock && cell.alignment == .right)

        let inlineIndex = plain.range(of: "inline code").location
        try expect(text.attribute(MarkdownText.codeSnippet, at: inlineIndex, effectiveRange: nil) as? String == "inline code")
        try expect(text.attribute(.backgroundColor, at: inlineIndex, effectiveRange: nil) as? NSColor == .quaternarySystemFill)
        try verifyTableLayout()

        // Exercise native selection and export without touching the user's clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes(view.writablePasteboardTypes, owner: nil)
        let start = plain.range(of: "First bold").location
        let end = NSMaxRange(plain.range(of: "Last paragraph."))
        let range = NSRange(location: start, length: end - start)
        view.setSelectedRange(range)
        try expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        try expect(pasteboard.string(forType: .string) == plain.substring(with: range))
        view.selectAll(nil)
        try expect(view.selectedRange() == NSRange(location: 0, length: text.length))

        // Streaming and width measurement must leave an existing selection intact.
        view.setSelectedRange(range)
        let appended = MarkdownText.render(MarkdownDocument.parse(source + "\n\nMore output."))
        view.update(appended)
        try expect(view.selectedRange() == range)
        let wide = LinkedText.measuredSize(of: appended, width: 700)
        let narrow = LinkedText.measuredSize(of: appended, width: 150)
        guard narrow.height > wide.height && wide.height > 200 else {
            throw CheckFailure(description: "Markdown wrapping height: wide=\(wide), narrow=\(narrow)")
        }
        try expect(view.selectedRange() == range)
        view.update(NSAttributedString(string: "Short"))
        try expect(NSMaxRange(view.selectedRange()) <= 5)
    }

    private func verifyTableLayout() throws {
        let source = """
        | Hostname | Router | Interface | Site |
        | --- | --- | --- | --- |
        | `port-channel3501.ccr92.lhr01.atlas.cogentco.com` | ccr92 | `port-channel3501` | lhr01 |

        Following paragraph.
        """
        let text = MarkdownText.render(MarkdownDocument.parse(source))
        for width: CGFloat in [320, 500, 820] {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: 10_000))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            try expect(used.maxX <= width + 1)
            let tableRange = (text.string as NSString).range(of: "lhr01\n")
            let paragraphRange = (text.string as NSString).range(of: "Following paragraph.")
            let lastCell = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: tableRange, actualCharacterRange: nil), in: container)
            let following = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: paragraphRange, actualCharacterRange: nil), in: container)
            try expect(following.minY - lastCell.maxY >= 12)
        }
    }
}
