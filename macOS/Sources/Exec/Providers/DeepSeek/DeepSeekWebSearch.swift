import Foundation

enum DeepSeekWebSearch {
    private static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        return String(decoding: text.utf8.prefix(bytes), as: UTF8.self) + " [Excerpt truncated.]"
    }

    static func result(_ data: Data, query: String) throws -> WebSearchResult {
        struct Response: Decodable {
            struct Result: Decodable {
                let title: String
                let url: String
                let snippet: String
                let summary: String
            }
            let results: [Result]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ExecError("DeepSeek returned invalid search results.")
        }
        var sources: [WebSearchResult.Source] = []
        var excerpts: [String] = []
        var seen = Set<String>()
        for result in response.results.prefix(10) {
            let source = WebSearchResult.Source(title: bounded(result.title, bytes: 200), url: result.url)
            guard source.link != nil, seen.insert(source.url).inserted else { continue }
            sources.append(source)
            excerpts.append("[\(sources.count)] " + bounded(result.summary.isEmpty ? result.snippet : result.summary, bytes: 1_000))
        }
        return WebSearchResult(query: query, answer: excerpts.isEmpty ? "No usable search results returned." : excerpts.joined(separator: "\n\n"), sources: sources)
    }
}
