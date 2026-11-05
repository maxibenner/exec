import Foundation

struct WebSearchResult: Codable, Sendable, Equatable {
    struct Source: Codable, Sendable, Equatable {
        let title: String
        let url: String

        var link: URL? {
            guard url.utf8.count <= 1_024,
                  url.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  let components = URLComponents(string: url),
                  ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else { return nil }
            return components.url
        }
    }
    let query: String
    let answer: String
    let sources: [Source]

    var context: String {
        let citations = sources.enumerated().map { "[\($0.offset + 1)] \($0.element.title)\n\($0.element.url)" }
        return "Web search query: \(query)\n\n\(answer)\n\nSources:\n" +
            (citations.isEmpty ? "No source URLs returned." : citations.joined(separator: "\n\n"))
    }
}

enum WebSearchTool {
    static let definition = ToolDefinition(
        name: "web_search",
        description: "Search the public web for current or external information. Returns a bounded answer and source URLs. Use only necessary public search terms; never include credentials or private project contents. Search failures stop the turn; do not retry without a new user request.",
        parameters: [.init(name: "query", type: "string", description: "Public web search question or keywords; at most 2,048 UTF-8 bytes")]
    )

    static func query(_ call: ToolCall) throws -> String {
        struct Arguments: Decodable { let query: String }
        return try validatedQuery(CodingTools.decode(Arguments.self, call).query)
    }

    static func validatedQuery(_ query: String) throws -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 2_048,
              query.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw ExecError("Use a nonempty, single-line web search query of at most 2,048 bytes.")
        }
        return query
    }

    static let interrupted = "Web search did not complete. No complete search result was saved. It was not resumed or automatically retried."
}
