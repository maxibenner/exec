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
        let initial = cache.initialText(for: source)
        try expect(initial === cache.initialText(for: source) && initial === cache.renderedText(for: source))
        try expect(initial.string == MarkdownText.render(blocks).string)
        let rendered = cache.insert(blocks, for: source)
        try expect(rendered === cache.renderedText(for: source) && rendered === cache.initialText(for: source))
        try expect(rendered === cache.insert(blocks, for: source))
        let streamingSource = source + "\n\nMore output."
        try expect(cache.renderedText(for: streamingSource) == nil)
        let streamed = cache.insert(MarkdownDocument.parse(streamingSource), for: streamingSource)
        try expect(streamed !== rendered && rendered === cache.renderedText(for: source))
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
        A paragraph before the table.

        | Field | Value |
        | --- | --- |
        | Building ID | `2211–1` |
        | City | **Stamford** |

        Text after the two-column table.

        | Hostname | Router | Interface | Site |
        | --- | --- | --- | --- |
        | `port-channel3501.ccr92.lhr01.atlas.cogentco.com` | ccr92 | `port-channel3501` | lhr01 |

        Following paragraph.

        ```text
        Origin → Stamford → New York → Slough/LHR
        ```

        Text after code.
        """
        let text = MarkdownText.render(MarkdownDocument.parse(source))
        var cells: [NSTextTableBlock] = []
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, let cell = style.textBlocks.last as? NSTextTableBlock,
               cell.table.numberOfColumns > 1 {
                cells.append(cell)
            }
        }
        for cell in cells {
            let right = cells.first { $0.table === cell.table && $0.startingRow == cell.startingRow && $0.startingColumn == cell.startingColumn + 1 }
            let below = cells.first { $0.table === cell.table && $0.startingColumn == cell.startingColumn && $0.startingRow == cell.startingRow + 1 }
            // Each divider, including outer edges, has exactly one half-point stroke.
            try expect(cell.width(for: .border, edge: .maxX) + (right?.width(for: .border, edge: .minX) ?? 0) == 0.5)
            try expect(cell.width(for: .border, edge: .maxY) + (below?.width(for: .border, edge: .minY) ?? 0) == 0.5)
            if cell.startingRow == 0 { try expect(cell.width(for: .border, edge: .minY) == 0.5) }
            if cell.startingColumn == 0 { try expect(cell.width(for: .border, edge: .minX) == 0.5) }
        }
        for width: CGFloat in [320, 500, 820] {
            let host = NSHostingView(rootView: LinkedText(text: text).frame(width: width))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            func findText(in view: NSView) -> LinkedText.TextView? {
                if let text = view as? LinkedText.TextView { return text }
                return view.subviews.lazy.compactMap { findText(in: $0) }.first
            }
            let view = findText(in: host)!
            let layout = view.layoutManager!
            let container = view.textContainer!
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            try expect(used.maxX <= width)
            // Check the entire last row, not the short text in its final cell.
            // The old assertion passed while the tallest cell touched the next paragraph.
            let plain = text.string as NSString
            for (start, end, after) in [
                ("City\n", "Stamford\n", "Text after the two-column table."),
                ("port-channel3501.ccr92", "lhr01\n", "Following paragraph."),
                ("Origin →", "Origin → Stamford → New York → Slough/LHR\n", "Text after code.")
            ] {
                let startRange = plain.range(of: start)
                let endRange = plain.range(of: end)
                let rowRange = NSRange(location: startRange.location, length: NSMaxRange(endRange) - startRange.location)
                var row = NSRect.null
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: rowRange, actualCharacterRange: nil)) { _, used, _, _, _ in
                    row = row.union(used)
                }
                let following = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: plain.range(of: after), actualCharacterRange: nil), in: container)
                let style = text.attribute(.paragraphStyle, at: endRange.location, effectiveRange: nil) as! NSParagraphStyle
                let cell = style.textBlocks.last as! NSTextTableBlock
                let glyphIndex = layout.glyphIndexForCharacter(at: endRange.location)
                let bounds = layout.boundsRect(for: cell, at: glyphIndex, effectiveRange: nil)
                try expect(!bounds.isEmpty && bounds.maxX <= view.bounds.width)
                let bottomBorder = row.maxY + cell.width(for: .padding, edge: .maxY)
                    + ceil(cell.width(for: .border, edge: .maxY))
                guard following.minY - bottomBorder >= 12 else {
                    throw CheckFailure(description: "Table gap at \(width) for \(start): row=\(row), bounds=\(bounds), following=\(following)")
                }
            }
            try expect(ceil(used.height) <= view.bounds.height)
        }
    }
}
