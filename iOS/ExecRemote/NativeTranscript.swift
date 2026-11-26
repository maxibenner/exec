import SwiftUI
import UIKit
import ExecRemote
import ExecTranscript

enum AppColors {
    // Match the Mac app's fixed iMessage blue, independent of system accent/appearance.
    static let nativeBlue = UIColor(red: 0, green: 122.0 / 255.0, blue: 1, alpha: 1)
    static let blue = Color(uiColor: nativeBlue)
}

/// UIKit owns virtualization and reuse. One host measures each adjacent tool
/// group; message rows use selectable TextKit with the shared Markdown parser.
struct NativeTranscript: UIViewControllerRepresentable {
    let conversationID: String?
    let snapshot: RemoteJSON
    let showsThinkingIndicator: Bool
    let descriptiveShellTitles: Bool
    let viewState: TranscriptViewState?
    let saveViewState: (String, TranscriptViewState) -> Void
    let bottomPadding: CGFloat
    let hasEarlier: Bool
    let isLoadingEarlier: Bool
    let loadEarlier: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UITableViewController {
        let controller = TranscriptViewController(style: .plain)
        let table = TranscriptTableView(frame: .zero, style: .plain)
        controller.tableView = table
        controller.setContentScrollView(table, for: .top)
        table.accessibilityIdentifier = "native-transcript"
        table.backgroundColor = .systemBackground
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.selfSizingInvalidation = .enabledIncludingConstraints
        table.estimatedRowHeight = 120
        table.keyboardDismissMode = .interactive
        table.allowsSelection = false
        let coordinator = context.coordinator
        coordinator.attach(table, saveViewState: saveViewState)
        controller.saveViewState = { [weak coordinator, weak table] in
            guard let table else { return }
            coordinator?.savePresentation(table)
        }
        return controller
    }
    func updateUIViewController(_ controller: UITableViewController, context: Context) {
        guard let table = controller.tableView as? TranscriptTableView else { return }
        table.contentInset.bottom = bottomPadding + 12
        table.verticalScrollIndicatorInsets.bottom = bottomPadding
        table.configureEarlierHistory(conversationID: conversationID, hasEarlier: hasEarlier,
                                      isLoadingEarlier: isLoadingEarlier, loadEarlier: loadEarlier)
        context.coordinator.update(conversationID: conversationID, snapshot: snapshot,
                                   showsThinkingIndicator: showsThinkingIndicator, descriptiveShellTitles: descriptiveShellTitles,
                                   viewState: viewState, table: table)
    }
    static func dismantleUIViewController(_ controller: UITableViewController, coordinator: Coordinator) {
        if let table = controller.tableView as? TranscriptTableView { coordinator.detach(table) }
    }
    @MainActor final class Coordinator: NSObject, UITableViewDelegate {
        private struct Update {
            let conversationID: String?
            let snapshot: RemoteJSON
            let showsThinkingIndicator: Bool
            let descriptiveShellTitles: Bool
            let viewState: TranscriptViewState?
        }
        private var source: UITableViewDiffableDataSource<Int, String>?
        private var items: [String: TranscriptItem] = [:]
        private var itemForRow: [String: String] = [:]
        private var toolFrames: [String: (group: String, frame: CGRect)] = [:]
        private var measuredHeights: [String: CGFloat] = [:]
        private var measuredWidth: CGFloat = 0
        private var measuredCategory: UIContentSizeCategory?
        private var conversationID: String?
        private var descriptiveShellTitles = false
        private var expansion: [String: Bool] = [:]
        private var hasSnapshot = false
        private var currentUpdate: Update?
        private var pendingUpdate: Update?
        private var dirtyGroups: Set<String> = []
        private var scheduled = false
        private var applying = false
        private var attached = false
        private var presentation: TranscriptViewState?
        private var saveViewState: ((String, TranscriptViewState) -> Void)?

