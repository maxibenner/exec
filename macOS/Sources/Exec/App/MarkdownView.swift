import AppKit
import SwiftUI

struct MarkdownView: View {
    let source: String
    private let cache: MarkdownCache?
    @State private var text: NSAttributedString

    init(source: String, cache: MarkdownCache? = nil) {
        self.source = source
        self.cache = cache
        _text = State(initialValue: cache?.initialText(for: source)
                      ?? LinkedText.attributed(AttributedString(source)))
    }

    var body: some View {
        LinkedText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                MarkdownDocument.allowsLink(url) ? .systemAction : .discarded
            })
            .task(id: source) {
                if let cached = cache?.renderedText(for: source) { text = cached; return }
                let source = source
                let parsing = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [MarkdownBlock]() }
                    return MarkdownDocument.parse(source)
                }
                let result = await withTaskCancellationHandler {
                    await parsing.value
                } onCancel: { parsing.cancel() }
                if !Task.isCancelled {
                    text = cache?.insert(result, for: source) ?? MarkdownText.render(result)
                }
            }
    }
}

/// Bounded, width-independent text cache. SwiftUI evaluates State's initial value
/// on every view initialization, even when retaining existing state during resize.
/// Cache placeholders too, but never mistake one for a finished Markdown render.
@MainActor final class MarkdownCache {
    private final class Entry {
        let text: NSAttributedString
        let rendered: Bool
        init(_ text: NSAttributedString, rendered: Bool) {
            self.text = NSAttributedString(attributedString: text)
            self.rendered = rendered
        }
    }
    private let entries = NSCache<NSString, Entry>()
    init() { entries.countLimit = 64; entries.totalCostLimit = 2 * 1024 * 1024 }

    func initialText(for source: String) -> NSAttributedString {
        if let entry = entries.object(forKey: source as NSString) { return entry.text }
        return store(LinkedText.attributed(AttributedString(source)), for: source, rendered: false)
    }

    func renderedText(for source: String) -> NSAttributedString? {
        guard let entry = entries.object(forKey: source as NSString), entry.rendered else { return nil }
        return entry.text
    }

    @discardableResult
    func insert(_ blocks: [MarkdownBlock], for source: String) -> NSAttributedString {
        if let cached = renderedText(for: source) { return cached }
        return store(MarkdownText.render(blocks), for: source, rendered: true)
    }

    private func store(_ text: NSAttributedString, for source: String, rendered: Bool) -> NSAttributedString {
        let entry = Entry(text, rendered: rendered)
        entries.setObject(entry, forKey: source as NSString, cost: source.utf8.count + text.length * 2)
        return entry.text
    }
}
