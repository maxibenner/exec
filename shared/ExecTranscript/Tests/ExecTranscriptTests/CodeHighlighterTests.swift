import Foundation
import XCTest
@testable import ExecTranscript

@MainActor
final class CodeHighlighterTests: XCTestCase {
    func testLanguageAliasesAndPlainTextFallback() async {
        for (hint, expected) in [(" Swift\n", "swift"), ("JS", "javascript"), ("jsx", "javascript"),
                                 ("ts", "typescript"), ("TSX", "tsx"), ("py", "python"), ("rs", "rust"),
                                 ("golang", "go"), ("c++", "cpp"), ("sh", "bash"), ("yml", "yaml")] {
            XCTAssertEqual(CodeHighlighter.normalizedLanguage(hint), expected)
        }
        for hint: String? in [nil, "", "text", "unknown", "swift extra"] {
            XCTAssertNil(CodeHighlighter.normalizedLanguage(hint))
            let tokens = await CodeHighlighter.shared.highlight("let answer = 42", language: hint, documentID: UUID())
            XCTAssertEqual(tokens, [])
        }
    }

    func testEveryPinnedGrammarAndComposedQueryLoads() async {
        let cases: [(String, String, String, SyntaxToken.Kind)] = [
            ("swift", "func greet() -> String { return \"hello\" }", "func", .keyword),
            ("js", "function greet() { return 42; }", "function", .keyword),
            ("jsx", "const view = <section title=\"hello\">ok</section>;", "section", .type),
            ("ts", "interface Person { age: number }", "interface", .keyword),
            ("tsx", "const view: JSX.Element = <section />;", "section", .type),
            ("python", "def greet():\n    return \"hello\"", "def", .keyword),
            ("rust", "fn main() { let answer = 42; }", "fn", .keyword),
            ("go", "package main\nfunc main() { println(42) }", "func", .keyword),
            ("c", "int main(void) { return 42; }", "return", .keyword),
            ("cpp", "class Person { public: int age = 42; };", "class", .keyword),
            ("bash", "if true; then echo \"hello\"; fi", "if", .keyword),
            ("sh", "# comment\necho hello", "# comment", .comment),
            ("html", "<div title=\"hello\">ok</div>", "div", .type),
            ("css", ".item { color: red; }", "color", .property),
            ("json", "{\"answer\": 42, \"enabled\": true}", "42", .number),
            ("yaml", "answer: 42\nenabled: true\n# comment", "# comment", .comment),
        ]
        let highlighter = CodeHighlighter()
        for (language, source, spelling, kind) in cases {
            let tokens = await highlighter.highlight(source, language: language, documentID: UUID())
            XCTAssertFalse(tokens.isEmpty, "Failed grammar/query/resources: \(language)")
            XCTAssertTrue(tokens.contains { $0.kind == kind && (source as NSString).substring(with: $0.range) == spelling },
                          "Missing \(kind) capture for \(language): \(spelling)")
            assertValid(tokens, in: source)
        }
    }

    func testPredicatesDoNotColorOrdinaryIdentifiersAsConstantsOrTypes() async {
        let source = "const ordinary = 1; const UPPER_CASE = 2; const Widget = 3;"
        let tokens = await CodeHighlighter().highlight(source, language: "javascript", documentID: UUID())
        func kinds(_ spelling: String) -> [SyntaxToken.Kind] {
            tokens.filter { (source as NSString).substring(with: $0.range) == spelling }.map(\.kind)
        }
        XCTAssertFalse(kinds("ordinary").contains(.constant))
        XCTAssertFalse(kinds("ordinary").contains(.type))
        XCTAssertTrue(kinds("UPPER_CASE").contains(.constant))
        XCTAssertTrue(kinds("Widget").contains(.type))
    }

    func testIncrementalEditsUnicodeMultilineAndCacheReversionMatchFreshParsing() async {
        let highlighter = CodeHighlighter()
        let id = UUID()
        let versions = [
            "let emoji = \"😀\"\nlet café = 1\n// note",
            "let emoji = \"😁\"\nlet café = 12\n// changed",
            "// inserted\r\nlet emoji = \"😁🦀\"\r\nlet café = 12",
            "let emoji = \"😀\"\nlet café = 1\n// note", // content-cache hit, but tree still represents the previous source
            "let emoji = \"😀\"\nlet café = 123\n// after reversion",
            "", "func fresh() { print(\"👩🏽‍💻e\u{301}\") }",
        ]
        for source in versions {
            let incremental = await highlighter.highlight(source, language: "swift", documentID: id)
            let fresh = await CodeHighlighter().highlight(source, language: "swift", documentID: UUID())
            XCTAssertEqual(incremental, fresh, "Incremental mismatch for \(source)")
            assertValid(incremental, in: source)
        }
        await highlighter.release(documentID: id)
        let count = await highlighter.retainedDocumentCount
        XCTAssertEqual(count, 0)
        let reloaded = await highlighter.highlight("let answer = 7", language: "swift", documentID: id)
        XCTAssertFalse(reloaded.isEmpty)
    }

