import SwiftUI
import UIKit
import ExecRemote
import ExecTranscript

/// UIKit owns virtualization and reuse. One host measures each adjacent tool
/// group; message rows use selectable TextKit with the shared Markdown parser.
struct NativeTranscript: UIViewControllerRepresentable {
    let conversationID: String?
    let snapshot: RemoteJSON
    let queuedMessage: RemoteJSON
    let cancelQueuedMessage: (String) -> Void
    let descriptiveShellTitles: Bool
    let viewState: TranscriptViewState?
    let saveViewState: (String, TranscriptViewState) -> Void
    let bottomPadding: CGFloat
    let hasEarlier: Bool
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
        table.register(MessageCell.self, forCellReuseIdentifier: "message")
        table.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
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
        table.hasEarlier = hasEarlier
        table.loadEarlier = loadEarlier
        context.coordinator.update(conversationID: conversationID, snapshot: snapshot,
                                   queuedMessage: queuedMessage, cancelQueuedMessage: cancelQueuedMessage,
                                   descriptiveShellTitles: descriptiveShellTitles, viewState: viewState, table: table)
    }
    static func dismantleUIViewController(_ controller: UITableViewController, coordinator: Coordinator) {
        if let table = controller.tableView as? TranscriptTableView { coordinator.detach(table) }
    }
    @MainActor final class Coordinator: NSObject, UITableViewDelegate {
        private struct Update {
            let conversationID: String?
            let snapshot: RemoteJSON
            let queuedMessage: RemoteJSON
            let cancelQueuedMessage: (String) -> Void
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
                cell.configure(item.rows[0].message, width: max(100, table.bounds.width - 32),
                               cancelQueuedMessage: item.isQueued ? { [weak self] in self?.currentUpdate?.cancelQueuedMessage(id) } : nil)
                return cell
            }
        }
        private func binding(_ rowID: String, table: UITableView) -> Binding<Bool> {
            Binding(get: { [weak self] in self?.expansion[rowID] ?? false }, set: { [weak self, weak table] value in
                guard let self, let table = table as? TranscriptTableView, let group = self.itemForRow[rowID] else { return }
                self.expansion[rowID] = value
                self.dirtyGroups.insert(group)
                self.scheduleUpdate(table)
            })
        }
        func update(conversationID: String?, snapshot: RemoteJSON, queuedMessage: RemoteJSON,
                    cancelQueuedMessage: @escaping (String) -> Void, descriptiveShellTitles: Bool,
                    viewState: TranscriptViewState?, table: TranscriptTableView) {
            pendingUpdate = Update(conversationID: conversationID, snapshot: snapshot, queuedMessage: queuedMessage,
                                   cancelQueuedMessage: cancelQueuedMessage,
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
            let projected = TranscriptItem.project(update.snapshot, queuedMessage: update.queuedMessage)
            let next = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
            let dirty = dirtyGroups
            dirtyGroups.removeAll()
            let validSnapshot = update.snapshot["id"].string == update.conversationID && update.conversationID != nil
            guard changedConversation || changedDisplay || next != items || !dirty.isEmpty || (!hasSnapshot && validSnapshot) else { return }
            applying = true
            if changedConversation {
                savePresentation(table)
                table.resetScroll()
                expansion.removeAll(); toolFrames.removeAll(); measuredHeights.removeAll(); hasSnapshot = false
                presentation = update.viewState
            }
            let initial = changedConversation || currentUpdate == nil
            let opening = changedConversation || !table.hasPresentedContent
            let previousQueuedID = changedConversation ? nil : currentUpdate?.queuedMessage["id"].string
            currentUpdate = update
            table.beginContentUpdate()
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
                // The first real history is a loading baseline, even after a cold
                // queue was displayed. Keep a still-present local turn pinned.
                table.scrollState.restoreRows(rows)
            } else {
                _ = table.scrollState.update(rows: rows)
            }
            if let queuedID = update.queuedMessage["id"].string, queuedID != previousQueuedID {
                table.scrollState.submitted(queuedID)
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
                // After a cold queue disappears, an empty table is still a ready
                // projection. Lay it out and clear its old turn reservation too.
                table.finishContentUpdate(initial: opening,
                    ready: self.hasSnapshot || update.queuedMessage != .null || table.hasPresentedContent)
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
    var hasEarlier = false
    var loadEarlier: (() -> Void)?
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
    private var requestedEarlier = false
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
    private var lastReaderOffset: CGFloat = 0
    private var reduceMotion: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--transcript-reduce-motion") { return true }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }

    override init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: style)
        NotificationCenter.default.addObserver(self, selector: #selector(motionPolicyChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:style:)") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func resetScroll() {
        cancelScrollAnimation()
        finishContentReveal()
        scrollState = TranscriptScrollState()
        readingAnchor = nil
        restoringReadingAnchor = false
        requestedEarlier = false
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
        if !restoringReadingAnchor, scrollState.intent == .reading, let anchor = readingPosition?() { readingAnchor = anchor }
    }
    func beginReaderScroll() {
        cancelScrollAnimation()
        readerActive = true
        readerDirection = 0
        lastReaderOffset = contentOffset.y
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
        guard previousSize == bounds.size, previousInsets == adjustedContentInset else { return }
        if isDragging { setReaderDirection(-panGestureRecognizer.velocity(in: self).y) }
        guard abs(delta) > 0.1, readerDirection != 0 else { return }
        let bottom = TranscriptScrollGeometry.bottom(contentHeight: contentSize.height, viewportHeight: bounds.height,
                                                       topInset: adjustedContentInset.top, bottomInset: adjustedContentInset.bottom)
        // Keep the gesture's direction through momentum/rubber-band rebound.
        // Neither a layout callback nor merely being near the bottom opts in.
        scrollState.readerScrolled(towardLatest: readerDirection > 0, atBottom: contentOffset.y >= bottom - 2)
        if restoringReadingAnchor, let anchor = readingAnchor {
            readingAnchor = TranscriptViewportAnchor(rowID: anchor.rowID, offset: anchor.offset - delta)
        } else { rememberReadingPosition() }
        if contentOffset.y > -adjustedContentInset.top + 250 { requestedEarlier = false }
        if isDragging, readerDirection < 0, hasEarlier, !requestedEarlier,
           contentOffset.y < -adjustedContentInset.top + 120 {
            requestedEarlier = true
            loadEarlier?()
        }
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
        guard alignmentNeeded, contentReady, !updatingContent,
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
            height = TranscriptScrollGeometry.reservation(
                turnOffset: TranscriptScrollGeometry.turnOffset(rowTop: top, topInset: adjustedContentInset.top),
                naturalHeight: contentSize.height - oldHeight, viewportHeight: bounds.height, bottomInset: adjustedContentInset.bottom)
        } else { height = 0 }
        guard abs(height - oldHeight) > 0.5 else { return }
        let footer = tableFooterView ?? UIView()
        footer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        tableFooterView = footer
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
    private var cancelQueuedMessage: (() -> Void)?
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
        body.axis = .vertical
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(text); body.addArrangedSubview(markdownBody)
        markdownBody.tintColor = AppColors.nativeBlue
        contentView.addSubview(body)
        textWidth = body.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalContentInset),
            body.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalContentInset),
            textWidth
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: MessageCell, _: UITraitCollection) in
            // The Markdown body handles its own attributed-font trait changes.
            if !cell.markdown { cell.render(width: max(100, cell.contentView.bounds.width - 32)) }
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }
    override func prepareForReuse() {
        super.prepareForReuse()
        sourceText = nil; blocks = []
        setQueuedAction(nil)
        text.attributedText = nil; text.selectedRange = NSRange(location: 0, length: 0)
        markdownBody.reset()
    }
    override func layoutSubviews() {
        let width = max(100, contentView.bounds.width - 32)
        if sourceText != nil, abs(width - renderedWidth) > 1 {
            renderedWidth = width
            textWidth.constant = isUser ? width * 0.85 : width
            if markdown { markdownBody.setLayoutWidth(width) }
        }
        super.layoutSubviews()
    }
    func configure(_ message: RemoteJSON, width: CGFloat, cancelQueuedMessage: (() -> Void)? = nil) {
        // Acceptance can change only queue state, not text. Update before the
        // rendering fast path; dim just the bubble, never its reusable cell.
        setQueuedAction(message["role"].string == "user" ? cancelQueuedMessage : nil)
        var content = message["text"].string ?? ""
        if !message["images"].array.isEmpty { content += "\n[Image attachment]" }
        let useMarkdown = message["role"].string == "assistant"
        let user = message["role"].string == "user"
        guard sourceText != content || markdown != useMarkdown || isUser != user else { return }
        sourceText = content; markdown = useMarkdown; isUser = user
        blocks = useMarkdown ? MarkdownDocument.parse(content) : []
        text.isHidden = useMarkdown; markdownBody.isHidden = !useMarkdown
        if !useMarkdown { markdownBody.reset() }
        text.backgroundColor = user ? AppColors.nativeBlue : .clear
        text.tintColor = user ? .white : AppColors.nativeBlue
        text.textContainerInset = user ? UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12) : .zero
        render(width: width)
    }
    private func render(width: CGFloat) {
        guard let sourceText else { return }
        renderedWidth = max(100, width)
        textWidth.constant = isUser ? renderedWidth * 0.85 : renderedWidth
        if markdown {
            markdownBody.update(blocks, source: sourceText, width: renderedWidth)
        } else {
            text.attributedText = NSAttributedString(string: sourceText, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection),
                .foregroundColor: isUser ? UIColor.white : UIColor.label
            ])
        }
    }
    private func setQueuedAction(_ action: (() -> Void)?) {
        cancelQueuedMessage = action
        text.alpha = action == nil ? 1 : 0.68
        text.accessibilityCustomActions = action.map { cancel in
            [UIAccessibilityCustomAction(name: "Cancel Queued Message") { _ in cancel(); return true }]
        }
    }
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let cancelQueuedMessage else { return UIMenu(children: suggestedActions) }
        let cancel = UIAction(title: "Cancel Queued Message", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
            cancelQueuedMessage()
        }
        // Preserve TextKit selection and every native Copy/selection action.
        return UIMenu(children: suggestedActions + [cancel])
    }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        MarkdownDocument.allowsLink(URL)
    }
}
