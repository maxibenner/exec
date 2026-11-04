import Foundation

struct MarkdownTests {
    func preservesBlocksAndStreamingCode() throws {
        let blocks = MarkdownDocument.parse("# Heading\n\nA **bold** and `code` paragraph.\n\n3. First\n\n   Continuation\n\n4. Second\n   - Nested\n\n> Quote\n\n```swift\nlet value = \"**literal**\"\n")
        try expect(blocks[0].kind == .header(level: 1))
        try expect(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        try expect(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        let list = blocks[2]
        try expect(list.kind == .orderedList && list.children.count == 2)
        try expect(list.children[0].kind == .listItem(ordinal: 3) && list.children[0].children.count == 2)
        try expect(list.children[1].children.last?.kind == .unorderedList)
        try expect(blocks[3].kind == .blockQuote)
        try expect(blocks[4].kind == .codeBlock(languageHint: "swift"))
        try expect(String(blocks[4].text.characters) == "let value = \"**literal**\"\n")
        try expect(String(MarkdownDocument.parse("## ")[0].text.characters) == "## ")
        let table = MarkdownDocument.parse("| A | B |\n| --- | ---: |\n| | two |")
        try expect(table[0].children.count == 2)
        try expect(table[0].children[1].children.first?.kind == .tableCell(columnIndex: 1))
    }

    func stripsActiveContentAndUnsafeLinks() throws {
        let source = "[safe](https://example.com) [file](file:///tmp/a) [script](javascript:alert) ![image](https://example.com/image)\n\n<script>alert(1)</script>"
        let blocks = MarkdownDocument.parse(source)
        let runs = blocks.flatMap { Array($0.text.runs) }
        try expect(runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com"])
        try expect(runs.allSatisfy { $0.imageURL == nil })
        try expect(blocks.contains { String($0.text.characters).contains("<script>alert(1)</script>") })
        try expect(!MarkdownDocument.allowsLink(URL(string: "x-apple.systempreferences:privacy")!))
        try expect(!MarkdownDocument.allowsLink(URL(string: "relative/path")!))
    }
}
