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
    static let interrupted = "Web search did not complete. No complete search result was saved. It was not resumed or automatically retried."
}