        func attach(_ table: TranscriptTableView, saveViewState: @escaping (String, TranscriptViewState) -> Void) {
            table.register(MessageCell.self, forCellReuseIdentifier: "message")
            table.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
            attached = true
            self.saveViewState = saveViewState
            table.delegate = self
            table.prepareInitialRows = { [weak self, weak table] in
                guard let self, let table else { return }
                self.primeInitialPosition(table)
            }
            table.didChangeViewState = { [weak self, weak table] in
                guard let table else { return }
                self?.savePresentation(table)
            }
            table.rowTop = { [weak self, weak table] id in
                guard let self, let table else { return nil }
                return self.rowTop(id, table: table)
            }
            table.turnTop = { [weak self, weak table] id in
                guard let self, let table, let top = self.rowTop(id, table: table) else { return nil }
                // Pin the visible bubble, not its table cell's extra top margin.
                return top + MessageCell.verticalContentInset
            }
            table.readingPosition = { [weak self, weak table] in
                guard let self, let table else { return nil }
                return self.readingPosition(table)
            }
            table.didLayoutRows = { [weak self, weak table] in
                guard let self, let table, table.bounds.width > 0 else { return }
                if self.measuredWidth != table.bounds.width || self.measuredCategory != table.traitCollection.preferredContentSizeCategory {
                    self.measuredHeights.removeAll()
                    self.measuredWidth = table.bounds.width
                    self.measuredCategory = table.traitCollection.preferredContentSizeCategory
                }
                for path in table.indexPathsForVisibleRows ?? [] {
                    if let id = self.source?.itemIdentifier(for: path), let cell = table.cellForRow(at: path),
                       self.measuredHeights[id] != cell.bounds.height {
                        self.measuredHeights[id] = cell.bounds.height
                    }
                }
            }
            table.finishedFollowing = { [weak self, weak table] in
                guard let self, let table, self.pendingUpdate != nil || !self.dirtyGroups.isEmpty else { return }
                self.scheduleUpdate(table)
            }
            source = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
                guard let self, let item = self.items[id] else { return UITableViewCell() }
                if item.isToolGroup {
                    let cell = table.dequeueReusableCell(withIdentifier: "tool", for: path)
                    cell.accessibilityIdentifier = "transcript-tools-\(id)"
                    let descriptiveShellTitles = self.descriptiveShellTitles
                    let bindings = Dictionary(uniqueKeysWithValues: item.rows.map { ($0.id, self.binding($0.id, table: table)) })
                    let measured: (String, CGRect) -> Void = { [weak self, weak table] rowID, frame in
                        guard let self, self.itemForRow[rowID] == id else { return }
                        self.toolFrames[rowID] = (id, frame)
                        (table as? TranscriptTableView)?.scheduleAlignment()
                    }
                    cell.contentConfiguration = UIHostingConfiguration {
                        // One uninterrupted background, not N translucent fills or
                        // individually rounded/self-sized UIKit hosting surfaces.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(item.rows, id: \.id) { row in
                                MobileToolCard(call: row.call!, result: row.message, awaitingApproval: row.awaitingApproval,
                                               isRunning: row.isRunning, descriptiveShellTitles: descriptiveShellTitles,
                                               expanded: bindings[row.id]!)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tool-group")) } action: { frame in
                                        measured(row.id, frame)
                                    }
                            }
                        }
                        .coordinateSpace(name: "tool-group")
                        .fixedSize(horizontal: false, vertical: true)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    }.margins(.horizontal, 16).margins(.vertical, 6)
                    return cell
                }
                guard let cell = table.dequeueReusableCell(withIdentifier: "message", for: path) as? MessageCell else { return UITableViewCell() }
                cell.accessibilityIdentifier = "transcript-message-\(id)"
                cell.configure(item.rows[0].message, width: TranscriptMessageStyle.contentWidth(in: table.bounds.width))
                return cell
            }
        }
        private func binding(_ rowID: String, table: UITableView) -> Binding<Bool> {
            Binding(get: { [weak self] in self?.expansion[rowID] ?? false }, set: { [weak self, weak table] value in
                guard let table = table as? TranscriptTableView else { return }
                self?.setExpanded(value, rowID: rowID, table: table)
            })
        }
        func setExpanded(_ value: Bool, rowID: String, table: TranscriptTableView) {
            guard let group = itemForRow[rowID], (expansion[rowID] ?? false) != value else { return }
            table.beginDisclosure(rowID: rowID)
            expansion[rowID] = value
            dirtyGroups.insert(group)
            scheduleUpdate(table)
        }
        func update(conversationID: String?, snapshot: RemoteJSON,
                    showsThinkingIndicator: Bool, descriptiveShellTitles: Bool,
                    viewState: TranscriptViewState?, table: TranscriptTableView) {
            pendingUpdate = Update(conversationID: conversationID, snapshot: snapshot,
                                   showsThinkingIndicator: showsThinkingIndicator,
                                   descriptiveShellTitles: descriptiveShellTitles, viewState: viewState)
            scheduleUpdate(table)
        }
        private func scheduleUpdate(_ table: TranscriptTableView) {
            guard attached, !scheduled, !applying, !table.animatingScroll else { return }
            scheduled = true
            // Streaming snapshots and disclosure changes arriving before the next
            // run-loop turn share one diffable/self-sizing update.
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table else { return }
                self.scheduled = false
                self.applyUpdate(table)
            }
        }
        private func applyUpdate(_ table: TranscriptTableView) {
            guard attached, !table.animatingScroll, let source, let update = pendingUpdate ?? currentUpdate else { return }
            pendingUpdate = nil
            let changedConversation = conversationID != update.conversationID || presentation?.generation != update.viewState?.generation
            let changedDisplay = descriptiveShellTitles != update.descriptiveShellTitles
            let projected = TranscriptItem.project(update.snapshot)
            let next = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
            let dirty = dirtyGroups
            dirtyGroups.removeAll()
            let validSnapshot = update.snapshot["id"].string == update.conversationID && update.conversationID != nil
            guard changedConversation || changedDisplay || currentUpdate?.showsThinkingIndicator != update.showsThinkingIndicator
                    || next != items || !dirty.isEmpty || (!hasSnapshot && validSnapshot) else { return }
            applying = true
            if changedConversation {
                savePresentation(table)
                table.resetScroll()
                expansion.removeAll(); toolFrames.removeAll(); measuredHeights.removeAll(); hasSnapshot = false
                presentation = update.viewState
            }
            let initial = changedConversation || currentUpdate == nil
            let opening = changedConversation || !table.hasPresentedContent
            currentUpdate = update
            table.beginContentUpdate()
            table.setThinkingIndicator(update.showsThinkingIndicator)
            let rows = projected.flatMap(\.rows)
            if initial {
                presentation = update.viewState
                expansion = presentation?.expansion ?? [:]
                measuredHeights = presentation?.rowHeights ?? [:]
                measuredWidth = presentation?.layoutWidth ?? 0
                measuredCategory = presentation.flatMap {
                    $0.contentSizeCategory.isEmpty ? nil : UIContentSizeCategory(rawValue: $0.contentSizeCategory)
                }
                table.restorePresentation(presentation, rows: rows)
            } else if validSnapshot && !hasSnapshot {
                // The first real history establishes the scroll baseline.
                table.scrollState.restoreRows(rows)
            } else {
                _ = table.scrollState.update(rows: rows)
            }
            hasSnapshot = hasSnapshot || validSnapshot
            let previousIDs = Set(source.snapshot().itemIdentifiers)
            let changed = projected.filter {
                previousIDs.contains($0.id) && ($0 != items[$0.id] || dirty.contains($0.id) || (changedDisplay && $0.isToolGroup))
            }.map(\.id)
            items = next
            itemForRow = Dictionary(uniqueKeysWithValues: projected.flatMap { item in item.rows.map { ($0.id, item.id) } })
            expansion = expansion.filter { itemForRow[$0.key] != nil }
            toolFrames = toolFrames.filter { itemForRow[$0.key] == $0.value.group }
            measuredHeights = measuredHeights.filter { next[$0.key] != nil }
            conversationID = update.conversationID
            descriptiveShellTitles = update.descriptiveShellTitles
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0]); snapshot.appendItems(projected.map(\.id))
            snapshot.reconfigureItems(changed)
            source.apply(snapshot, animatingDifferences: false) { [weak self, weak table] in
                guard let self, let table, self.attached else { return }
                self.applying = false
                table.finishContentUpdate(initial: opening, ready: self.hasSnapshot)
                if self.pendingUpdate != nil || !self.dirtyGroups.isEmpty { self.scheduleUpdate(table) }
            }
        }
        func savePresentation(_ table: TranscriptTableView) {
            guard attached, hasSnapshot, table.hasPresentedContent, !table.updatingContent,
                  let id = conversationID, var value = presentation else { return }
            value.anchor = table.captureReadingPosition()
            value.scrollState = table.scrollState
            value.expansion = expansion
            value.rowHeights = measuredHeights
            value.layoutWidth = measuredWidth
            value.contentSizeCategory = measuredCategory?.rawValue ?? ""
            presentation = value
            saveViewState?(id, value)
        }
        func detach(_ table: TranscriptTableView) {
            savePresentation(table)
            attached = false
            pendingUpdate = nil; currentUpdate = nil; source = nil; saveViewState = nil
            table.stopEarlierHistory()
            table.delegate = nil
        }
        private func primeInitialPosition(_ table: TranscriptTableView) {
            guard let source, table.bounds.width > 0, table.bounds.height > 0 else { return }
            let row = table.restorationRowID
            guard let id = row.flatMap({ itemForRow[$0] }) ?? source.snapshot().itemIdentifiers.last,
                  let path = source.indexPath(for: id) else { return }
            // Materialize the anchor's cell/tool group before resolving its internal
            // geometry. Cached heights keep the initial table estimate consistent.
            UIView.performWithoutAnimation {
                table.layoutIfNeeded()
                table.scrollToRow(at: path, at: row == nil ? .bottom : .top, animated: false)
                table.layoutIfNeeded()
            }
        }
        private func rowTop(_ rowID: String, table: UITableView) -> CGFloat? {
            guard let itemID = itemForRow[rowID], let item = items[itemID], let path = source?.indexPath(for: itemID) else { return nil }
            let top = table.rectForRow(at: path).minY
            guard item.isToolGroup else { return top }
            if let measured = toolFrames[rowID], measured.group == itemID { return top + 6 + measured.frame.minY }
            return rowID == itemID ? top + 6 : nil
        }
        private func readingPosition(_ table: UITableView) -> TranscriptViewportAnchor? {
            let top = table.contentOffset.y + table.adjustedContentInset.top
            for path in (table.indexPathsForVisibleRows ?? []).sorted() {
                guard let id = source?.itemIdentifier(for: path), let item = items[id], table.rectForRow(at: path).maxY > top else { continue }
                for row in item.rows {
                    guard let y = rowTop(row.id, table: table) else { continue }
                    let height = toolFrames[row.id]?.frame.height ?? table.rectForRow(at: path).height
                    if y + height > top { return TranscriptViewportAnchor(rowID: row.id, offset: y - top) }
                }
            }
            return nil
        }
        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            // Reapplying a streaming snapshot must not replace known offscreen
            // heights with 120pt guesses and shift the turn's top on every pass.
            source?.itemIdentifier(for: indexPath).flatMap { measuredHeights[$0] } ?? 120
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { (scrollView as? TranscriptTableView)?.beginReaderScroll() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { (scrollView as? TranscriptTableView)?.readerDidScroll() }
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            (scrollView as? TranscriptTableView)?.setReaderDirection(velocity.y)
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { (scrollView as? TranscriptTableView)?.endReaderScroll() }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { (scrollView as? TranscriptTableView)?.endReaderScroll() }
    }
}

