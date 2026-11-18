import AppKit

@MainActor struct StreamingMarkdownTests {
    func projectsOnlyUnfinishedTails() throws {
        let cache = MarkdownCache()
        func streamed(_ source: String) -> NSAttributedString { cache.initialText(for: source, isStreaming: true) }
        func canonical(_ source: String) -> NSAttributedString { MarkdownText.render(MarkdownDocument.parse(source)) }
        for (open, closed) in [
            ("Stable paragraph.\n\nUse `some_code", "Stable paragraph.\n\nUse `some_code`"),
            ("Use ``a ` literal", "Use ``a ` literal``"),
            ("Use `first\nsecond", "Use `first\nsecond`"),
            ("A **bold tail", "A **bold tail**"),
            ("A *gentle tail", "A *gentle tail*"),
            ("A __bold tail", "A __bold tail__"),
            ("A ~~removed tail", "A ~~removed tail~~"),
            ("A **bold `code", "A **bold `code`**"),
            ("```swift\nlet value = 1", "```swift\nlet value = 1\n```"),
            ("~~~text\nLiteral ** and ` code", "~~~text\nLiteral ** and ` code\n~~~")
        ] {
            let before = streamed(open), after = canonical(closed)
            guard before.string == after.string else {
                throw CheckFailure(description: "Projection mismatch for \(open.debugDescription): \(before.string.debugDescription) vs \(after.string.debugDescription)")
            }
            for index in 0..<before.length {
                try expect((before.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ==
                           (after.attribute(.font, at: index, effectiveRange: nil) as? NSFont))
            }
            for width: CGFloat in [180, 500] {
                try expect(LinkedText.measuredSize(of: before, width: width) == LinkedText.measuredSize(of: after, width: width))
            }
            // A final unclosed source must NOT reuse its provisional cache entry.
            let final = cache.initialText(for: open), expected = canonical(open)
            // NSTextTable/Block instances have identity, not value equality.
            try expect(final.string == expected.string)
            for index in 0..<final.length {
                try expect((final.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ==
                           (expected.attribute(.font, at: index, effectiveRange: nil) as? NSFont))
            }
            try expect(LinkedText.measuredSize(of: final, width: 180) == LinkedText.measuredSize(of: expected, width: 180))
        }
        for opening in ["```swift", "```swift\n", "~~~text\n"] {
            let blocks = StreamingMarkdown.parse(opening)
            try expect(blocks.count == 1)
            guard case .codeBlock = blocks[0].kind else { throw CheckFailure(description: "Opening fence is not code") }
            let rendered = streamed(opening)
            let style = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
            try expect(!style.textBlocks.isEmpty && !rendered.string.contains("```"))
        }
        for literal in [#"Escaped \`literal"#, #"Escaped \**literal"#, "word_with_underscores", "2 * 3 = 6",
                        "Literal ``a ` b``", "`done` then plain", "Unfinished `prior\n\nNew paragraph",
                        "```text\n` ** literal\n```", "[safe](https://example.com/a_b)"] {
            guard streamed(literal).string == canonical(literal).string else {
                throw CheckFailure(description: "Changed literal \(literal.debugDescription): \(streamed(literal).string.debugDescription)")
            }
        }
        try expect(streamed("Use `").string == canonical("Use ").string)
        try expect(streamed("A **").string == canonical("A ").string)
        let boldSpace = streamed("A **bold ")
        try expect(boldSpace.string == canonical("A **bold** ").string)
        // Provisional styling and final canonical correction retain native
        // selection, including when a literal delimiter returns on completion.
        let view = LinkedText.TextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let open = "Stable paragraph.\n\nUse `some_code"
        view.update(streamed(open))
        let selection = (view.string as NSString).range(of: "some_code")
        view.setSelectedRange(selection)
        view.update(streamed(open + "`"))
        try expect(view.selectedRange() == selection)
        view.update(cache.initialText(for: open + "`"))
        try expect(view.selectedRange() == selection)
        view.update(cache.initialText(for: open))
        try expect((view.string as NSString).substring(with: view.selectedRange()) == "some_code")
        let codeBefore = streamed("```swift\nlet val"), codeAfter = streamed("```swift\nlet value = 1")
        let edit = RenderedTextEdit(from: codeBefore.string, to: codeAfter.string)
        try expect(edit.oldRange == NSRange(location: codeBefore.length - 1, length: 0))
        try expect(NSMaxRange(edit.newRange) == codeAfter.length - 1)

        let safe = streamed("[safe](https://example.com) [bad](javascript:alert) and `code")
        var links: [URL] = []
        safe.enumerateAttribute(.link, in: NSRange(location: 0, length: safe.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        try expect(links.map(\.absoluteString) == ["https://example.com"])
    }
}
