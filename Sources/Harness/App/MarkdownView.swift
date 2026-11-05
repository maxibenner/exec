import AppKit
import SwiftUI

struct MarkdownView: View {
    let source: String
    private let cache: MarkdownCache?
    @State private var text: NSAttributedString

    init(source: String, cache: MarkdownCache? = nil) {
        self.source = source
        self.cache = cache
        _text = State(initialValue: cache?.value(for: source).map(MarkdownText.render)
                      ?? LinkedText.attributed(AttributedString(source)))
    }

    var body: some View {
        LinkedText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                MarkdownDocument.allowsLink(url) ? .systemAction : .discarded
            })
            .task(id: source) {
                if let cached = cache?.value(for: source) { text = MarkdownText.render(cached); return }
                let source = source
                let parsing = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [MarkdownBlock]() }
                    return MarkdownDocument.parse(source)
                }
                let result = await withTaskCancellationHandler {
                    await parsing.value
                } onCancel: { parsing.cancel() }
                if !Task.isCancelled {
                    cache?.insert(result, for: source)
                    text = MarkdownText.render(result)
                }
            }
    }
}

/// Bounded parsed-data cache; recycled rows can remount without a plain-text flash.
@MainActor final class MarkdownCache {
    private final class Entry {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }
    private let entries = NSCache<NSString, Entry>()
    init() { entries.countLimit = 64; entries.totalCostLimit = 2 * 1024 * 1024 }
    func value(for source: String) -> [MarkdownBlock]? { entries.object(forKey: source as NSString)?.blocks }
    func insert(_ blocks: [MarkdownBlock], for source: String) {
        entries.setObject(Entry(blocks), forKey: source as NSString, cost: source.utf8.count)
    }
}
