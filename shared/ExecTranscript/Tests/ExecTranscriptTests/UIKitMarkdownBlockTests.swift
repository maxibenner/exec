#if canImport(UIKit)
import XCTest
import UIKit
@testable import ExecTranscript

@MainActor final class UIKitMarkdownBlockTests: XCTestCase {
    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    func testNativeBlocksKeepFontAlignmentSelectionAndOffsetAcrossUpdates() throws {
        let line = String(repeating: "unbroken_", count: 80)
        let source = """
        Before **bold** and `inline`.

        ```swift
        let first = 1
        \(line)
        let last = 2
        ```

        Between.

        | Left | Center | Right |
        | :--- | :---: | ---: |
        | \(line) | Middle | 123 |
        | short | | 4 |

        After.
        """
        let view = UIKitMarkdownView()
        view.traitOverrides.preferredContentSizeCategory = .large
        view.update(MarkdownDocument.parse(source), source: source, width: 280)
        let code = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownCodePart }.first)
        let table = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTablePart }.first)
        XCTAssertEqual(view.subviews.compactMap { $0 as? MarkdownTextPart }.count, 3)
        XCTAssertEqual(code.subviews.compactMap { $0 as? UIScrollView }.count, 1)
        XCTAssertGreaterThan(code.layer.cornerRadius, 0)
        XCTAssertGreaterThan(code.scroll.contentSize.width, code.scroll.bounds.width)
        XCTAssertGreaterThan(table.scroll.contentSize.width, table.scroll.bounds.width)
        XCTAssertTrue(code.text.isSelectable && !code.text.isScrollEnabled)
        XCTAssertNil(code.text.attributedText.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(code.text.blockText, String(MarkdownBlockLayout.elements(MarkdownDocument.parse(source))[1].block.text.characters))

        let cells = textViews(in: table)
        let first = try XCTUnwrap(cells.first { $0.accessibilityIdentifier == "markdown-table-cell-1-0" })
        let header = try XCTUnwrap(cells.first { $0.accessibilityIdentifier == "markdown-table-cell-0-0" })
        let center = try XCTUnwrap(cells.first { $0.accessibilityIdentifier == "markdown-table-cell-1-1" })
        let right = try XCTUnwrap(cells.first { $0.accessibilityIdentifier == "markdown-table-cell-1-2" })
        let fontSize = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: view.traitCollection).pointSize
        XCTAssertEqual(first.font!.pointSize, fontSize)
        XCTAssertTrue(header.font!.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual((center.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .center)
        XCTAssertEqual((right.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        XCTAssertTrue(table.blockText.contains("short\t\t4"), "Whole-table copy retains empty columns.")
        code.text.selectedRange = NSRange(location: 4, length: 5)
        table.scroll.contentOffset.x = 100
        code.scroll.contentOffset.x = 80

        let appended = source + "\n\nStreaming tail."
        view.update(MarkdownDocument.parse(appended), source: appended, width: 280)
        XCTAssertTrue(view.subviews.contains { $0 === code })
        XCTAssertTrue(view.subviews.contains { $0 === table })
        XCTAssertEqual(code.text.selectedRange, NSRange(location: 4, length: 5))
        XCTAssertEqual(table.scroll.contentOffset.x, 100)
        XCTAssertEqual(code.scroll.contentOffset.x, 80)
        view.setLayoutWidth(620)
        XCTAssertEqual(first.font!.pointSize, fontSize)
        XCTAssertEqual(table.scroll.contentOffset.x, 100)
        XCTAssertGreaterThan(table.scroll.contentSize.width, table.scroll.bounds.width)

        view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        view.update(MarkdownDocument.parse(appended), source: appended, width: 280)
        XCTAssertGreaterThan(first.font!.pointSize, fontSize)
        XCTAssertTrue(view.subviews.contains { $0 === table })
        view.reset()
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertEqual(view.intrinsicContentSize.height, 0)
    }

    func testOrdinaryParagraphsUseOneSelectableTextRegion() throws {
        let source = "First paragraph.\n\nSecond [safe](https://example.com) paragraph."
        let view = UIKitMarkdownView()
        view.update(MarkdownDocument.parse(source), source: source, width: 320)
        XCTAssertEqual(view.subviews.count, 1)
        let text = try XCTUnwrap(textViews(in: view).first)
        XCTAssertTrue(text.isSelectable)
        XCTAssertTrue(text.text.contains("First paragraph.\nSecond safe paragraph."))
    }
}
#endif
