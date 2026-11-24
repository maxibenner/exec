#if canImport(UIKit)
import XCTest
import UIKit
@testable import ExecTranscript

private actor UIKitHighlightWorker {
    private(set) var sources: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    let suspended: Bool
    init(suspended: Bool = false) { self.suspended = suspended }
    func highlight(_ source: String, language: String?, documentID: UUID) async -> [SyntaxToken] {
        sources.append(source)
        if suspended { await withCheckedContinuation { continuation = $0 } }
        guard CodeHighlighter.normalizedLanguage(language) != nil, !source.isEmpty else { return [] }
        var tokens = [SyntaxToken(range: NSRange(location: 0, length: min(3, source.utf16.count)), kind: .keyword)]
        let stringRange = (source as NSString).range(of: "\"😀e\u{301}\"")
        if stringRange.location != NSNotFound { tokens.append(SyntaxToken(range: stringRange, kind: .string)) }
        return tokens
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private final class HighlightStorageEdits: NSObject, NSTextStorageDelegate {
    private(set) var attributeEdits = 0
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedAttributes) { attributeEdits += 1 }
    }
}

@MainActor final class UIKitCodeHighlightingTests: XCTestCase {
    private let light = UITraitCollection(userInterfaceStyle: .light)
    private func block(_ source: String, language: String? = "swift") -> MarkdownBlock {
        MarkdownBlock(id: 1, kind: .codeBlock(languageHint: language), text: AttributedString(source))
    }
    private func part(_ worker: UIKitHighlightWorker) -> MarkdownCodePart {
        MarkdownCodePart(highlightingDelay: .milliseconds(1)) { source, language, id in
            await worker.highlight(source, language: language, documentID: id)
        }
    }
    private func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for UIKit highlighting", file: file, line: line)
    }
    private func color(_ part: MarkdownCodePart, at offset: Int = 0) -> UIColor? {
        (part.text.textStorage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor)?
            .resolvedColor(with: light)
    }
    private func withoutColors(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        result.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: result.length))
        return result
    }

    func testAsyncColorsPreserveTextAttributesGeometrySelectionAndOffsetsWithoutRemeasure() async {
        let worker = UIKitHighlightWorker(suspended: true)
        let view = part(worker)
        let source = "let icon = \"😀e\u{301}\"\n// " + String(repeating: "long_line_", count: 80)
        let block = block(source)
        view.update(block, quoted: false, message: "whole message", traits: light)
        _ = view.height(for: 260)
        view.text.selectedRange = NSRange(location: 4, length: 4)
        view.scroll.contentOffset.x = 90
        let original = NSAttributedString(attributedString: view.text.textStorage)
        let textFrame = view.text.frame, scrollFrame = view.scroll.frame, contentSize = view.scroll.contentSize
        let measuredWidth = view.measuredWidth, measuredHeight = view.measuredHeight
        let textOffset = view.text.contentOffset
        await eventually { await worker.sources.count == 1 }
        await worker.resume()
        let keyword = SyntaxPalette.color(for: .keyword).resolvedColor(with: light)
        await eventually { self.color(view) == keyword }
        let stringRange = (source as NSString).range(of: "\"😀e\u{301}\"")
        XCTAssertEqual(color(view, at: stringRange.location), SyntaxPalette.color(for: .string).resolvedColor(with: light))
        XCTAssertEqual(Array(view.text.textStorage.string.utf8), Array(source.utf8))
        XCTAssertTrue(withoutColors(view.text.textStorage).isEqual(to: withoutColors(original)))
        XCTAssertEqual(view.text.selectedRange, NSRange(location: 4, length: 4))
        XCTAssertEqual(view.scroll.contentOffset.x, 90)
        XCTAssertEqual(view.text.contentOffset, textOffset)
        XCTAssertEqual(view.text.frame, textFrame)
        XCTAssertEqual(view.scroll.frame, scrollFrame)
        XCTAssertEqual(view.scroll.contentSize, contentSize)
        XCTAssertEqual(view.measuredWidth, measuredWidth)
        XCTAssertEqual(view.measuredHeight, measuredHeight)
        XCTAssertEqual(view.blockText, source)
        XCTAssertEqual(view.text.blockText, source)
        XCTAssertEqual(view.text.message, "whole message")

        view.update(block, quoted: false, message: "updated message", traits: light)
        XCTAssertEqual(view.measuredWidth, measuredWidth, "Syntax colors are not part of base-attribute identity.")
        XCTAssertEqual(view.measuredHeight, measuredHeight)
        XCTAssertEqual(view.text.selectedRange, NSRange(location: 4, length: 4))
        XCTAssertEqual(view.scroll.contentOffset.x, 90)
        XCTAssertEqual(color(view), keyword)
        _ = view.height(for: 400)
        try? await Task.sleep(for: .milliseconds(10))
        let sources = await worker.sources
        XCTAssertEqual(sources.count, 1, "Repeated configuration and resize do not tokenize again.")
    }

    func testUnchangedConfigurationAndLanguageAliasesDoNotRepaintButBaseChangesDo() async {
        let worker = UIKitHighlightWorker()
        let view = part(worker)
        let source = "let value = 42"
        view.update(block(source), quoted: false, message: source, traits: light)
        let keyword = SyntaxPalette.color(for: .keyword).resolvedColor(with: light)
        await eventually { self.color(view) == keyword }
        let edits = HighlightStorageEdits()
        view.text.textStorage.delegate = edits
        defer { view.text.textStorage.delegate = nil }

        for index in 0..<10 {
            view.update(block(source), quoted: false, message: "streaming prose \(index)", traits: light)
        }
        view.blockTitle = "Copy Snippet"
        let alias = block(source, language: " SWIFT ")
        view.update(alias, quoted: false, message: "latest prose", traits: light)
        XCTAssertEqual(edits.attributeEdits, 0, "Unchanged base content must not replay cached syntax attributes.")
        XCTAssertEqual(color(view), keyword)
        XCTAssertEqual(view.message, "latest prose")
        XCTAssertEqual(view.text.message, "latest prose")
        XCTAssertEqual(view.blockText, source)
        XCTAssertEqual(view.text.blockText, source)
        XCTAssertEqual(view.text.blockTitle, "Copy Snippet")

        // A real base-attribute replacement must still synchronously restore syntax colors.
        view.update(alias, quoted: true, message: "latest prose", traits: light)
        XCTAssertGreaterThan(edits.attributeEdits, 0, "The delegate observes real attribute writes.")
        XCTAssertEqual(color(view), keyword)
        XCTAssertEqual(color(view, at: 4), UIColor.secondaryLabel.resolvedColor(with: light))
        try? await Task.sleep(for: .milliseconds(10))
        let sources = await worker.sources
        XCTAssertEqual(sources.count, 1, "Language aliases and base styling changes reuse existing tokens.")
    }

    func testBaseFontReplacementReappliesAndRemovingLanguageClearsOnlyColors() async {
        let worker = UIKitHighlightWorker()
        let view = part(worker)
        let source = "let value = 42"
        view.update(block(source), quoted: false, message: source, traits: light)
        let keyword = SyntaxPalette.color(for: .keyword).resolvedColor(with: light)
        await eventually { self.color(view) == keyword }
        let oldFont = view.text.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let large = light.modifyingTraits { $0.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
        view.update(block(source), quoted: false, message: source, traits: large)
        let largeFont = view.text.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(largeFont?.pointSize ?? 0, oldFont?.pointSize ?? 0)
        XCTAssertEqual(color(view), keyword, "An identical source reapplies over replacement base text synchronously.")
        let beforeRemoval = withoutColors(view.text.textStorage)
        view.text.selectedRange = NSRange(location: 4, length: 5)
        view.update(block(source, language: nil), quoted: false, message: source, traits: large)
        await eventually { self.color(view) == UIColor.label.resolvedColor(with: self.light) }
        XCTAssertTrue(withoutColors(view.text.textStorage).isEqual(to: beforeRemoval))
        XCTAssertEqual(view.text.selectedRange, NSRange(location: 4, length: 5))
        let sources = await worker.sources
        XCTAssertEqual(sources.count, 2, "Only the language change needs new work, not the font replacement.")
    }

    func testCanonicalEquivalentReplacementKeepsExactBytes() async {
        let worker = UIKitHighlightWorker()
        let view = part(worker)
        let first = "e\u{301}\u{323}", second = "e\u{323}\u{301}"
        XCTAssertEqual(first, second)
        view.update(block(first), quoted: false, message: first, traits: light)
        await eventually { self.color(view) == SyntaxPalette.color(for: .keyword).resolvedColor(with: self.light) }
        view.update(block(second), quoted: false, message: second, traits: light)
        XCTAssertEqual(Array(view.text.textStorage.string.utf8), Array(second.utf8))
        await eventually { await worker.sources.count == 2 }
        XCTAssertEqual(Array(view.blockText.utf8), Array(second.utf8))
    }

    func testParsedFenceUsesTheProductionSchedulerAndSharedCore() async throws {
        let source = "```swift\nlet icon = \"😀e\u{301}\"\n```"
        let fence = try XCTUnwrap(MarkdownDocument.parse(source).first)
        let exactCode = String(fence.text.characters)
        let view = MarkdownCodePart()
        view.update(fence, quoted: false, message: source, traits: light)
        _ = view.height(for: 260)
        // Allow cold simulator grammar/query initialization, without warming a separate worker.
        await eventually(timeout: .seconds(15)) {
            self.color(view) == SyntaxPalette.color(for: .keyword).resolvedColor(with: self.light)
        }
        let stringRange = (exactCode as NSString).range(of: "\"😀e\u{301}\"")
        XCTAssertEqual(color(view, at: stringRange.location), SyntaxPalette.color(for: .string).resolvedColor(with: light))
        XCTAssertEqual(Array(view.text.textStorage.string.utf8), Array(exactCode.utf8))
        XCTAssertEqual(view.text.message, source)
    }

    func testPaletteResolvesDifferentLightAndDarkColorsForEveryKind() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let kinds: [SyntaxToken.Kind] = [.keyword, .string, .comment, .number, .type, .function,
                                         .property, .constant, .operator, .punctuation]
        for kind in kinds {
            let dynamic = SyntaxPalette.color(for: kind)
            XCTAssertNotEqual(dynamic.resolvedColor(with: light), dynamic.resolvedColor(with: dark))
        }
    }
}
#endif
