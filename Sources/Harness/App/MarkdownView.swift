import AppKit
import SwiftUI

struct MarkdownView: View {
    let source: String
    @State private var blocks: [MarkdownBlock] = []

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
            let source = source
            let parsing = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return [MarkdownBlock]() }
                return MarkdownDocument.parse(source)
            }
            let result = await withTaskCancellationHandler {
                await parsing.value
            } onCancel: { parsing.cancel() }
            if !Task.isCancelled { blocks = result }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var ordered = false

    var body: some View {
        switch block.kind {
        case .header(let level):
            inline(block.text).font(.system(size: level == 1 ? 24 : level == 2 ? 20 : 16, weight: .semibold))
        case .codeBlock(let language):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let language, !language.isEmpty { Text(verbatim: language).lineLimit(1) }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(block.text.characters), forType: .string)
                    }
                    .buttonStyle(.borderless)
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
                                inline(row.children.first { $0.kind == .tableCell(columnIndex: column) }?.text ?? AttributedString())
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

    private func inline(_ text: AttributedString) -> some View {
        var styled = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(.body, design: .monospaced)
            styled[run.range].backgroundColor = Color.secondary.opacity(0.12)
        }
        return Text(styled).textSelection(.enabled)
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
