import XCTest
@testable import ExecTranscript

final class MarkdownBlockLayoutTests: XCTestCase {
    func testInterleavedBlocksKeepReadingOrderAndWholeTable() throws {
        let source = """
        Before.

        ```swift
        let first = 1
        let second = 2
        ```

        Between.

        | Left | Center | Right |
        | :--- | :---: | ---: |
        | one | | 123 |

        After.
        """
        let elements = MarkdownBlockLayout.elements(MarkdownDocument.parse(source))
        XCTAssertEqual(elements.map(\.kind), [.text, .code, .text, .table, .text])
        XCTAssertTrue(String(elements[1].block.text.characters).contains("let first = 1\nlet second = 2"))
        XCTAssertEqual(String(elements.last!.block.text.characters), "After.")
        let table = elements[3].block
        guard case .table(let columns) = table.kind else { return XCTFail("Missing table") }
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns[1].alignment, .center)
        XCTAssertEqual(columns[2].alignment, .right)
        XCTAssertEqual(table.children.count, 2)
        // Foundation omits empty cells; consumers must keep their column slot.
        XCTAssertNil(table.children[1].children.first { $0.kind == .tableCell(columnIndex: 1) })
        let right = try XCTUnwrap(table.children[1].children.first { $0.kind == .tableCell(columnIndex: 2) })
        XCTAssertEqual(String(right.text.characters), "123")
    }

    func testNestedBlocksRetainQuoteIndentAndListMarker() throws {
        let source = """
        3. List intro

           > ```text
           > nested code
           > ```
           >
           > | A | B |
           > | --- | ---: |
           > | one | two |

           List tail.
        """
        let elements = MarkdownBlockLayout.elements(MarkdownDocument.parse(source))
        XCTAssertEqual(elements.first?.marker, "3.\t")
        let code = try XCTUnwrap(elements.first { $0.kind == .code })
        let table = try XCTUnwrap(elements.first { $0.kind == .table })
        XCTAssertEqual(code.indent, 40)
        XCTAssertEqual(table.indent, 40)
        XCTAssertTrue(code.quoted && table.quoted)
        XCTAssertNil(code.marker, "A split must not repeat the list number.")
        XCTAssertEqual(elements.last?.indent, 24)

        // A quote/fence can also be the first content in a list item.
        let fence = MarkdownBlock(id: 4, kind: .codeBlock(languageHint: nil), text: AttributedString("first\nsecond"))
        let quote = MarkdownBlock(id: 3, kind: .blockQuote, children: [fence])
        let item = MarkdownBlock(id: 2, kind: .listItem(ordinal: 7), children: [quote])
        let list = MarkdownBlock(id: 1, kind: .orderedList, children: [item])
        let first = try XCTUnwrap(MarkdownBlockLayout.elements([list]).first)
        XCTAssertEqual(first.kind, .code)
        XCTAssertEqual(first.marker, "7.\t")
        XCTAssertEqual(first.indent, 40)
    }

    func testStreamingFenceStaysOneBlockAndKeepsUnbrokenLines() throws {
        let line = String(repeating: "abcdef", count: 200)
        let partial = "Intro.\n\n```swift\nlet value = 1\n\(line)"
        for source in [partial, partial + "\nprint(value)\n```\n\nTail."] {
            let elements = MarkdownBlockLayout.elements(MarkdownDocument.parse(source))
            let fences = elements.filter { $0.kind == .code }
            XCTAssertEqual(fences.count, 1)
            let code = try XCTUnwrap(fences.first)
            XCTAssertTrue(String(code.block.text.characters).contains("let value = 1\n\(line)"))
        }
    }
}
