import AppKit
import SwiftUI

struct MarkdownView: View {
    private let text: NSAttributedString

    init(source: String, cache: MarkdownCache? = nil, isStreaming: Bool = false) {
        // Only mounted rows render. Measure actual Markdown on the first layout,
        // not literal source whose soft breaks may subsequently collapse away.
        text = cache?.initialText(for: source, isStreaming: isStreaming)
            ?? MarkdownText.render(isStreaming ? StreamingMarkdown.parse(source) : MarkdownDocument.parse(source))
    }

    var body: some View {
        LinkedText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                MarkdownDocument.allowsLink(url) ? .systemAction : .discarded
            })
    }
}

/// Bounded, width-independent cache. Reflow and remounting reuse rendered text;
/// offscreen messages still have only estimates and do not populate this cache.
@MainActor final class MarkdownCache {
    private let entries = NSCache<NSString, NSAttributedString>()
    private let streamingEntries = NSCache<NSString, NSAttributedString>()
    init() {
        entries.countLimit = 64; entries.totalCostLimit = 2 * 1024 * 1024
        streamingEntries.countLimit = 8; streamingEntries.totalCostLimit = 2 * 1024 * 1024
    }

    func initialText(for source: String, isStreaming: Bool = false) -> NSAttributedString {
        guard isStreaming else { return renderedText(for: source) ?? insert(MarkdownDocument.parse(source), for: source) }
        // Separate provisional and canonical entries, even for identical source.
        let key = ("stream:" + source) as NSString
        if let cached = streamingEntries.object(forKey: key) { return cached }
        let text = NSAttributedString(attributedString: MarkdownText.render(StreamingMarkdown.parse(source)))
        streamingEntries.setObject(text, forKey: key, cost: source.utf8.count + text.length * 2)
        return text
    }

    func renderedText(for source: String) -> NSAttributedString? {
        entries.object(forKey: source as NSString)
    }

    @discardableResult
    func insert(_ blocks: [MarkdownBlock], for source: String) -> NSAttributedString {
        if let cached = renderedText(for: source) { return cached }
        let text = NSAttributedString(attributedString: MarkdownText.render(blocks))
        entries.setObject(text, forKey: source as NSString, cost: source.utf8.count + text.length * 2)
        return text
    }
}
