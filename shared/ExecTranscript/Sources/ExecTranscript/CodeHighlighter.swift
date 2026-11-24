import Foundation
// Access-level imports still serialize a required TreeSitter C import into the Swift module.
// Implementation-only imports let direct swiftc clients use just this module and the static archive.
@_implementationOnly import SwiftTreeSitter
@_implementationOnly import TreeSitterSwift
@_implementationOnly import TreeSitterJavaScript
@_implementationOnly import TreeSitterTypeScript
@_implementationOnly import TreeSitterTSX
@_implementationOnly import TreeSitterPython
@_implementationOnly import TreeSitterRust
@_implementationOnly import TreeSitterGo
@_implementationOnly import TreeSitterC
@_implementationOnly import TreeSitterCPP
@_implementationOnly import TreeSitterBash
@_implementationOnly import TreeSitterHTML
@_implementationOnly import TreeSitterCSS
@_implementationOnly import TreeSitterJSON
@_implementationOnly import TreeSitterYAML

public struct SyntaxToken: Sendable, Equatable {
    public enum Kind: Sendable, Hashable, CaseIterable {
        case keyword, string, comment, number, type, function, property, constant, `operator`, punctuation
    }

    /// A UTF-16 range in the exact source passed to `highlight`.
    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// Serialized, off-main-actor tokenization. Unsupported input or exhausted work budgets returns plain text (`[]`).
public actor CodeHighlighter {
    public static let shared = CodeHighlighter()

    enum Limits {
        static let sourceBytes = 128 * 1024
        static let documents = 24
        static let cacheEntries = 48
        static let cacheBytes = 2 * 1024 * 1024
        static let tokens = 8_192
        static let matches = 32_768
        static let parseSeconds = 0.025
        static let querySeconds = 0.025
    }

    private struct CacheKey: Hashable {
        // String equality is canonically equivalent, not byte-exact. Data also keeps UTF-16 offsets distinct.
        let source: Data
        let language: String
    }

    private struct CachedTokens {
        let tokens: [SyntaxToken]
        let cost: Int
        var used: UInt64
    }

    @_implementationOnly private struct Document {
        let language: String
        let parser: Parser
        var tree: MutableTree
        var source: String
        var used: UInt64
    }

    @_implementationOnly private struct Configuration {
        let language: Language
        let query: Query
    }

    private var documents: [UUID: Document] = [:]
    private var cache: [CacheKey: CachedTokens] = [:]
    private var configurations: [String: Configuration] = [:]
    private var unavailableLanguages: Set<String> = []
    private var clock: UInt64 = 0
    private var cacheCost = 0

    // Internal read-only counts keep the retention limits verifiable without exposing parser types.
    var retainedDocumentCount: Int { documents.count }
    var cachedEntryCount: Int { cache.count }
    var cachedByteCount: Int { cacheCost }

    public init() {}

    public static nonisolated func normalizedLanguage(_ hint: String?) -> String? {
        guard let hint else { return nil }
        switch hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "swift": return "swift"
        case "js", "javascript", "jsx", "javascriptreact", "node", "nodejs": return "javascript"
        case "ts", "typescript": return "typescript"
        case "tsx", "typescriptreact": return "tsx"
        case "py", "python", "python3": return "python"
        case "rs", "rust": return "rust"
        case "go", "golang": return "go"
        case "c", "h": return "c"
        case "cpp", "c++", "cc", "cxx", "hpp", "hxx": return "cpp"
        case "bash", "sh", "shell", "zsh": return "bash"
        case "html", "htm": return "html"
        case "css": return "css"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        default: return nil
        }
    }

