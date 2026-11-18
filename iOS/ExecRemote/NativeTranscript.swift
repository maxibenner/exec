import SwiftUI
import UIKit
import ExecRemote
import ExecTranscript

/// UIKit owns virtualization and reuse. Tool rows host the same SwiftUI card as
/// macOS; message rows use selectable TextKit with the shared Markdown parser.
struct NativeTranscript: UIViewControllerRepresentable {
    let conversationID: String?
    let snapshot: RemoteJSON
    let bottomPadding: CGFloat
    let hasEarlier: Bool
    let loadEarlier: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UITableViewController {
        let controller = TranscriptViewController(style: .plain)
        let table = TranscriptTableView(frame: .zero, style: .plain)
        controller.tableView = table
        controller.setContentScrollView(table, for: .top)
        table.backgroundColor = .systemBackground
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 120
        table.keyboardDismissMode = .interactive
        table.allowsSelection = false
        table.register(MessageCell.self, forCellReuseIdentifier: "message")
        table.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
        context.coordinator.attach(table)
        return controller
    }
    func updateUIViewController(_ controller: UITableViewController, context: Context) {
        let table = controller.tableView!
        let nearBottom = table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom >= table.contentSize.height - 60
        let paddingChanged = abs(table.contentInset.bottom - bottomPadding - 12) > 1
        table.contentInset.bottom = bottomPadding + 12
        table.verticalScrollIndicatorInsets.bottom = bottomPadding
        if let table = table as? TranscriptTableView {
            table.hasEarlier = hasEarlier
            table.loadEarlier = loadEarlier
        }
        context.coordinator.update(conversationID: conversationID, snapshot: snapshot, table: table, followBottom: paddingChanged && nearBottom)
    }
    @MainActor final class Coordinator {
        private var source: UITableViewDiffableDataSource<Int, String>?
        private var rows: [String: RemoteTranscriptRow] = [:]
        private var conversationID: String?
        private var expansion: [String: Bool] = [:]
        func attach(_ table: UITableView) {
            source = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
                guard let self else { return UITableViewCell() }
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
                        MobileToolCard(call: call, result: row.message, awaitingApproval: row.awaitingApproval,
                                       isRunning: row.isRunning, roundsTop: row.roundsTop, roundsBottom: row.roundsBottom,
                                       expanded: binding)
                    }.margins(.horizontal, 16)
                        .margins(.top, row.roundsTop ? 6 : 0)
                        .margins(.bottom, row.roundsBottom ? 6 : 0)
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
            guard changedConversation || next != rows || followBottom else { return }
            let previousIDs = Set(source.snapshot().itemIdentifiers)
            let firstOld = source.snapshot().itemIdentifiers.first
            let prepending = !changedConversation && firstOld.map { ids.first != $0 && ids.contains($0) } == true
            let anchor = prepending ? table.indexPathsForVisibleRows?.min().flatMap { source.itemIdentifier(for: $0) } ?? firstOld : nil
            let oldPosition = anchor.flatMap { source.indexPath(for: $0) }
                .map { table.rectForRow(at: $0).minY - table.contentOffset.y }
            let changed = ids.filter { previousIDs.contains($0) && next[$0] != rows[$0] }
            if changedConversation { expansion.removeAll() }
            else { expansion = expansion.filter { next[$0.key] != nil } }
            rows = next; self.conversationID = conversationID
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0]); snapshot.appendItems(ids)
            snapshot.reconfigureItems(changed)
            source.apply(snapshot, animatingDifferences: false) {
                if let anchor, let oldPosition, let path = source.indexPath(for: anchor) {
                    table.layoutIfNeeded()
                    table.contentOffset.y = table.rectForRow(at: path).minY - oldPosition
                    return
                }
                guard changedConversation || nearBottom, !ids.isEmpty, !table.isDragging, !table.isDecelerating else { return }
                (table as? TranscriptTableView)?.followBottom()
            }
        }
    }
}

/// The navigation item belongs to SwiftUI's hosting controller, not this child.
/// Register the actual underlapping scroll view with that owner; leave the bar's
/// appearance and scroll-edge effect entirely to UIKit.
@MainActor private final class TranscriptViewController: UITableViewController {
    private weak var navigationOwner: UIViewController?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let owner = navigationController?.topViewController, owner !== navigationOwner else { return }
        navigationOwner = owner
        owner.setContentScrollView(tableView, for: .top)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        navigationOwner?.setContentScrollView(nil, for: .top)
        navigationOwner = nil
    }
}

private struct MobileToolCard: View {
    let call: RemoteJSON
    let result: RemoteJSON
    let awaitingApproval: Bool
    let isRunning: Bool
    let roundsTop: Bool
    let roundsBottom: Bool
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
        ToolCard(presentation: presentation, isExpanded: $expanded, awaitingApproval: awaitingApproval,
                 isRunning: isRunning, roundsTop: roundsTop, roundsBottom: roundsBottom) {
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
    var hasEarlier = false
    var loadEarlier: (() -> Void)?
    private var requestedEarlier = false
    private var previousHeight: CGFloat = 0
    private var previousContentHeight: CGFloat = 0
    private var previousBottomInset: CGFloat = 0
    private var wasNearBottom = true
    private var needsBottomAlignment = false
    private var nearBottom: Bool {
        contentOffset.y + bounds.height - adjustedContentInset.bottom >= contentSize.height - 60
    }
    override var contentOffset: CGPoint {
        didSet {
            // User scrolling takes priority over following new content, including
            // deceleration. Programmatic size corrections don't change intent.
            if isTracking || isDragging || isDecelerating { wasNearBottom = nearBottom }
            if contentOffset.y > -adjustedContentInset.top + 250 { requestedEarlier = false }
            if (isTracking || isDragging), hasEarlier, !requestedEarlier,
               contentOffset.y < -adjustedContentInset.top + 120 {
                requestedEarlier = true
                loadEarlier?()
            }
        }
    }
    func followBottom() {
        wasNearBottom = true
        needsBottomAlignment = true
        setNeedsLayout()
        layoutIfNeeded()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let geometryChanged = abs(previousHeight - bounds.height) > 1
            || abs(previousContentHeight - contentSize.height) > 1
            || abs(previousBottomInset - adjustedContentInset.bottom) > 1
        // Self-sizing cells can resolve over several layout passes, after a
        // diffable update completes. Follow those changes as well as keyboard
        // and composer resizing, keeping the last row above the composer.
        if (geometryChanged || needsBottomAlignment), wasNearBottom,
           !isTracking, !isDragging, !isDecelerating {
            let bottom = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
            if abs(contentOffset.y - bottom) > 1 { contentOffset.y = bottom }
        }
        needsBottomAlignment = false
        previousHeight = bounds.height
        previousContentHeight = contentSize.height
        previousBottomInset = adjustedContentInset.bottom
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
