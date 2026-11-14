import SwiftUI
import UIKit
import ExecRemote
import ExecTranscript

/// UIKit owns virtualization and reuse. Tool rows host the same SwiftUI card as
/// macOS; message rows use selectable TextKit with the shared Markdown parser.
struct NativeTranscript: UIViewRepresentable {
    let conversationID: String?
    let snapshot: RemoteJSON
    let bottomPadding: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITableView {
        let table = TranscriptTableView(frame: .zero, style: .plain)
        table.backgroundColor = .systemBackground
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 120
        table.keyboardDismissMode = .interactive
        table.allowsSelection = false
        table.register(MessageCell.self, forCellReuseIdentifier: "message")
        table.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
        table.register(UITableViewCell.self, forCellReuseIdentifier: "working")
        context.coordinator.attach(table)
        return table
    }
    func updateUIView(_ table: UITableView, context: Context) {
        let nearBottom = table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom >= table.contentSize.height - 60
        let paddingChanged = abs(table.contentInset.bottom - bottomPadding - 12) > 1
        table.contentInset.bottom = bottomPadding + 12
        table.verticalScrollIndicatorInsets.bottom = bottomPadding
        context.coordinator.update(conversationID: conversationID, snapshot: snapshot, table: table, followBottom: paddingChanged && nearBottom)
    }
    @MainActor final class Coordinator {
        private var source: UITableViewDiffableDataSource<Int, String>?
        private var rows: [String: RemoteTranscriptRow] = [:]
        private var conversationID: String?
        private var expansion: [String: Bool] = [:]
        private var active = false
        private static let workingID = "transcript-working-indicator"
        func attach(_ table: UITableView) {
            source = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
                guard let self else { return UITableViewCell() }
                if id == Self.workingID {
                    let cell = table.dequeueReusableCell(withIdentifier: "working", for: path)
                    cell.contentConfiguration = UIHostingConfiguration {
                        MobileWorkingIndicator().frame(width: 28, height: 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.margins(.horizontal, 16).margins(.vertical, 12)
                    return cell
                }
                guard let row = self.rows[id] else { return UITableViewCell() }
                if let call = row.call {
                    let cell = table.dequeueReusableCell(withIdentifier: "tool", for: path)
                    let binding = Binding(get: { [weak self] in self?.expansion[id] ?? false }, set: { [weak self] value in
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
        func update(conversationID: String?, snapshot: RemoteJSON, table: UITableView, followBottom: Bool) {
            guard let source else { return }
            let changedConversation = self.conversationID != conversationID
            let nearBottom = followBottom || table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom >= table.contentSize.height - 60
            var next: [String: RemoteTranscriptRow] = [:]
            var ids: [String] = []
            for row in RemoteTranscriptRow.project(snapshot) where !row.id.isEmpty && next[row.id] == nil { ids.append(row.id); next[row.id] = row }
            let nextActive = RemoteMessageSubmission.isActive(snapshot)
            if nextActive { ids.append(Self.workingID) }
            guard changedConversation || next != rows || active != nextActive || followBottom else { return }
            active = nextActive
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

@MainActor private final class TranscriptTableView: UITableView {
    private var previousHeight: CGFloat = 0
    private var wasNearBottom = true
    override func layoutSubviews() {
        let resized = previousHeight > 0 && abs(previousHeight - bounds.height) > 1
        super.layoutSubviews()
        if resized, wasNearBottom, !isDragging, !isDecelerating {
            contentOffset.y = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        }
        previousHeight = bounds.height
        wasNearBottom = contentOffset.y + bounds.height - adjustedContentInset.bottom >= contentSize.height - 60
    }
}

@MainActor private final class MessageCell: UITableViewCell, UITextViewDelegate {
    private let text = UITextView()
    private var textWidth: NSLayoutConstraint!
    private var sourceText: String?
    private var markdown = false
    private var isUser = false
    private var blocks: [MarkdownBlock] = []
    private var renderedWidth: CGFloat = 0
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        text.isEditable = false; text.isSelectable = true; text.isScrollEnabled = false
        text.backgroundColor = .clear; text.delegate = self
        text.adjustsFontForContentSizeCategory = true
        text.textContainer.lineFragmentPadding = 0
        text.dataDetectorTypes = []
        text.translatesAutoresizingMaskIntoConstraints = false
        text.layer.cornerRadius = 10
        text.layer.cornerCurve = .continuous
        contentView.addSubview(text)
        textWidth = text.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            textWidth
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: MessageCell, _: UITraitCollection) in
            cell.render(width: max(100, cell.contentView.bounds.width - 32))
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }
    override func prepareForReuse() { super.prepareForReuse(); sourceText = nil; blocks = [] }
    override func layoutSubviews() {
        let width = max(100, contentView.bounds.width - 32)
        if sourceText != nil, abs(width - renderedWidth) > 1 { render(width: width) }
        super.layoutSubviews()
    }
    func configure(_ message: RemoteJSON, width: CGFloat) {
        var content = message["text"].string ?? ""
        if !message["images"].array.isEmpty { content += "\n[Image attachment]" }
        let useMarkdown = message["role"].string == "assistant"
        let user = message["role"].string == "user"
        guard sourceText != content || markdown != useMarkdown || isUser != user else { return }
        sourceText = content; markdown = useMarkdown; isUser = user
        blocks = useMarkdown ? MarkdownDocument.parse(content) : []
        text.backgroundColor = user ? UIColor.systemBlue.withAlphaComponent(0.18) : .clear
        text.textContainerInset = user ? UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12) : .zero
        render(width: width)
    }
    private func render(width: CGFloat) {
        guard let sourceText else { return }
        renderedWidth = max(100, width)
        let attributed = markdown ? UIKitMarkdownText.render(blocks, width: renderedWidth) : NSAttributedString(string: sourceText,
            attributes: [.font:UIFont.preferredFont(forTextStyle: .body), .foregroundColor:UIColor.label])
        if isUser {
            let maximum = renderedWidth * 0.85
            let bounds = attributed.boundingRect(with: CGSize(width: maximum - 24, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            textWidth.constant = min(maximum, max(40, ceil(bounds.width) + 24))
        } else {
            textWidth.constant = renderedWidth
        }
        text.attributedText = attributed
    }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        MarkdownDocument.allowsLink(URL)
    }
}
