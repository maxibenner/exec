import SwiftUI

struct WebSearchView: View {
    let result: WebSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: result.query).font(.callout.weight(.medium)).textSelection(.enabled)
            if !result.answer.isEmpty { MarkdownView(source: result.answer) }
            ForEach(Array(result.sources.enumerated()), id: \.offset) { index, source in
                if let url = source.link {
                    LinkedText(source: citation(index: index, source: source, url: url), fontSize: 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func citation(index: Int, source: WebSearchResult.Source, url: URL) -> AttributedString {
        var text = AttributedString("[\(index + 1)] \(source.title)\n\(source.url)")
        text.link = url
        return text
    }
}
