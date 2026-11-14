import Foundation

/// Foundation supplies Markdown syntax; this tree retains block layout that Text alone ignores.
public struct MarkdownBlock: Identifiable, Sendable {
    public let id: Int
    public let kind: PresentationIntent.Kind
    public var text = AttributedString()
    public var children: [MarkdownBlock] = []

    fileprivate static func append(_ text: AttributedString, path: ArraySlice<PresentationIntent.IntentType>, to blocks: inout [MarkdownBlock]) {
        guard let component = path.first else { return }
        if blocks.last?.id != component.identity {
            blocks.append(MarkdownBlock(id: component.identity, kind: component.kind))
        }
        let index = blocks.count - 1
        if path.count == 1 { blocks[index].text.append(text) }
        else { append(text, path: path.dropFirst(), to: &blocks[index].children) }
    }
}

public enum MarkdownDocument {
    public static func allowsLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "http": return url.host?.isEmpty == false
        case "mailto": return !url.path.isEmpty
        default: return false
        }
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        // Bound parsing work for unusually large model output; never hide the original text.
        guard source.utf8.count <= 1_048_576,
              let parsed = try? AttributedString(markdown: source, options: .init(
                interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)),
              !parsed.characters.isEmpty else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
        }
        var blocks: [MarkdownBlock] = []
        var fallbackID = -1
        var identities = Set<Int>()
        for run in parsed.runs {
            if Task.isCancelled { return [] }
            // Copy only supported attributes. In particular, image URLs and raw HTML have no behavior.
            var text = AttributedString(String(parsed[run.range].characters))
            if let inline = run.inlinePresentationIntent {
                text.inlinePresentationIntent = inline.intersection([.stronglyEmphasized, .emphasized, .code, .strikethrough])
            }
            if let link = run.link, allowsLink(link) { text.link = link }
            if let intent = run.presentationIntent {
                let path = Array(intent.components.reversed())
                identities.formUnion(path.map(\.identity))
                guard path.count <= 32, identities.count <= 2_000,
                      !path.contains(where: { if case .table(let columns) = $0.kind { return columns.count > 32 }; return false }) else {
                    return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
                }
                MarkdownBlock.append(text, path: path[...], to: &blocks)
            } else {
                blocks.append(MarkdownBlock(id: fallbackID, kind: .paragraph, text: text))
                fallbackID -= 1
            }
        }
        return blocks
    }
}