/// The navigation item belongs to SwiftUI's hosting controller, not this child.
/// Register the actual underlapping scroll view with that owner; leave the bar's
/// appearance and scroll-edge effect entirely to UIKit.
@MainActor private final class TranscriptViewController: UITableViewController {
    private weak var navigationOwner: UIViewController?
    var saveViewState: (() -> Void)?
    override func viewWillDisappear(_ animated: Bool) {
        saveViewState?()
        super.viewWillDisappear(animated)
    }
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
    let descriptiveShellTitles: Bool
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
        return ToolPresentation(name: call["name"].string ?? "Tool", arguments: arguments, result: display,
                                descriptiveShellTitles: descriptiveShellTitles)
    }
    var body: some View {
        let presentation = presentation
        ToolCard(presentation: presentation, isExpanded: $expanded, awaitingApproval: awaitingApproval,
                 isRunning: isRunning, showsBackground: false) {
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

@MainActor final class TranscriptTableView: UITableView {
    private var hasEarlier = false
    private var isLoadingEarlier = false
    private var loadEarlier: (() -> Void)?
    private var pagingConversationID: String?
    private var requestedEarlier = false
    private let earlierRefreshControl = UIRefreshControl()
    var rowTop: ((String) -> CGFloat?)?
    var turnTop: ((String) -> CGFloat?)?
    var readingPosition: (() -> TranscriptViewportAnchor?)?
    var didLayoutRows: (() -> Void)?
    var finishedFollowing: (() -> Void)?
    var prepareInitialRows: (() -> Void)?
    var didChangeViewState: (() -> Void)?
    var scrollState = TranscriptScrollState()
    var updatingContent = false
    private(set) var hasPresentedContent = false
    private var contentReady = false
    private var suppressOpeningAnimation = true
    var restorationRowID: String? {
        switch scrollState.intent {
        case .reading: readingAnchor?.rowID
        case .turn(let id): id
        case .latest: nil
        }
    }
    private var readingAnchor: TranscriptViewportAnchor?
    private var restoringReadingAnchor = false
    private var previousSize = CGSize.zero
    private var previousContentHeight: CGFloat = 0
    private var previousInsets = UIEdgeInsets.zero
    private var alignmentNeeded = false
    private var alignmentScheduled = false
    private var immediateAlignment = true
    private var settling = false
    private var correctingOffset = false
    private var scrollAnimator: UIViewPropertyAnimator?
    private var revealAnimator: UIViewPropertyAnimator?
    var animatingScroll: Bool { scrollAnimator != nil }
    private var readerActive = false
    private var readerDirection: CGFloat = 0
    private var readerTranslation: CGFloat = 0
    private var readerContentSize = CGSize.zero
    private var readerViewportSize = CGSize.zero
    private var readerInsets = UIEdgeInsets.zero
    private var thinkingView: UIView?
    private var thinkingHeight: CGFloat { thinkingView == nil ? 0 : 36 }
    private var lastReaderOffset: CGFloat = 0
    private var reduceMotion: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--transcript-reduce-motion") { return true }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }

    override init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: style)
        alwaysBounceVertical = true
        earlierRefreshControl.accessibilityIdentifier = "transcript-earlier-refresh"
        earlierRefreshControl.accessibilityLabel = "Loading earlier messages"
        earlierRefreshControl.addTarget(self, action: #selector(pulledEarlierHistory), for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(motionPolicyChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:style:)") }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Only UIRefreshControl's native pull gesture emits valueChanged. Neither
    /// beginRefreshing(), reaching the top, nor layout/offset changes request data.
    @objc func pulledEarlierHistory() {
        guard earlierRefreshControl.isRefreshing else { return }
        guard hasEarlier, !isLoadingEarlier, !requestedEarlier, let loadEarlier else {
            if !isLoadingEarlier && !requestedEarlier { earlierRefreshControl.endRefreshing() }
            return
        }
        requestedEarlier = true // Close the gap before the store publishes loading.
        scrollState.readerScrolled(towardLatest: false, atBottom: false)
        if let anchor = readingAnchor ?? readingPosition?() {
            // Native refresh expands adjustedContentInset before valueChanged.
            // Use the reading anchor from before that expansion, not a later row
            // now reported beneath the spinner's extra inset.
            readingAnchor = TranscriptViewportAnchor(rowID: anchor.rowID, offset: min(0, anchor.offset))
        }
        loadEarlier()
    }

    func configureEarlierHistory(conversationID: String?, hasEarlier: Bool,
                                 isLoadingEarlier: Bool, loadEarlier: @escaping () -> Void) {
        let changedConversation = pagingConversationID != conversationID
        if changedConversation { stopEarlierHistory() }
        pagingConversationID = conversationID
        let completed = self.isLoadingEarlier && !isLoadingEarlier
        let exhausted = !hasEarlier && (self.hasEarlier || requestedEarlier)
        self.hasEarlier = hasEarlier
        self.isLoadingEarlier = isLoadingEarlier
        self.loadEarlier = loadEarlier
        if completed || (exhausted && !isLoadingEarlier) {
            requestedEarlier = false
            earlierRefreshControl.endRefreshing()
            restoringReadingAnchor = scrollState.intent == .reading && readingAnchor != nil
            scheduleAlignment(immediate: true)
        }
        // Keep an active control until its request finishes, even if that page
        // exhausts history. No refresh control is needed once history is complete.
        let enabled = conversationID != nil && (hasEarlier || isLoadingEarlier || requestedEarlier)
        if enabled && refreshControl == nil { refreshControl = earlierRefreshControl }
        if !enabled && refreshControl != nil { refreshControl = nil }
        // External loading does not synthesize a pull or move the viewport.
        if isLoadingEarlier && !earlierRefreshControl.isRefreshing {
            earlierRefreshControl.beginRefreshing()
        }
    }

    func stopEarlierHistory() {
        requestedEarlier = false
        isLoadingEarlier = false
        hasEarlier = false
        loadEarlier = nil
        earlierRefreshControl.endRefreshing()
        refreshControl = nil
    }

    func resetScroll() {
        cancelScrollAnimation()
        finishContentReveal()
        scrollState = TranscriptScrollState()
        readingAnchor = nil
        restoringReadingAnchor = false
        thinkingView?.removeFromSuperview()
        thinkingView = nil
        tableFooterView = nil
        immediateAlignment = true
        suppressOpeningAnimation = true
        hasPresentedContent = false
        contentReady = false
        UIView.performWithoutAnimation { alpha = 0 }
    }
    func restorePresentation(_ value: TranscriptViewState?, rows: [RemoteTranscriptRow]) {
        scrollState = value?.scrollState ?? TranscriptScrollState()
        scrollState.restoreRows(rows)
        readingAnchor = value?.anchor
        if scrollState.intent == .reading,
           !rows.contains(where: { $0.id == readingAnchor?.rowID }) {
            scrollState = TranscriptScrollState()
            scrollState.restoreRows(rows)
            readingAnchor = nil
        }
        restoringReadingAnchor = scrollState.intent == .reading && readingAnchor != nil
    }
    func captureReadingPosition() -> TranscriptViewportAnchor? {
        cancelScrollAnimation()
        return readingPosition?() ?? readingAnchor
    }
    func beginContentUpdate() {
        if readingAnchor == nil { rememberReadingPosition() }
        restoringReadingAnchor = scrollState.intent == .reading && readingAnchor != nil
        updatingContent = true
    }
    func finishContentUpdate(initial: Bool, ready: Bool) {
        updatingContent = false
        contentReady = ready
        if !initial { suppressOpeningAnimation = false }
        if scrollState.intent != .reading { restoringReadingAnchor = false }
        scheduleAlignment(immediate: initial)
        // Paging must compensate before the next frame, even with a finger still
        // down. This is an anchor correction, never a follow animation.
        if restoringReadingAnchor { alignViewport() }
    }
    func rememberReadingPosition() {
        // Refresh inset expansion and rubber-band rebound are not a new reading
        // position. Keep the pre-page row anchor until the native spinner ends.
        guard !earlierRefreshControl.isRefreshing else { return }
        if !restoringReadingAnchor, scrollState.intent == .reading, let anchor = readingPosition?() { readingAnchor = anchor }
    }
    /// Capture the disclosed header before SwiftUI/self-sizing changes its group.
    /// Collapse also stays in reading mode; clamping a shorter document is not
    /// an explicit request to follow subsequent output.
    func beginDisclosure(rowID: String) {
        cancelScrollAnimation()
        readerActive = false
        scrollState.disclosedTool()
        if let top = rowTop?(rowID) {
            readingAnchor = TranscriptViewportAnchor(rowID: rowID,
                offset: top - contentOffset.y - adjustedContentInset.top)
        } else { readingAnchor = readingPosition?() }
        restoringReadingAnchor = readingAnchor != nil
        scheduleAlignment(immediate: true)
    }
    func setThinkingIndicator(_ visible: Bool) {
        guard visible != (thinkingView != nil) else { return }
        if visible {
            // Explicit sRGB iMessage blue, never a semantic/system accent.
            let blue = AppColors.nativeBlue
            let view = UIHostingConfiguration {
                MobileWorkingIndicator(tintColor: blue)
            }.margins(.all, 0).makeContentView()
            view.frame = CGRect(x: 16, y: 10, width: 28, height: 16)
            view.accessibilityIdentifier = "transcript-thinking"
            let footer = tableFooterView ?? UIView()
            footer.addSubview(view)
            thinkingView = view
            tableFooterView = footer
            if !reduceMotion {
                view.alpha = 0
                UIView.animate(withDuration: 0.4) { view.alpha = 1 }
            }
        } else {
            thinkingView?.removeFromSuperview()
            thinkingView = nil
        }
        scheduleAlignment()
    }
    func beginReaderScroll() {
        cancelScrollAnimation()
        readerActive = true
        readerDirection = 0
        lastReaderOffset = contentOffset.y
        readerTranslation = panGestureRecognizer.translation(in: self).y
        readerContentSize = contentSize
        readerViewportSize = bounds.size
        readerInsets = adjustedContentInset
        scrollState.readerScrolled(towardLatest: false, atBottom: false)
        rememberReadingPosition()
    }
    func setReaderDirection(_ velocity: CGFloat) {
        if velocity != 0 { readerDirection = velocity > 0 ? 1 : -1 }
    }
    func readerDidScroll() {
        guard readerActive, !correctingOffset, !updatingContent, isDragging || isDecelerating else { return }
        let delta = contentOffset.y - lastReaderOffset
        lastReaderOffset = contentOffset.y
        let translation = panGestureRecognizer.translation(in: self).y
        let movedFinger = abs(translation - readerTranslation) > 0.1
        let geometryChanged = readerContentSize != contentSize || readerViewportSize != bounds.size
            || readerInsets != adjustedContentInset
        readerTranslation = translation
        readerContentSize = contentSize
        readerViewportSize = bounds.size
        readerInsets = adjustedContentInset
        guard !geometryChanged else { return }
        if isDragging {
            guard movedFinger else { return }
            setReaderDirection(-panGestureRecognizer.velocity(in: self).y)
        }
        guard abs(delta) > 0.1, readerDirection != 0 else { return }
        let bottom = TranscriptScrollGeometry.bottom(contentHeight: contentSize.height, viewportHeight: bounds.height,
                                                       topInset: adjustedContentInset.top, bottomInset: adjustedContentInset.bottom)
        // Keep the gesture's direction through momentum/rubber-band rebound.
        // Neither a layout callback nor merely being near the bottom opts in.
        scrollState.readerScrolled(towardLatest: readerDirection > 0, atBottom: contentOffset.y >= bottom - 2)
        if restoringReadingAnchor, let anchor = readingAnchor {
            readingAnchor = TranscriptViewportAnchor(rowID: anchor.rowID, offset: anchor.offset - delta)
        } else { rememberReadingPosition() }
    }
    func endReaderScroll() {
        readerActive = false
        if !immediateAlignment { rememberReadingPosition() }
        scheduleAlignment()
        didChangeViewState?()
    }
    private func finishedScrollAnimation() {
        scrollAnimator = nil
        didChangeViewState?()
        scheduleAlignment()
        finishedFollowing?()
    }
    private func cancelScrollAnimation() {
        guard let animator = scrollAnimator else { return }
        // UIKit keeps the model bounds at the target during this short motion.
        // Rebase to the displayed position before handing control to a reader.
        let displayed = layer.presentation()?.bounds.origin ?? contentOffset
        animator.stopAnimation(true)
        scrollAnimator = nil
        correctingOffset = true
        setContentOffset(displayed, animated: false)
        correctingOffset = false
        finishedFollowing?()
    }
    @objc private func motionPolicyChanged() {
        if UIAccessibility.isReduceMotionEnabled {
            finishContentReveal()
            scheduleAlignment(immediate: true)
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelScrollAnimation()
            finishContentReveal()
        } else { scheduleAlignment(immediate: true) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        didLayoutRows?()
        let viewportChanged = previousSize != bounds.size || previousInsets != adjustedContentInset
        let contentChanged = abs(previousContentHeight - contentSize.height) > 0.5
        previousSize = bounds.size
        previousInsets = adjustedContentInset
        previousContentHeight = contentSize.height
        // Self-sizing can produce several layouts per snapshot. Never jump from
        // inside layout; consume the final geometry once on the main queue.
        if viewportChanged || contentChanged { scheduleAlignment(immediate: viewportChanged) }
    }
    func scheduleAlignment(immediate: Bool = false) {
        alignmentNeeded = true
        immediateAlignment = immediateAlignment || immediate || suppressOpeningAnimation
        guard !alignmentScheduled, !settling, !updatingContent, !animatingScroll || immediate else { return }
        alignmentScheduled = true
        DispatchQueue.main.async { [weak self] in self?.alignViewport() }
    }
    private func alignViewport() {
        alignmentScheduled = false
        guard !(requestedEarlier && earlierRefreshControl.isRefreshing),
              alignmentNeeded, contentReady, !updatingContent,
              restoringReadingAnchor || (!isTracking && !isDragging && !isDecelerating),
              window != nil, bounds.height > 0 else { return }
        settling = true
        defer {
            settling = false
            if alignmentNeeded { scheduleAlignment() }
        }
        if !hasPresentedContent { prepareInitialRows?() }
        layoutIfNeeded()
        updateResponseReservation()
        layoutIfNeeded()
        if immediateAlignment || reduceMotion { cancelScrollAnimation() }
        guard !animatingScroll else { return }
        alignmentNeeded = false
        guard let y = resolvedOffset() else { return }
        let animate = hasPresentedContent && !suppressOpeningAnimation
            && TranscriptScrollGeometry.shouldAnimate(initial: false, geometryChanged: immediateAlignment,
                                                       reduceMotion: reduceMotion)
            && scrollState.intent != .reading && abs(contentOffset.y - y) > 0.5
        immediateAlignment = false
        restoringReadingAnchor = false
        correctingOffset = true
        let destination = CGPoint(x: contentOffset.x, y: y)
        if animate {
            let animator = UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) { [weak self] in
                self?.setContentOffset(destination, animated: false)
            }
            animator.addCompletion { [weak self] _ in self?.finishedScrollAnimation() }
            scrollAnimator = animator
            animator.startAnimation()
        } else {
            UIView.performWithoutAnimation {
                setContentOffset(destination, animated: false)
                layoutIfNeeded()
            }
        }
        lastReaderOffset = contentOffset.y
        correctingOffset = false
        if !animate {
            // Self-sizing may refine the target during the synchronous layout.
            // Reveal only the positioned content, never a visible initial travel.
            if let refined = resolvedOffset(), abs(contentOffset.y - refined) > 0.5 {
                scheduleAlignment(immediate: true)
                return
            }
            revealContent()
            didChangeViewState?()
        }
    }
    private func revealContent() {
        // Fade only the first positioned transcript, not later streaming,
        // keyboard or disclosure layouts. Content offsets stay non-animated.
        guard !hasPresentedContent else { return }
        hasPresentedContent = true
        guard !reduceMotion else {
            UIView.performWithoutAnimation { alpha = 1 }
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) { [weak self] in
            self?.alpha = 1
        }
        animator.addCompletion { [weak self] _ in self?.revealAnimator = nil }
        revealAnimator = animator
        animator.startAnimation()
    }
    private func finishContentReveal() {
        revealAnimator?.stopAnimation(true)
        revealAnimator = nil
        if hasPresentedContent { UIView.performWithoutAnimation { alpha = 1 } }
    }
    private func resolvedOffset() -> CGFloat? {
        let maximum = TranscriptScrollGeometry.bottom(contentHeight: contentSize.height, viewportHeight: bounds.height,
                                                       topInset: adjustedContentInset.top, bottomInset: adjustedContentInset.bottom)
        let target: CGFloat
        switch scrollState.intent {
        case .latest: target = maximum
        case .turn(let id):
            guard let top = turnTop?(id) else { return nil }
            target = TranscriptScrollGeometry.turnOffset(rowTop: top, topInset: adjustedContentInset.top)
        case .reading:
            guard let anchor = readingAnchor, let top = rowTop?(anchor.rowID) else { return nil }
            target = top - adjustedContentInset.top - anchor.offset
        }
        return min(maximum, max(-adjustedContentInset.top, target))
    }
    private func updateResponseReservation() {
        let oldHeight = tableFooterView?.frame.height ?? 0
        let height: CGFloat
        if let id = scrollState.reservedTurnID, let top = turnTop?(id) {
            height = max(thinkingHeight, TranscriptScrollGeometry.reservation(
                turnOffset: TranscriptScrollGeometry.turnOffset(rowTop: top, topInset: adjustedContentInset.top),
                naturalHeight: contentSize.height - oldHeight, viewportHeight: bounds.height, bottomInset: adjustedContentInset.bottom))
        } else { height = thinkingHeight }
        guard abs(height - oldHeight) > 0.5 else { return }
        let footer = tableFooterView ?? UIView()
        footer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        tableFooterView = footer
    }
}

/// Shared by sent transcript bubbles and the separate composer queue.
enum TranscriptMessageStyle {
    static let rowInset: CGFloat = 16
    static let fontStyle: UIFont.TextStyle = .body
    static let outgoingInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    static func contentWidth(in rowWidth: CGFloat) -> CGFloat { max(100, rowWidth - 2 * rowInset) }
    static func outgoingWidth(in contentWidth: CGFloat) -> CGFloat { contentWidth * 0.85 }

    static func plainText(_ message: RemoteJSON) -> String {
        let text = message["text"].string ?? ""
        return message["images"].array.isEmpty ? text : text + "\n[Image attachment]"
    }

    @MainActor static func configure(_ text: UITextView) {
        text.isEditable = false; text.isSelectable = true; text.isScrollEnabled = false
        text.adjustsFontForContentSizeCategory = true
        text.textContainer.lineFragmentPadding = 0
        text.dataDetectorTypes = []
        text.layer.cornerRadius = 10
        text.layer.cornerCurve = .continuous
    }
}

struct QueuedMessageBubbles: View {
    let messages: [RemoteJSON]
    let canCancel: (String) -> Bool
    let cancel: (String) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            bubbles.fixedSize(horizontal: false, vertical: true)
            ScrollView { bubbles }
                .scrollDismissesKeyboard(.never)
        }
        .frame(maxHeight: 200)
    }

    private struct Row: Identifiable {
        let id: String
        let message: RemoteJSON
    }

    private var bubbles: some View {
        let rows = messages.compactMap { message in message["id"].string.map { Row(id: $0, message: message) } }
        return VStack(spacing: 8) {
            ForEach(rows) { row in
                let isCancellable = canCancel(row.id)
                QueuedMessageText(message: row.message, rowID: row.id, isCancellable: isCancellable)
                    .overlay(alignment: .topTrailing) {
                        if isCancellable {
                            Button(role: .destructive) { cancel(row.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                                    .frame(width: QueuedMessageText.cancelWidth, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Cancel Queued Message")
                            .accessibilityIdentifier("cancel-queued-message-\(row.id)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct QueuedMessageText: UIViewRepresentable {
    static let cancelWidth: CGFloat = 44
    let message: RemoteJSON
    let rowID: String
    let isCancellable: Bool

    func makeUIView(context: Context) -> UITextView {
        let text = UITextView()
        TranscriptMessageStyle.configure(text)
        text.backgroundColor = .systemGray5
        text.font = UIFont.preferredFont(forTextStyle: TranscriptMessageStyle.fontStyle)
        text.textColor = .label
        text.tintColor = AppColors.nativeBlue
        text.accessibilityHint = "Queued message"
        return text
    }

    func updateUIView(_ view: UITextView, context: Context) {
        var insets = TranscriptMessageStyle.outgoingInsets
        if isCancellable { insets.right = Self.cancelWidth }
        if view.textContainerInset != insets { view.textContainerInset = insets }
        let content = TranscriptMessageStyle.plainText(message)
        if view.text != content { view.text = content }
        view.accessibilityIdentifier = "queued-message-\(rowID)"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let contentWidth = proposal.width, contentWidth.isFinite else { return nil }
        let width = TranscriptMessageStyle.outgoingWidth(in: contentWidth)
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }
}

@MainActor private final class MessageCell: UITableViewCell, UITextViewDelegate {
    static let verticalContentInset: CGFloat = 10
    private let text = UITextView()
    private let markdownBody = UIKitMarkdownView()
    private let body = UIStackView()
    private var textWidth: NSLayoutConstraint!
    private var sourceText: String?
    private var markdown = false
    private var isUser = false
    private var blocks: [MarkdownBlock] = []
    private var renderedWidth: CGFloat = 0
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        TranscriptMessageStyle.configure(text)
        text.backgroundColor = .clear; text.delegate = self
        text.translatesAutoresizingMaskIntoConstraints = false
        body.axis = .vertical
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(text); body.addArrangedSubview(markdownBody)
        markdownBody.tintColor = AppColors.nativeBlue
        contentView.addSubview(body)
        textWidth = body.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: TranscriptMessageStyle.rowInset),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -TranscriptMessageStyle.rowInset),
            body.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalContentInset),
            body.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalContentInset),
            textWidth
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: MessageCell, _: UITraitCollection) in
            // The Markdown body handles its own attributed-font trait changes.
            if !cell.markdown { cell.render(width: TranscriptMessageStyle.contentWidth(in: cell.contentView.bounds.width)) }
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }
    override func prepareForReuse() {
        super.prepareForReuse()
        sourceText = nil; blocks = []
        text.attributedText = nil; text.selectedRange = NSRange(location: 0, length: 0)
        markdownBody.reset()
    }
    override func layoutSubviews() {
        let width = TranscriptMessageStyle.contentWidth(in: contentView.bounds.width)
        if sourceText != nil, abs(width - renderedWidth) > 1 {
            renderedWidth = width
            textWidth.constant = isUser ? TranscriptMessageStyle.outgoingWidth(in: width) : width
            if markdown { markdownBody.setLayoutWidth(width) }
        }
        super.layoutSubviews()
    }
    func configure(_ message: RemoteJSON, width: CGFloat) {
        let content = TranscriptMessageStyle.plainText(message)
        let useMarkdown = message["role"].string == "assistant"
        let user = message["role"].string == "user"
        guard sourceText != content || markdown != useMarkdown || isUser != user else { return }
        sourceText = content; markdown = useMarkdown; isUser = user
        blocks = useMarkdown ? MarkdownDocument.parse(content) : []
        text.isHidden = useMarkdown; markdownBody.isHidden = !useMarkdown
        if !useMarkdown { markdownBody.reset() }
        text.backgroundColor = user ? AppColors.nativeBlue : .clear
        text.tintColor = user ? .white : AppColors.nativeBlue
        text.textContainerInset = user ? TranscriptMessageStyle.outgoingInsets : .zero
        render(width: width)
    }
    private func render(width: CGFloat) {
        guard let sourceText else { return }
        renderedWidth = width
        textWidth.constant = isUser ? TranscriptMessageStyle.outgoingWidth(in: width) : width
        if markdown {
            markdownBody.update(blocks, source: sourceText, width: renderedWidth)
        } else {
            text.attributedText = NSAttributedString(string: sourceText, attributes: [
                .font: UIFont.preferredFont(forTextStyle: TranscriptMessageStyle.fontStyle, compatibleWith: traitCollection),
                .foregroundColor: isUser ? UIColor.white : UIColor.label
            ])
        }
    }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        MarkdownDocument.allowsLink(URL)
    }
}
