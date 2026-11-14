import XCTest
@testable import ExecTranscript
#if canImport(UIKit)
import UIKit
#endif

final class TranscriptTests: XCTestCase {
    func testMarkdownPreservesBlocksAndRejectsUnsafeLinks() {
        let blocks = MarkdownDocument.parse("# Heading\n\nA **bold** [safe](https://example.com) and [unsafe](file:///private/file) link.\n\n- Item\n\n```swift\nlet x = 1\n```")
        XCTAssertTrue(blocks.contains { $0.kind == .header(level: 1) })
        XCTAssertTrue(blocks.contains { $0.kind == .unorderedList })
        XCTAssertTrue(blocks.contains { if case .codeBlock = $0.kind { true } else { false } })
        func links(_ blocks: [MarkdownBlock]) -> [URL] { blocks.flatMap { block in block.text.runs.compactMap(\.link) + links(block.children) } }
        XCTAssertEqual(links(blocks), [URL(string: "https://example.com")!])
        XCTAssertFalse(MarkdownDocument.allowsLink(URL(string: "javascript:alert(1)")!))
    }
    func testToolPresentationRetainsCommandsResultsAndFailureState() {
        let arguments = #"{"command":"printf hello","description":"Say hello"}"#
        let shell = ToolPresentation(name: "shell", arguments: arguments, result: .init(text: "Tool error: interrupted", outcome: "failed"), descriptiveShellTitles: true)
        XCTAssertEqual(shell.summary, "Say hello")
        XCTAssertEqual(shell.inputs, [.init(title: "Command", text: "printf hello")])
        XCTAssertEqual(shell.output, "Tool error: interrupted")
        XCTAssertEqual(shell.outputTitle, "Result")
        let read = ToolPresentation(name: "read_file", arguments: #"{"path":"file.swift"}"#, result: .init(text: "Revision: test\n12: first\n13: last\n"))
        XCTAssertEqual(read.detail, "Lines 12–13")
        let unknown = ToolPresentation(name: "new_tool", arguments: "{invalid", result: .init(text: "Exact output", outcome: "denied"))
        XCTAssertEqual(unknown.inputs, [.init(title: "Arguments", text: "{invalid")])
        XCTAssertEqual(unknown.output, "Exact output")
        XCTAssertEqual(unknown.detail, "Denied")
    }
    #if canImport(UIKit)
    @MainActor func testUIKitRendererKeepsSelectableCodeAndSafeLinks() {
        let text = UIKitMarkdownText.render(MarkdownDocument.parse("# Heading\n\n**Bold** [Link](https://example.com)\n\n```swift\nlet answer = 42\n```"), width: 320)
        XCTAssertTrue(text.string.contains("Heading"))
        XCTAssertTrue(text.string.contains("let answer = 42"))
        let bold = (text.string as NSString).range(of: "Bold")
        XCTAssertTrue((text.attribute(.font, at: bold.location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        let link = (text.string as NSString).range(of: "Link")
        XCTAssertEqual(text.attribute(.link, at: link.location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        let code = (text.string as NSString).range(of: "let answer")
        XCTAssertTrue((text.attribute(.font, at: code.location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
    }
    #endif
}
