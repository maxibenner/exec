import SwiftUI
import UIKit
import ExecRemote

/// UIKit owns row virtualization, reuse and self-sizing. Only mounted cells have
/// text views; conversation state stays outside the scroll surface.
struct NativeTranscript: UIViewRepresentable {
    let conversationID: String?
    let messages: [RemoteJSON]
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
        context.coordinator.attach(table)
        return table
    }
    func updateUIView(_ table: UITableView, context: Context) {
        context.coordinator.update(conversationID: conversationID, messages: messages, table: table)
    }
    @MainActor final class Coordinator {
        private var source: UITableViewDiffableDataSource<Int, String>?
        private var rows: [String:RemoteJSON] = [:]
        private var conversationID: String?
        func attach(_ table: UITableView) {
            source = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
                guard let cell = table.dequeueReusableCell(withIdentifier: "message", for: path) as? MessageCell else { return UITableViewCell() }
                if let row = self?.rows[id] { cell.configure(row) }
                return cell
            }
        }
        func update(conversationID: String?, messages: [RemoteJSON], table: UITableView) {
            guard let source else { return }
            let changedConversation = self.conversationID != conversationID
            let nearBottom = table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom >= table.contentSize.height - 60
            var next: [String:RemoteJSON] = [:]
            var ids: [String] = []
            for row in messages where !row.id.isEmpty && next[row.id] == nil { ids.append(row.id); next[row.id] = row }
            guard changedConversation || next != rows else { return }
            let previousIDs = Set(source.snapshot().itemIdentifiers)
            let changed = ids.filter { previousIDs.contains($0) && next[$0] != rows[$0] }
            rows = next; self.conversationID = conversationID
            var snapshot = NSDiffableDataSourceSnapshot<Int,String>()
            snapshot.appendSections([0]); snapshot.appendItems(ids)
            if !changedConversation { snapshot.reconfigureItems(changed) }
            source.apply(snapshot, animatingDifferences: false) {
                guard changedConversation || nearBottom, !ids.isEmpty, !table.isDragging, !table.isDecelerating else { return }
                table.layoutIfNeeded()
                table.scrollToRow(at: IndexPath(row: ids.count - 1, section: 0), at: .bottom, animated: false)
            }
        }
    }
}

@MainActor private final class MessageCell: UITableViewCell, UITextViewDelegate {
    private let role = UILabel()
    private let text = UITextView()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        role.font = .preferredFont(forTextStyle: .caption1)
        role.adjustsFontForContentSizeCategory = true
        role.textColor = .secondaryLabel
        text.isEditable = false; text.isSelectable = true; text.isScrollEnabled = false
        text.backgroundColor = .clear; text.delegate = self
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = .zero; text.textContainer.lineFragmentPadding = 0
        text.dataDetectorTypes = [.link]
        let stack = UIStackView(arrangedSubviews: [role, text])
        stack.axis = .vertical; stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }
    func configure(_ message: RemoteJSON) {
        role.text = message["role"].string?.capitalized ?? "Message"
        var content = message["text"].string ?? ""
        let calls = message["calls"].array.compactMap { $0["name"].string }
        if !calls.isEmpty { content += (content.isEmpty ? "" : "\n") + calls.joined(separator: " · ") }
        if let outcome = message["outcome"].string { content += "\n[\(outcome)]" }
        if !message["images"].array.isEmpty { content += "\n[Image attachment]" }
        // Do not reset selection or text layout for an unchanged reused row.
        if text.text != content { text.text = content }
        text.font = message["role"].string == "tool" ? .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular) : .preferredFont(forTextStyle: .body)
    }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        ["https", "http"].contains(URL.scheme?.lowercased() ?? "")
    }
}