    func testCacheUsesExactSourceAndLanguage() async {
        let highlighter = CodeHighlighter()
        let id = UUID()
        let composed = "let café = \"é\""
        let decomposed = "let cafe\u{301} = \"e\u{301}\""
        XCTAssertEqual(composed, decomposed) // Swift's canonical equality must not alias the cache keys.
        for source in [composed, decomposed, composed] {
            let actual = await highlighter.highlight(source, language: "swift", documentID: id)
            let fresh = await CodeHighlighter().highlight(source, language: "swift", documentID: UUID())
            XCTAssertEqual(actual, fresh)
            assertValid(actual, in: source)
        }
        let swift = await highlighter.highlight("let answer = 42", language: "swift", documentID: id)
        let python = await highlighter.highlight("let answer = 42", language: "python", documentID: id)
        let freshPython = await CodeHighlighter().highlight("let answer = 42", language: "python", documentID: UUID())
        XCTAssertNotEqual(swift, python)
        XCTAssertEqual(python, freshPython)
        let unknown = await highlighter.highlight("let answer = 42", language: nil, documentID: id)
        XCTAssertEqual(unknown, [])
        let count = await highlighter.retainedDocumentCount
        XCTAssertEqual(count, 0)
    }

    func testRetentionAndWorkLimitsAndCancellation() async {
        let highlighter = CodeHighlighter()
        for index in 0..<80 {
            _ = await highlighter.highlight("let value = \(index)", language: "swift", documentID: UUID())
        }
        let documents = await highlighter.retainedDocumentCount
        let entries = await highlighter.cachedEntryCount
        let bytes = await highlighter.cachedByteCount
        XCTAssertLessThanOrEqual(documents, CodeHighlighter.Limits.documents)
        XCTAssertLessThanOrEqual(entries, CodeHighlighter.Limits.cacheEntries)
        XCTAssertLessThanOrEqual(bytes, CodeHighlighter.Limits.cacheBytes)
        let oversized = String(repeating: "a", count: CodeHighlighter.Limits.sourceBytes + 1)
        let oversizedTokens = await highlighter.highlight(oversized, language: "swift", documentID: UUID())
        XCTAssertEqual(oversizedTokens, [])
        let excessiveTokens = String(repeating: "[1,2,3,4,5];\n", count: 3_000)
        let bounded = await highlighter.highlight(excessiveTokens, language: "javascript", documentID: UUID())
        XCTAssertEqual(bounded, []) // Never expose a partially highlighted result after a work/token limit.
        assertValid(bounded, in: excessiveTokens)
        // Exercise the byte budget independently of the entry-count budget, including the exact source cap.
        for index in 0..<24 {
            let prefix = "// \(index) "
            let source = prefix + String(repeating: "a", count: CodeHighlighter.Limits.sourceBytes - prefix.utf8.count)
            let comment = await highlighter.highlight(source, language: "javascript", documentID: UUID())
            XCTAssertEqual(comment.first?.kind, .comment)
            let cost = await highlighter.cachedByteCount
            XCTAssertLessThanOrEqual(cost, CodeHighlighter.Limits.cacheBytes)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await highlighter.highlight("let x = 1", language: "swift", documentID: UUID())
        }
        let result = await cancelled.value
        XCTAssertEqual(result, [])
        let recovered = await highlighter.highlight("let recovered = 1", language: "swift", documentID: UUID())
        XCTAssertFalse(recovered.isEmpty)
    }

    private func assertValid(_ tokens: [SyntaxToken], in source: String, file: StaticString = #filePath, line: UInt = #line) {
        for token in tokens {
            XCTAssertGreaterThan(token.range.length, 0, file: file, line: line)
            XCTAssertNotNil(Range(token.range, in: source), file: file, line: line)
        }
    }
}