    public func highlight(_ source: String, language: String?, documentID: UUID) -> [SyntaxToken] {
        guard !Task.isCancelled, !source.isEmpty,
              source.utf8.count <= Limits.sourceBytes,
              let language = Self.normalizedLanguage(language) else {
            release(documentID: documentID)
            return []
        }
        clock &+= 1
        if documents[documentID]?.language != language {
            documents.removeValue(forKey: documentID)
        }
        let key = CacheKey(source: Data(source.utf8), language: language)
        if var hit = cache[key] {
            hit.used = clock
            cache[key] = hit
            // A content hit does not pretend that a stale tree represents the new source.
            if var document = documents[documentID] {
                document.used = clock
                documents[documentID] = document
            }
            return hit.tokens
        }
        guard let configuration = configuration(for: language), !Task.isCancelled else { return [] }

        let parser: Parser
        let oldTree: MutableTree?
        if let document = documents[documentID] {
            parser = document.parser
            oldTree = document.tree
            if let edit = Self.edit(from: document.source, to: source) {
                oldTree?.edit(edit)
            }
        } else {
            parser = Parser()
            parser.timeout = Limits.parseSeconds
            guard (try? parser.setLanguage(configuration.language)) != nil else { return [] }
            oldTree = nil
        }
        guard let tree = parser.parse(tree: oldTree, string: source), !Task.isCancelled else {
            parser.reset() // A timed-out parser must not resume the interrupted source on the next request.
            documents.removeValue(forKey: documentID)
            return []
        }
        documents[documentID] = Document(language: language, parser: parser, tree: tree, source: source, used: clock)
        while documents.count > Limits.documents,
              let oldest = documents.min(by: { $0.value.used < $1.value.used })?.key {
            documents.removeValue(forKey: oldest)
        }

        guard let tokens = Self.tokens(in: tree, query: configuration.query, source: source), !Task.isCancelled else {
            return []
        }
        let cost = key.source.count + tokens.count * MemoryLayout<SyntaxToken>.stride
        cache[key] = CachedTokens(tokens: tokens, cost: cost, used: clock)
        cacheCost += cost
        while cache.count > Limits.cacheEntries || cacheCost > Limits.cacheBytes {
            guard let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key,
                  let removed = cache.removeValue(forKey: oldest) else { break }
            cacheCost -= removed.cost
        }
        return tokens
    }

    /// Release the incremental parser/tree. The bounded, content-addressed token cache is shared across documents.
    public func release(documentID: UUID) {
        documents.removeValue(forKey: documentID)
    }

    private func configuration(for name: String) -> Configuration? {
        if let configuration = configurations[name] { return configuration }
        guard !unavailableLanguages.contains(name) else { return nil }
        let pointer: OpaquePointer
        let queries: [String]
        switch name {
        case "swift": pointer = tree_sitter_swift(); queries = ["swift"]
        case "javascript": pointer = tree_sitter_javascript(); queries = ["javascript", "jsx"]
        case "typescript": pointer = tree_sitter_typescript(); queries = ["javascript", "typescript"]
        case "tsx": pointer = tree_sitter_tsx(); queries = ["javascript", "jsx", "typescript"]
        case "python": pointer = tree_sitter_python(); queries = ["python"]
        case "rust": pointer = tree_sitter_rust(); queries = ["rust"]
        case "go": pointer = tree_sitter_go(); queries = ["go"]
        case "c": pointer = tree_sitter_c(); queries = ["c"]
        case "cpp": pointer = tree_sitter_cpp(); queries = ["c", "cpp"]
        case "bash": pointer = tree_sitter_bash(); queries = ["bash"]
        case "html": pointer = tree_sitter_html(); queries = ["html"]
        case "css": pointer = tree_sitter_css(); queries = ["css"]
        case "json": pointer = tree_sitter_json(); queries = ["json"]
        case "yaml": pointer = tree_sitter_yaml(); queries = ["yaml"]
        default: return nil
        }
        do {
            let data = try queries.map { name in
                guard let url = Self.queryBundle?.url(forResource: name, withExtension: "scm", subdirectory: "SyntaxQueries") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return try String(contentsOf: url, encoding: .utf8)
            }.joined(separator: "\n")
            let language = Language(pointer)
            let configuration = Configuration(language: language, query: try Query(language: language, data: Data(data.utf8)))
            configurations[name] = configuration
            return configuration
        } catch {
            unavailableLanguages.insert(name)
            return nil
        }
    }

