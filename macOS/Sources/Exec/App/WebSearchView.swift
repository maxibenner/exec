import SwiftUI

struct WebSearchView: View {
    let result: WebSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !result.answer.isEmpty {
                MarkdownView(source: result.answer)
            }
            ToolSection(title: "Sources") {
                VStack(alignment: .leading, spacing: 8) {
                    if result.sources.isEmpty {
                        Text("No sources returned").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(result.sources.enumerated()), id: \.offset) { index, source in
                        if let url = source.link {
                            LinkedText(source: citation(index: index, source: source, url: url), fontSize: 12)
                        } else {
                            LinkedText(source: AttributedString("[\(index + 1)] \(source.title)\n\(source.url)"), fontSize: 12)
                        }
                    }
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
