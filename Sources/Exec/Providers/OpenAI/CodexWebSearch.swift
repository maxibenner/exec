import Foundation

/// Only complete hosted-search output becomes a tool result. Nothing here mutates chat response context.
enum CodexWebSearch {
    static func result(_ output: Data, query: String) throws -> WebSearchResult {
        guard output.count <= 4 * 1024 * 1024,
              let items = try JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
            throw ExecError("Codex returned invalid web search output.")
        }
        let searches = items.filter { $0["type"] as? String == "web_search_call" }
        guard !searches.isEmpty else {
            throw ExecError("Codex did not perform a web search. This model or account may not support hosted search; no retry was made.")
        }
        guard searches.allSatisfy({ $0["status"] == nil || $0["status"] as? String == "completed" }) else {
            throw ExecError("Codex web search did not complete. No retry was made.")
        }
        let parts = items.filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let text = parts.filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = text.utf8.count <= 12_000 ? text
            : String(decoding: text.utf8.prefix(12_000), as: UTF8.self) + "\n[Search answer truncated.]"
        var sources: [WebSearchResult.Source] = []
        var seen = Set<String>()
        func add(_ value: [String: Any]) {
            guard sources.count < 10, let url = (value["url"] ?? value["source_website_url"]) as? String else { return }
            let title = ((value["title"] ?? value["caption"]) as? String ?? "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let source = WebSearchResult.Source(title: title.isEmpty ? "Source" : String(title.prefix(160)), url: url)
            guard source.link != nil, seen.insert(url).inserted else { return }
            sources.append(source)
        }
        // Prefer URLs actually cited in the answer before the broader consulted-source list.
        for part in parts {
            for citation in part["annotations"] as? [[String: Any]] ?? [] where citation["type"] as? String == "url_citation" {
                add(citation)
            }
        }
        for search in searches {
            let action = search["action"] as? [String: Any]
            for group in [action?["sources"], search["sources"], search["results"]] {
                for source in group as? [[String: Any]] ?? [] { add(source) }
            }
        }
        guard !answer.isEmpty || !sources.isEmpty else {
            throw ExecError("Codex web search returned no answer or usable sources. No retry was made.")
        }
        let result = WebSearchResult(query: try WebSearchTool.validatedQuery(query), answer: answer, sources: sources)
        guard result.context.utf8.count <= 32_768 else { throw ExecError("Web search result exceeded 32 KiB.") }
        return result
    }
}
