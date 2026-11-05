import AppKit
import SwiftUI

struct MarkdownView: View {
    let source: String
    private let cache: MarkdownCache?
    @State private var blocks: [MarkdownBlock]

    init(source: String, cache: MarkdownCache? = nil) {
        self.source = source
        self.cache = cache
        _blocks = State(initialValue: cache?.value(for: source) ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty { Text(verbatim: source).textSelection(.enabled) }
            ForEach(blocks) { MarkdownBlockView(block: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            MarkdownDocument.allowsLink(url) ? .systemAction : .discarded
        })
        .task(id: source) {
            if let cached = cache?.value(for: source) { blocks = cached; return }
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
                blocks = result
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var ordered = false

    var body: some View {
        switch block.kind {
        case .header(let level):
            let size: CGFloat = level == 1 ? 24 : level == 2 ? 20 : 16
            inline(block.text, codeFont: .system(size: size, weight: .semibold, design: .monospaced), fontSize: size, weight: .semibold)
                .font(.system(size: size, weight: .semibold)).accessibilityAddTraits(.isHeader)
        case .codeBlock(let language):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let language, !language.isEmpty { Text(verbatim: language).lineLimit(1) }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(block.text.characters), forType: .string)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.primary)
                    .accessibilityLabel("Copy code")
                }
                .font(.caption).foregroundStyle(.secondary).padding(10)
                ScrollView(.horizontal) {
                    Text(verbatim: String(block.text.characters))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(10)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .orderedList, .unorderedList:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(block.children) { MarkdownBlockView(block: $0, ordered: block.kind == .orderedList) }
            }
        case .listItem(let ordinal):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(ordinal)." : "•").frame(minWidth: 18, alignment: .trailing)
                children
            }
        case .blockQuote:
            children.padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3) }
        case .thematicBreak:
            Divider()
        case .table(let columns):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(block.children) { row in
                        GridRow {
                            ForEach(columns.indices, id: \.self) { column in
                                inline(row.children.first { $0.kind == .tableCell(columnIndex: column) }?.text ?? AttributedString(),
                                       weight: row.kind == .tableHeaderRow ? .semibold : .regular)
                                    .fontWeight(row.kind == .tableHeaderRow ? .semibold : .regular)
                                    .fixedSize(horizontal: true, vertical: true)
                                    .gridColumnAlignment(alignment(columns[column].alignment))
                            }
                        }
                    }
                }
                .padding(10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        default:
            if block.children.isEmpty { inline(block.text) }
            else { children }
        }
    }

    private var children: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(block.children) { MarkdownBlockView(block: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: AttributedString, codeFont: Font = .system(.body, design: .monospaced),
                        fontSize: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular) -> some View {
        var styled = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            var font = codeFont
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { font = font.bold() }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { font = font.italic() }
            styled[run.range].font = font
            styled[run.range].backgroundColor = Color.secondary.opacity(0.12)
        }
        return Group {
            if text.runs.contains(where: { $0.link != nil }) {
                LinkedText(source: text, fontSize: fontSize, weight: weight)
            } else {
                Text(styled).textSelection(.enabled).lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alignment(_ value: PresentationIntent.TableColumn.Alignment) -> HorizontalAlignment {
        switch value {
        case .center: .center
        case .right: .trailing
        default: .leading
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
