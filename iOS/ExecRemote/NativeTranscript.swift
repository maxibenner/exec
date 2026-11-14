import SwiftUI
import UIKit
import ExecRemote
import ExecTranscript

/// UIKit owns virtualization and reuse. Tool rows host the same SwiftUI card as
/// macOS; message rows use selectable TextKit with the shared Markdown parser.
struct NativeTranscript: UIViewRepresentable {
    let conversationID: String?
    let snapshot: RemoteJSON
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = .systemBackground
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 120
        table.keyboardDismissMode = .interactive
        table.allowsSelection = false
        table.register(MessageCell.self, forCellReuseIdentifier: "message")
        table.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
        context.coordinator.attach(table)
        return table
    }
    func updateUIView(_ table: UITableView, context: Context) {
        context.coordinator.update(conversationID: conversationID, snapshot: snapshot, table: table)
    }
    @MainActor final class Coordinator {
        private var source: UITableViewDiffableDataSource<Int, String>?
        private var rows: [String: RemoteTranscriptRow] = [:]
        private var conversationID: String?
        private var expansion: [String: Bool] = [:]
        func attach(_ table: UITableView) {
            source = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
                guard let self, let row = self.rows[id] else { return UITableViewCell() }
                if let call = row.call {
                    let cell = table.dequeueReusableCell(withIdentifier: "tool", for: path)
                    let binding = Binding(get: { [weak self] in self?.expansion[id] ?? (row.message["details"]["type"].string == "edit") }, set: { [weak self] value in
                        guard let self, self.rows[id] != nil, let source = self.source else { return }
                        self.expansion[id] = value
                        var snapshot = source.snapshot()
                        guard snapshot.itemIdentifiers.contains(id) else { return }
                        snapshot.reconfigureItems([id]); source.apply(snapshot, animatingDifferences: false)
                    })
                    cell.contentConfiguration = UIHostingConfiguration {
                        MobileToolCard(call: call, result: row.message, awaitingApproval: row.awaitingApproval, expanded: binding)
                    }.margins(.horizontal, 16).margins(.vertical, 6)
                    return cell
                }
                guard let cell = table.dequeueReusableCell(withIdentifier: "message", for: path) as? MessageCell else { return UITableViewCell() }
                cell.configure(row.message, width: max(100, table.bounds.width - 32))
                return cell
            }
        }
        func update(conversationID: String?, snapshot: RemoteJSON, table: UITableView) {
            guard let source else { return }
            let changedConversation = self.conversationID != conversationID
            let nearBottom = table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom >= table.contentSize.height - 60
            var next: [String: RemoteTranscriptRow] = [:]
            var ids: [String] = []
            for row in RemoteTranscriptRow.project(snapshot) where !row.id.isEmpty && next[row.id] == nil { ids.append(row.id); next[row.id] = row }
            guard changedConversation || next != rows else { return }
            let previousIDs = Set(source.snapshot().itemIdentifiers)
            let changed = ids.filter { previousIDs.contains($0) && next[$0] != rows[$0] }
            if changedConversation { expansion.removeAll() }
            else { expansion = expansion.filter { next[$0.key] != nil } }
            rows = next; self.conversationID = conversationID
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0]); snapshot.appendItems(ids)
            snapshot.reconfigureItems(changed)
            source.apply(snapshot, animatingDifferences: false) {
                guard changedConversation || nearBottom, !ids.isEmpty, !table.isDragging, !table.isDecelerating else { return }
                table.layoutIfNeeded()
                table.scrollToRow(at: IndexPath(row: ids.count - 1, section: 0), at: .bottom, animated: false)
            }
        }
    }
}

private struct MobileToolCard: View {
    let call: RemoteJSON
    let result: RemoteJSON
    let awaitingApproval: Bool
    @Binding var expanded: Bool
    private var presentation: ToolPresentation {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let arguments = String(decoding: (try? encoder.encode(call["arguments"])) ?? Data(), as: UTF8.self)
        let details = result["details"]
        let display = result == .null ? nil : ToolDisplayResult(text: result["text"].string ?? "",
            outcome: result["outcome"].string,
            editPath: details["type"].string == "edit" ? details["path"].string : nil,
            searchQuery: details["type"].string == "search" ? details["result"]["query"].string : nil,
            pageText: details["type"].string == "page" ? details["content"]["text"].string : nil)
        return ToolPresentation(name: call["name"].string ?? "Tool", arguments: arguments, result: display)
    }
    var body: some View {
        let presentation = presentation
        ToolCard(presentation: presentation, isExpanded: $expanded, awaitingApproval: awaitingApproval) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(presentation.inputs.indices, id: \.self) { index in
                    section(presentation.inputs[index].title, text: presentation.inputs[index].text)
                }
                if let diff = result["details"]["diff"].string, result["details"]["type"].string == "edit" {
                    section("Diff", text: diff)
                } else if result != .null {
                    section(presentation.outputTitle, text: presentation.output)
                }
            }.padding(.horizontal, 12).padding(.bottom, 12)
        }
    }
    private func section(_ title: String?, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(verbatim: title).font(.caption).foregroundStyle(.secondary) }
            Text(verbatim: text.isEmpty ? "No output" : text)
                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor private final class MessageCell: UITableViewCell, UITextViewDelegate {
    private let role = UILabel()
    private let text = UITextView()
    private var sourceText: String?
    private var markdown = false
    private var blocks: [MarkdownBlock] = []
    private var renderedWidth: CGFloat = 0
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        role.font = .preferredFont(forTextStyle: .caption1)
        role.adjustsFontForContentSizeCategory = true; role.textColor = .secondaryLabel
        text.isEditable = false; text.isSelectable = true; text.isScrollEnabled = false
        text.backgroundColor = .clear; text.delegate = self
        text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = .zero; text.textContainer.lineFragmentPadding = 0
        text.dataDetectorTypes = []
        let stack = UIStackView(arrangedSubviews: [role, text])
        stack.axis = .vertical; stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: MessageCell, _: UITraitCollection) in
            cell.render(width: cell.renderedWidth)
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }
    override func prepareForReuse() { super.prepareForReuse(); sourceText = nil; blocks = [] }
    override func layoutSubviews() {
        super.layoutSubviews()
        if sourceText != nil, text.bounds.width > 0, abs(text.bounds.width - renderedWidth) > 1 { render(width: text.bounds.width) }
    }
    func configure(_ message: RemoteJSON, width: CGFloat) {
        role.text = message["role"].string?.capitalized ?? "Message"
        var content = message["text"].string ?? ""
        if !message["images"].array.isEmpty { content += "\n[Image attachment]" }
        let useMarkdown = message["role"].string == "assistant"
        guard sourceText != content || markdown != useMarkdown else { return }
        sourceText = content; markdown = useMarkdown
        blocks = useMarkdown ? MarkdownDocument.parse(content) : []
        render(width: width)
    }
    private func render(width: CGFloat) {
        guard let sourceText else { return }
        renderedWidth = max(100, width)
        text.attributedText = markdown ? UIKitMarkdownText.render(blocks, width: renderedWidth) : NSAttributedString(string: sourceText,
            attributes: [.font:UIFont.preferredFont(forTextStyle: .body), .foregroundColor:UIColor.label])
    }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        MarkdownDocument.allowsLink(URL)
    }
}