    // Unlike Bundle.module's fatal missing-resource fallback, a mispackaged client remains plain text.
    private static let queryBundle: Bundle? = {
        let name = "ExecTranscript_ExecTranscript.bundle"
        let containers = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                          Bundle.main.bundleURL.deletingLastPathComponent(),
                          Bundle(for: BundleLocator.self).resourceURL]
        for container in containers.compactMap({ $0 }) {
            if let bundle = Bundle(url: container.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()

    private final class BundleLocator: NSObject {}

    private static func tokens(in tree: MutableTree, query: Query, source: String) -> [SyntaxToken]? {
        let cursor = query.execute(in: tree)
        // Keep the native default: a small in-progress match limit silently drops
        // captures, and SwiftTreeSitter does not expose its exhaustion flag.
        let text = source as NSString
        let context = Predicate.Context(textProvider: { range, _ in
            guard range.location >= 0, range.length >= 0,
                  range.location <= text.length, range.length <= text.length - range.location else { return nil }
            return text.substring(with: range)
        })
        let deadline = ContinuousClock.now + .seconds(Limits.querySeconds)
        var work = 0
        var tokens: [SyntaxToken] = []
        while let match = cursor.next() {
            work += 1 + match.captures.count
            guard work <= Limits.matches, !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            // SwiftTreeSitter's raw cursor does NOT evaluate text predicates. Unknown predicates fail closed.
            guard !match.predicates.contains(where: { if case .generic = $0 { true } else { false } }),
                  match.allowed(in: context) else { continue }
            for capture in match.captures {
                let range = capture.range
                guard let kind = kind(for: capture.nameComponents),
                      range.location >= 0, range.length > 0, range.location <= text.length,
                      range.length <= text.length - range.location else { continue }
                // Parser ranges already use UTF-16 scalar boundaries. Avoid repeatedly
                // walking Swift String indices for every token in a large block.
                tokens.append(SyntaxToken(range: range, kind: kind))
                guard tokens.count <= Limits.tokens else { return nil }
            }
        }
        // The wrapper cannot interrupt cursor.next(): this deadline is cooperative,
        // backed by the source-size cap, and checked even after a no-match traversal.
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        // General captures first, then specific/nested captures. Consumers can apply these in order;
        // a property capture, for example, overrides the enclosing JSON string's color.
        return tokens.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return priority($0.kind) < priority($1.kind)
        }
    }

    private static func kind(for components: [String]) -> SyntaxToken.Kind? {
        switch components.first {
        case "keyword": return .keyword
        case "string", "character": return .string
        case "comment": return .comment
        case "number", "float": return .number
        case "type", "constructor", "tag": return .type
        case "function", "method": return .function
        case "property", "attribute", "field": return .property
        case "constant", "boolean": return .constant
        case "operator": return .operator
        case "punctuation": return .punctuation
        default: return nil
        }
    }

    private static func priority(_ kind: SyntaxToken.Kind) -> Int {
        switch kind {
        case .punctuation: return 0
        case .operator: return 1
        case .string: return 2
        case .number: return 3
        case .constant: return 4
        case .type: return 5
        case .function: return 6
        case .keyword: return 7
        case .property: return 8
        case .comment: return 9
        }
    }

    /// One replacement spanning the changed middle, expressed in UTF-16 bytes/points for the parser.
    private static func edit(from old: String, to new: String) -> InputEdit? {
        let before = Array(old.utf16)
        let after = Array(new.utf16)
        var start = 0
        while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
        if start == before.count, start == after.count { return nil }
        // Don't split a surrogate pair at either edit boundary.
        if start > 0, start < before.count, (0xDC00...0xDFFF).contains(before[start]) { start -= 1 }
        var oldEnd = before.count
        var newEnd = after.count
        while oldEnd > start, newEnd > start, before[oldEnd - 1] == after[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        if oldEnd < before.count, (0xDC00...0xDFFF).contains(before[oldEnd]) {
            oldEnd += 1
            newEnd += 1
        }
        func point(_ units: [UInt16], at offset: Int) -> Point {
            var row = 0
            var column = 0
            for unit in units.prefix(offset) {
                if unit == 10 { row += 1; column = 0 } else { column += 2 }
            }
            return Point(row: row, column: column)
        }
        return InputEdit(startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
                         startPoint: point(before, at: start), oldEndPoint: point(before, at: oldEnd),
                         newEndPoint: point(after, at: newEnd))
    }
}
