import AppKit
import SwiftUI
import Observation

/// Only data survives a conversation switch. No hidden scroll views or row hosts.
@MainActor @Observable final class TranscriptState {
    var followsLatest = true
    var jumpRequest = 0
    var trailingInset: CGFloat = 0
    @ObservationIgnored weak var scrollView: TranscriptScrollView?
    @ObservationIgnored var anchor: TranscriptLayout.Anchor?
    // Keep a consumed receipt from retriggering a jump on updates or remounts.
    @ObservationIgnored var handledImmediateSendID: UUID?
    // Reserve a viewport for a newly sent turn, including across view remounts.
    @ObservationIgnored var sentMessageID: UUID?
    @ObservationIgnored var layout = TranscriptLayout()
    @ObservationIgnored var expanded: [UUID: Bool] = [:]
    @ObservationIgnored let markdown = MarkdownCache()
    @ObservationIgnored let composerEditingState = ComposerEditingState()
    func jumpToLatest() { followsLatest = true; jumpRequest += 1 }
}

// Shared by the native transcript and overlays aligned to its viewport.
enum TranscriptColumn {
    static let maxWidth: CGFloat = 820
    static let horizontalInset: CGFloat = 20
}

struct TranscriptView: View {
    let messages: [Message]
    let state: TranscriptState
    var bottomInset: CGFloat = 0
    var showsThinkingIndicator = false
    var immediateSendID: UUID?
    var body: some View {
        VirtualTranscript(messages: messages, state: state, jumpRequest: state.jumpRequest, bottomInset: bottomInset,
                          showsThinkingIndicator: showsThinkingIndicator, immediateSendID: immediateSendID)
            .ignoresSafeArea(.container, edges: .top)
            .focusedSceneValue(\.transcriptNavigation, messages.contains { $0.role == .user } ? state : nil)
    }
}

private struct VirtualTranscript: NSViewRepresentable {
    let messages: [Message]
    let state: TranscriptState
    let jumpRequest: Int
    let bottomInset: CGFloat
    let showsThinkingIndicator: Bool
    let immediateSendID: UUID?
    func makeNSView(context: Context) -> TranscriptScrollView { TranscriptScrollView(state: state) }
    func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.update(messages: messages, jumpRequest: jumpRequest, bottomInset: bottomInset,
                    showsThinkingIndicator: showsThinkingIndicator, immediateSendID: immediateSendID)
    }
    static func dismantleNSView(_ view: TranscriptScrollView, coordinator: ()) { view.detach() }
}

/// A native scroll surface with a viewport-sized pool of SwiftUI message hosts.
/// Offscreen messages have geometry only. Height corrections preserve the top
/// message and its pixel offset, or the bottom edge when following a response.
/// Width reflow additionally preserves the reading character in ordinary text.
@MainActor final class TranscriptScrollView: NSScrollView {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }
    /// Keep AppKit's actual NSScroller rendering path. Overlay-compatible
    /// subclasses can receive an undersized native knob texture on newer macOS.
    /// Only action delivery needs customization, not the control or its drawing.
    @MainActor private final class ReaderScrollAction: NSObject {
        weak var target: AnyObject?
        var action: Selector?
        var track: ((() -> Void) -> Void)?

        func attach(to scroller: NSScroller?) {
            guard let scroller, scroller.target !== self else { return }
            target = scroller.target
            action = scroller.action
            scroller.target = self
            scroller.action = #selector(scroll(_:))
        }

        @objc private func scroll(_ sender: NSScroller) {
            guard let action else { return }
            let forward = { _ = NSApp.sendAction(action, to: self.target, from: sender) }
            if let track { track(forward) } else { forward() }
        }
    }
    private let readerScrollAction = ReaderScrollAction()
    private let content = DocumentView()
    private var thinkingFooter: NSHostingView<WorkingIndicator>?
    private var thinkingFooterHeight: CGFloat { thinkingFooter == nil ? 0 : 40 }
    var thinkingIndicatorFrame: CGRect? { thinkingFooter?.frame }

    private var trackingReaderScroll = false
    private var lastScrollY: CGFloat = 0
    private var wheelDirection: CGFloat = 0
    private static let bottomTolerance: CGFloat = 2
    let state: TranscriptState
    private var messages: [Message] = []
    private var arrivingToolIDs: Set<UUID> = []
    private var streamingGrowthPending = false
    private let growthMotion = TranscriptGrowthMotion()
    private var messagesChanged = true
    private var rows: [UUID: MessageHost] = [:]
    private var reuse: [MessageHost] = []
    private var scheduled = false
    private var refreshNeeded = false
    private var updating = false
    private var initialized = false
    private var detached = false
    private var lastSize = CGSize.zero
    private var jumpRequest = 0
    private var hasReceivedMessages = false
    private var navigationAnchor: TranscriptLayout.Anchor?
    // Keep the original character across every frame of a width animation;
    // recapturing the start of each newly wrapped line would accumulate drift.
    private var readingAnchor: (id: UUID, position: LinkedText.TextView.ReadingPosition)?
    private static let navigationPadding: CGFloat = 20
    private var requestedScroll = false
    private struct ScrollAnimation {
        let origin: CGFloat
        let started: TimeInterval
    }
    private var scrollAnimation: ScrollAnimation?
    var isAnimatingScroll: Bool { scrollAnimation != nil }
    private var scrollAnimationTask: Task<Void, Never>?
    private var bottomInset: CGFloat = 0
    private var renderedBottomInset: CGFloat = 0
    // Rows move down by the header overlap; anchors remain relative to the
    // unobscured viewport. Equal extra document and viewport height cancel out,
    // preserving the original scroll range, row widths and navigation targets.
    private(set) var topInset: CGFloat = 0
    private var renderedTopInset: CGFloat = 0
    private var selectionClearing: TranscriptSelectionClearing?
    var mountedRowCount: Int { rows.count }
    private(set) var rowMeasurementCount = 0

    init(state: TranscriptState) {
        self.state = state
        jumpRequest = state.jumpRequest
        super.init(frame: .zero)
        state.scrollView = self
        drawsBackground = false
        borderType = .noBorder
        readerScrollAction.track = { [weak self] action in self?.withReaderScroll(action) }
        hasVerticalScroller = true
        readerScrollAction.attach(to: verticalScroller)
        verticalScrollElasticity = .allowed
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        content.wantsLayer = true
        documentView = content
        growthMotion.layer = content.layer
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPolicyChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateHeaderInset(_ inset: CGFloat) {
        topInset = max(0, inset)
        if scrollerInsets.top != topInset { scrollerInsets.top = topInset }
    }

    func update(messages: [Message], jumpRequest: Int, bottomInset: CGFloat = 0,
                showsThinkingIndicator: Bool = false, immediateSendID: UUID? = nil) {
        guard !detached else { return }
        if showsThinkingIndicator {
            if thinkingFooter == nil { insertThinkingFooter() }
        } else {
            thinkingFooter?.removeFromSuperview()
            thinkingFooter = nil
        }
        self.bottomInset = max(0, bottomInset)
        // Empty inference placeholders have no visible content, but mounting them
        // adds row spacing and moves the bottom anchor between every tool result.
        // Keep terminal error labels visible even when no text arrived.
        let filtered = messages.filter {
            $0.compaction != nil || $0.role != .assistant || !$0.text.isEmpty || $0.status == .failed
        }
        streamingGrowthPending = initialized && Self.isStreamingGrowth(from: self.messages, to: filtered)
        if self.messages != filtered, !streamingGrowthPending, growthMotion.isActive,
           !preservesCompletedRendering(from: self.messages, to: filtered) {
            cancelGrowthMotion()
        }
        // A receipt or its snapshot may arrive first. Anchor only this exact
        // local send, even when other user rows arrive in the same update.
        if let id = immediateSendID, id != state.handledImmediateSendID,
           filtered.contains(where: { $0.id == id && $0.role == .user }) {
            state.handledImmediateSendID = id
            beginSendAnimation()
            state.sentMessageID = id
            state.followsLatest = false
            navigationAnchor = TranscriptLayout.Anchor(id: id, offset: -Self.navigationPadding)
            requestedScroll = true
        }
        if hasReceivedMessages {
            let previous = Set(self.messages.map(\.id))
            arrivingToolIDs.formUnion(filtered.filter { $0.isToolCard && !previous.contains($0.id) }.map(\.id))
        }
        hasReceivedMessages = true
        if let id = state.sentMessageID, !filtered.contains(where: { $0.id == id }) {
            state.sentMessageID = nil
        }
        if self.messages != filtered {
            readingAnchor = nil
            messagesChanged = true
            self.messages = filtered
        }
        if jumpRequest != self.jumpRequest {
            cancelScrollAnimation()
            cancelGrowthMotion()
            state.sentMessageID = nil
            state.followsLatest = true
            self.jumpRequest = jumpRequest
            requestedScroll = true
        }
        refresh()
    }

    private func insertThinkingFooter() {
        let footer = NSHostingView(rootView: WorkingIndicator())
        let shouldFade = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        footer.alphaValue = shouldFade ? 0 : 1
        thinkingFooter = footer
        content.addSubview(footer)
        refresh()
        if shouldFade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                footer.animator().alphaValue = 1
            }
        }
    }

    override func tile() {
        super.tile()
        // AppKit can replace/reconfigure its controls when the style changes.
        readerScrollAction.attach(to: verticalScroller)
    }

    override func layout() {
        super.layout()
        if let window {
            // Read the actual native titlebar overlap, including detached and
            // full-screen windows, rather than assuming a toolbar height.
            updateHeaderInset(min(bounds.height, convert(bounds, to: nil).maxY - window.contentLayoutRect.maxY))
        }
        // Commit row widths in this layout pass. Deferring to the main queue lets
        // a live split-view resize display one frame with the previous text width.
        if refreshNeeded || contentSize != lastSize || topInset != renderedTopInset { refresh() }
    }
    override func viewWillDraw() {
        // Hosting views may invalidate their natural size after the outer layout
        // pass. Consume that correction before this frame is painted, not on a
        // later animation tick/run-loop turn.
        super.viewWillDraw()
        if refreshNeeded { refresh() }
        growthMotion.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelScrollAnimation(); cancelGrowthMotion() }
        selectionClearing?.stop()
        selectionClearing = nil
        if window != nil, !detached {
            selectionClearing = TranscriptSelectionClearing(self) { [weak self] in
                self?.rebaseGrowthForReaderInteraction()
            }
            scheduleRefresh()
        }
    }
    /// Use the current viewport after manual scrolling, or the last explicit target
    /// for repeated commands. Native clip-view scrolling is intentionally immediate.
    func navigateSentMessage(_ direction: MessageNavigationDirection) {
        guard !detached, !updating, contentSize.width > 0, contentSize.height > 0 else { return }
        cancelScrollAnimation()
        cancelGrowthMotion()
        // Settle even during rubber-banding so message indices and geometry agree.
        requestedScroll = true
        refresh()
        let sent = messages.indices.filter { messages[$0].role == .user }
        guard let first = sent.first else { return }
        let target: Int?
        if let anchor = navigationAnchor, let current = sent.firstIndex(where: { messages[$0].id == anchor.id }) {
            switch direction {
            case .previous: target = sent[max(0, current - 1)]
            case .next: target = current + 1 < sent.count ? sent[current + 1] : nil
            }
        } else {
            let top = contentView.bounds.minY + Self.navigationPadding
            switch direction {
            case .previous:
                // From the bottom, skip recent messages already below the padded
                // top edge rather than inventing room to lift them above it.
                target = sent.last(where: { state.layout.offsets[$0] < top - 1 }) ?? first
            case .next:
                target = state.followsLatest ? nil : sent.first(where: { state.layout.offsets[$0] > top + 1 })
            }
        }
        navigationAnchor = target.map { TranscriptLayout.Anchor(id: messages[$0].id, offset: -Self.navigationPadding) }
        state.followsLatest = target == nil
        if target == nil { state.sentMessageID = nil }
        requestedScroll = true
        refresh()
    }

    func detach() {
        cancelScrollAnimation()
        cancelGrowthMotion()
        detached = true
        if state.scrollView === self { state.scrollView = nil }
        selectionClearing?.stop()
        selectionClearing = nil
        rememberAnchor()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for row in rows.values { row.didInvalidateSize = nil; row.removeFromSuperview() }
        rows.removeAll()
        reuse.removeAll()
        thinkingFooter?.removeFromSuperview()
        thinkingFooter = nil
    }
    @objc private func scrolled() {
        let previousY = lastScrollY
        lastScrollY = contentView.bounds.minY
        guard !updating else { return }
        // Bounds changes also come from TextKit, delayed hosting layout and
        // rubber-band recovery. None of those is permission to change intent.
        let eventType = NSApp.currentEvent?.type
        if initialized, contentSize == lastSize,
           trackingReaderScroll || eventType == .keyDown || eventType == .leftMouseDragged {
            let delta = lastScrollY - previousY
            if delta != 0 { readerScrolled(down: delta > 0) }
        }
        rememberAnchor()
        scheduleRefresh()
    }

    // Scope native scroller actions and keyboard scrolling, not layout work
    // that happens to produce a bounds notification between reader actions.
    func withReaderScroll(_ action: () -> Void) {
        rebaseGrowthForReaderInteraction()
        let wasTracking = trackingReaderScroll
        trackingReaderScroll = true
        defer { trackingReaderScroll = wasTracking }
        action()
    }

    override func keyDown(with event: NSEvent) {
        withReaderScroll { super.keyDown(with: event) }
    }

    private func readerScrolled(down: Bool) {
        cancelScrollAnimation()
        cancelGrowthMotion()
        navigationAnchor = nil
        readingAnchor = nil
        if !down {
            state.followsLatest = false
        } else if content.bounds.height - contentView.bounds.maxY <= Self.bottomTolerance {
            state.followsLatest = true
            state.sentMessageID = nil
        }
        rememberAnchor()
        scheduleRefresh()
    }

    override func scrollWheel(with event: NSEvent) {
        rebaseGrowthForReaderInteraction()
        // Momentum keeps the gesture's direction. A spring rebound must not
        // undo upward intent, nor opt a downward gesture out of following.
        if event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 {
            wheelDirection = event.scrollingDeltaY
        }
        if event.scrollingDeltaY != 0 {
            cancelScrollAnimation()
            if wheelDirection > 0 { readerScrolled(down: false) }
        }
        super.scrollWheel(with: event)
        // Check after delivery even at a boundary where no bounds event fires.
        if event.scrollingDeltaY != 0, wheelDirection != 0 {
            readerScrolled(down: wheelDirection < 0)
        }
    }

    // Only an append to a live tail or newly delivered live rows qualifies.
    // History replacement/removal, restyling and tool status updates are immediate.
    private static func isStreamingGrowth(from old: [Message], to new: [Message]) -> Bool {
        guard new.count >= old.count else { return false }
        var grew = false
        for (index, previous) in old.enumerated() {
            let next = new[index]
            if previous == next { continue }
            guard index == old.count - 1, previous.id == next.id,
                  previous.role == .assistant, !previous.isToolCard,
                  previous.status == .streaming, next.text.hasPrefix(previous.text),
                  next.text != previous.text else { return false }
            grew = true
        }
        for next in new.dropFirst(old.count) {
            guard next.isToolCard || (next.role == .assistant && next.status == .streaming) else { return false }
            grew = true
        }
        return grew
    }

    // Completion can be data-only, but provisional Markdown may instead become
    // literal text or lose an empty fence. Preserve motion only for identical
    // rendering, not merely identical source or equal row height.
    private func preservesCompletedRendering(from old: [Message], to new: [Message]) -> Bool {
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { previous, next in
            if previous == next { return true }
            guard previous.role == .assistant, previous.compaction == nil,
                  previous.pendingTool == nil, previous.toolResult == nil,
                  previous.status == .streaming, next.status == .complete else { return false }
            var completed = previous
            completed.status = .complete
            guard completed == next else { return false }
            // Compare renderer inputs, not native attributed strings: identical
            // code/table blocks allocate distinct NSTextTableBlock objects.
            func sameBlocks(_ a: [MarkdownBlock], _ b: [MarkdownBlock]) -> Bool {
                a.count == b.count && zip(a, b).allSatisfy {
                    $0.kind == $1.kind && $0.text == $1.text && sameBlocks($0.children, $1.children)
                }
            }
            return sameBlocks(StreamingMarkdown.parse(previous.text), MarkdownDocument.parse(next.text))
        }
    }

    private var hasTextSelection: Bool {
        func selected(_ view: NSView) -> Bool {
            if let text = view as? NSTextView, text.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) { return true }
            return view.subviews.contains(where: selected)
        }
        return selected(content)
    }

    func cancelGrowthMotion() {
        streamingGrowthPending = false
        growthMotion.cancel()
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard let text = notification.object as? NSTextView, text.isDescendant(of: content),
              text.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return }
        rebaseGrowthForReaderInteraction()
    }

    @objc private func motionPolicyChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cancelGrowthMotion()
            cancelScrollAnimation()
        }
    }

    // Called before mouse delivery/target selection, or by native selection and
    // keyboard/scroll input. Passive hit testing must never mutate the viewport.
    private func rebaseGrowthForReaderInteraction() {
        guard !updating, !detached, growthMotion.isActive else { return }
        var y = contentView.bounds.minY
        if let document = content.layer?.presentation(), let clip = contentView.layer?.presentation() {
            // In this flipped hierarchy: newY = pinnedY - displayedOffset.
            // Convert the actual presentation viewport, including its scroll
            // origin: a queued prepaint arrival may have changed BOTH the model
            // pin and pending compensation without displaying either yet.
            y = document.convert(clip.bounds.origin, from: clip).y
        }
        let maximum = max(0, content.bounds.height - contentView.bounds.height)
        y = min(maximum, max(0, y.isFinite ? y : contentView.bounds.minY))
        cancelScrollAnimation()
        updating = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: y))
        reflectScrolledClipView(contentView)
        cancelGrowthMotion()
        CATransaction.commit()
        updating = false
        state.followsLatest = false
        navigationAnchor = nil
        readingAnchor = nil
        rememberAnchor()
        scheduleRefresh()
    }

    private func cancelScrollAnimation() {
        scrollAnimationTask?.cancel()
        scrollAnimationTask = nil
        scrollAnimation = nil
    }

    private func beginSendAnimation() {
        cancelScrollAnimation()
        cancelGrowthMotion()
        // Initial mounting/reopening and offscreen geometry remain immediate.
        guard initialized, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = ProcessInfo.processInfo.systemUptime
        scrollAnimation = ScrollAnimation(origin: contentView.bounds.minY, started: now)
        scrollAnimationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard let self, self.scrollAnimation != nil else { return }
                guard !self.detached, self.window != nil,
                      self.contentSize.width > 0, self.contentSize.height > 0 else {
                    self.cancelScrollAnimation()
                    return
                }
                // Use the normal virtualization/measurement pass at every frame;
                // all our bounds changes stay under `updating`, not manual scrolls.
                self.refresh()
                if self.scrollAnimation == nil { return }
            }
        }
    }

    private func rememberAnchor() {
        guard initialized else { return }
        state.anchor = state.layout.anchor(at: contentView.bounds.minY)
        guard !state.followsLatest, navigationAnchor == nil else { readingAnchor = nil; return }
        guard readingAnchor == nil, contentSize == lastSize,
              let anchor = state.anchor, let text = rows[anchor.id]?.readingText else { return }
        let y = text.convert(NSPoint(x: 0, y: contentView.bounds.minY + topInset), from: content).y
        if let position = text.readingPosition(at: y) { readingAnchor = (anchor.id, position) }
    }
    private func scheduleRefresh() {
        guard !detached else { return }
        refreshNeeded = true
        needsLayout = true
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            // A synchronous resize/update may already have handled this request.
            if self.refreshNeeded { self.refresh() }
        }
    }

    func refresh() {
        guard !updating, !detached, contentSize.width > 0, contentSize.height > 0 else { return }
        let size = contentSize
        let oldY = contentView.bounds.minY
        let selecting = hasTextSelection
        let canAnimateGrowth = streamingGrowthPending && initialized && state.followsLatest &&
            window != nil && !requestedScroll && size == lastSize &&
            topInset == renderedTopInset && bottomInset == renderedBottomInset &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !selecting &&
            NSEvent.pressedMouseButtons == 0
        streamingGrowthPending = false
        if !state.followsLatest || requestedScroll || size != lastSize ||
            topInset != renderedTopInset || bottomInset != renderedBottomInset ||
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || selecting {
            cancelGrowthMotion()
        }
        if scrollAnimation != nil, size != lastSize || topInset != renderedTopInset ||
            bottomInset != renderedBottomInset || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cancelScrollAnimation()
            requestedScroll = true
        }
        // Match overlays to the actual viewport, not an assumed scrollbar style.
        // Publish outside the representable update/layout pass to avoid mutating
        // SwiftUI state while it is rendering. Read current geometry when delivered.
        if state.trailingInset != max(0, self.bounds.width - size.width) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.detached else { return }
                self.state.trailingInset = max(0, self.bounds.width - self.contentSize.width)
            }
        }
        // AppKit owns rubber-banding and its spring back. Defer content geometry
        // changes until the clip view returns in bounds, unless explicitly jumping.
        let bounds = contentView.bounds
        if initialized, size == lastSize, topInset == renderedTopInset, !requestedScroll,
           bounds.minY < 0 || bounds.maxY > content.bounds.height {
            cancelScrollAnimation()
            cancelGrowthMotion()
            return
        }
        updating = true
        refreshNeeded = false
        defer { updating = false }
        let width = max(1, min(TranscriptColumn.maxWidth, size.width - 2 * TranscriptColumn.horizontalInset))
        if requestedScroll && state.followsLatest { navigationAnchor = nil }
        if let navigationAnchor, !messages.contains(where: { $0.id == navigationAnchor.id }) {
            self.navigationAnchor = nil
        }
        var anchor = navigationAnchor ?? (initialized ? state.layout.anchor(at: contentView.bounds.minY) : state.anchor)
        let reading = !state.followsLatest && navigationAnchor == nil && width != state.layout.width ? readingAnchor : nil
        let oldHeight = state.layout.totalHeight
        let needsRestore = !initialized || requestedScroll || size != lastSize ||
            bottomInset != renderedBottomInset || topInset != renderedTopInset
        let pinBottom = state.followsLatest
        renderedBottomInset = bottomInset
        renderedTopInset = topInset
        if messagesChanged {
            state.layout.update(messages: messages, width: width)
            messagesChanged = false
        } else {
            state.layout.resize(to: width)
        }
        lastSize = size
        setDocumentSize()
        if pinBottom || needsRestore || oldHeight != state.layout.totalHeight || scrollAnimation != nil {
            restore(anchor, pinBottom: pinBottom)
        }
        requestedScroll = false
        initialized = true
        // Following must settle *all* measured corrections in this layout pass.
        // Manual reading retains the bounded, anchored virtualization path.
        var changed = false
        var passes = 0
        repeat {
            refreshNeeded = false
            passes += 1
            // Compensated content can expose pixels just above the logical
            // viewport. Keep those native rows mounted, including small windows.
            let overscan = max(size.height * 0.5, TranscriptGrowthMotion.maximumOffset)
            let range = state.layout.visibleRange(y: contentView.bounds.minY - topInset,
                                                  height: size.height, overscan: overscan)
            let wanted = Set(range.map { messages[$0].id })
            for id in Array(rows.keys) where !wanted.contains(id) {
                if let row = rows.removeValue(forKey: id) {
                    row.didInvalidateSize = nil
                    row.layer?.removeAnimation(forKey: "streamEntrance")
                    row.removeFromSuperview()
                    row.rootView = TranscriptRow(message: nil, state: state, width: width)
                    if reuse.count < 4 { reuse.append(row) }
                }
            }
            var measurements: [(id: UUID, height: CGFloat)] = []
            for index in range {
                let message = messages[index]
                let row: MessageHost
                if let existing = rows[message.id] { row = existing }
                else {
                    row = reuse.popLast() ?? MessageHost(rootView: TranscriptRow(message: nil, state: state, width: width))
                    rows[message.id] = row
                    content.addSubview(row)
                    row.didInvalidateSize = { [weak self] in self?.scheduleRefresh() }
                }
                let roundsTop = !message.isToolCard || index == 0 || !messages[index - 1].isToolCard
                let roundsBottom = !message.isToolCard || index + 1 == messages.count || !messages[index + 1].isToolCard
                if row.rootView.message != message || row.rootView.width != width ||
                    row.rootView.roundsTop != roundsTop || row.rootView.roundsBottom != roundsBottom {
                    row.rootView = TranscriptRow(message: message, state: state, width: width,
                                                 roundsTop: roundsTop, roundsBottom: roundsBottom)
                }
                if let height = row.measureHeightIfNeeded() {
                    rowMeasurementCount += 1
                    measurements.append((message.id, height))
                }
            }
            changed = state.layout.measure(measurements)
            if changed {
                if !canAnimateGrowth { cancelGrowthMotion() }
                setDocumentSize()
                restore(anchor, pinBottom: pinBottom)
            }
            for index in range {
                let frame = CGRect(x: (size.width - width) / 2, y: state.layout.offsets[index] + topInset,
                                   width: width, height: state.layout.heights[index])
                if rows[messages[index].id]?.frame != frame { rows[messages[index].id]?.frame = frame }
                rows[messages[index].id]?.layoutSubtreeIfNeeded()
            }
            if let reading, let row = rows[reading.id] {
                row.layoutSubtreeIfNeeded()
                if let text = row.readingText, let y = text.position(of: reading.position) {
                    let offset = text.convert(NSPoint(x: 0, y: y), to: row).y
                    anchor = TranscriptLayout.Anchor(id: reading.id, offset: offset)
                    restore(anchor, pinBottom: false)
                }
            }
            changed = changed || refreshNeeded
        } while changed && (pinBottom || passes < 3)
        // Ordinary navigation clamps to the natural bottom. A newly sent turn
        // keeps its padded top anchor even while the response area is empty.
        if state.sentMessageID == nil, navigationAnchor != nil,
           contentView.bounds.maxY >= content.bounds.height - 1 {
            navigationAnchor = nil
            state.followsLatest = true
        }
        arrivingToolIDs.removeAll()
        let growth = contentView.bounds.minY - oldY
        if canAnimateGrowth, growth > 0 {
            growthMotion.add(growth: growth)
            needsDisplay = true
        } else if growth != 0 {
            // Late measurements, reflow and other corrections are not arrivals.
            cancelGrowthMotion()
        }
        rememberAnchor()
        if changed { scheduleRefresh() }
    }
    private func setDocumentSize() {
        let turnTop = state.sentMessageID.flatMap {
            state.layout.position(of: TranscriptLayout.Anchor(id: $0, offset: -Self.navigationPadding))
        } ?? 0
        // This is a minimum height, not a fixed footer: answers consume the blank
        // space, then extend naturally below the fold without moving the reader.
        let size = CGSize(width: contentSize.width,
                          height: max(contentSize.height + turnTop,
                                      state.layout.totalHeight + thinkingFooterHeight + bottomInset + topInset))
        if content.frame.size != size { content.setFrameSize(size) }
        // The layout already includes trailing message spacing. Place the indicator
        // there, reserving its own height before the composer clearance.
        thinkingFooter?.frame = CGRect(x: (contentSize.width - state.layout.width) / 2,
                                      y: state.layout.totalHeight - 8 + topInset,
                                      width: 28, height: 16)
    }
    private func restore(_ anchor: TranscriptLayout.Anchor?, pinBottom: Bool) {
        let maximum = max(0, content.bounds.height - contentView.bounds.height)
        let y = pinBottom ? maximum : anchor.flatMap { state.layout.position(of: $0) } ?? contentView.bounds.minY
        var target = min(maximum, max(0, y))
        // Only the separate send-to-top anchor is animated (200 ms). Following
        // pins synchronously after every document-size/measurement correction.
        if pinBottom { cancelScrollAnimation() }
        if let scroll = scrollAnimation {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                cancelScrollAnimation()
            } else {
                let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - scroll.started) / 0.2))
                if target > scroll.origin {
                    target = scroll.origin + (target - scroll.origin) * (1 - pow(1 - progress, 3))
                }
                if progress == 1 { cancelScrollAnimation() }
            }
        }
        let origin = NSPoint(x: 0, y: target)
        if contentView.bounds.origin != origin {
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        }
    }
}

private struct TranscriptRow: View {
    let message: Message?
    let state: TranscriptState
    let width: CGFloat
    var roundsTop = true
    var roundsBottom = true
    var heightDidChange: ((CGFloat) -> Void)?
    var body: some View {
        Group {
            if let message { MessageView(message: message, state: state, roundsTop: roundsTop, roundsBottom: roundsBottom).equatable().id(message.id) }
        }
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // Observe natural content height, before the outer frame accepts the
        // previously committed height. Local/async SwiftUI state does not always
        // call NSHostingView.invalidateIntrinsicContentSize().
        .onGeometryChange(for: CGFloat.self) { max(1, ceil($0.size.height)) } action: {
            heightDidChange?($0)
        }
        // Accept even the stale collapsed height while the native row is being
        // remeasured. Without minHeight: 0, SwiftUI keeps the expanded minimum
        // height and the hosting view centers it over the disclosure header.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

// SwiftUI's ideal-size/layout probes can temporarily grow the hosting view before
// the virtual transcript has measured it and moved subsequent rows. A separate,
// native clipping boundary must retain the last committed row frame throughout.
private final class MessageHost: NSView {
    private let hosted: NSHostingView<TranscriptRow>
    private var needsMeasurement = true
    private var measuredHeight: CGFloat?
    var didInvalidateSize: (() -> Void)?
    var rootView: TranscriptRow {
        get { hosted.rootView }
        set {
            needsMeasurement = true
            var root = newValue
            root.heightDidChange = { [weak self] height in
                guard let self, !self.needsMeasurement, height != self.measuredHeight else { return }
                self.needsMeasurement = true
                self.didInvalidateSize?()
            }
            hosted.rootView = root
        }
    }

    init(rootView: TranscriptRow) {
        hosted = NSHostingView(rootView: rootView)
        // The transcript owns row frames. Keep ideal sizing for fittingSize,
        // without also probing automatic minimum/maximum sizing constraints.
        hosted.sizingOptions = [.intrinsicContentSize]
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        layer?.masksToBounds = true
        hosted.autoresizingMask = [.width, .height]
        addSubview(hosted)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { hosted.fittingSize }

    // Tool cards can contain multiple independently scrolling text surfaces;
    // retain their pixel anchor instead of guessing which content is being read.
    var readingText: LinkedText.TextView? {
        guard let message = rootView.message, message.toolResult == nil,
              message.pendingTool == nil, message.compaction == nil else { return nil }
        func find(in view: NSView) -> LinkedText.TextView? {
            (view as? LinkedText.TextView) ?? view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: hosted)
    }

    func measureHeightIfNeeded() -> CGFloat? {
        guard needsMeasurement else { return nil }
        let height = hosted.fittingSize.height
        measuredHeight = max(1, ceil(height))
        needsMeasurement = false
        return height
    }

    override func layout() {
        hosted.frame = bounds
        super.layout()
    }
}

private struct MessageView: View, Equatable {
    let message: Message
    let state: TranscriptState

    var roundsTop = true
    var roundsBottom = true

    // Width belongs to the row's layout, not its content. Reflow existing views
    // without rebuilding attributed text, tool presentations or decoded images.
    // Descendant SwiftUI state/environment updates still invalidate normally.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.state === rhs.state &&
            lhs.roundsTop == rhs.roundsTop && lhs.roundsBottom == rhs.roundsBottom
    }

    var body: some View {
        if message.compaction != nil {
            CompactionMessageView(status: message.status)
        } else if let call = message.pendingTool?.call ?? message.toolResult?.call {
            ToolMessageView(call: call, result: message.toolResult,
                            isAwaitingApproval: message.pendingTool?.isAwaitingApproval == true,
                            isActive: message.status == .streaming,
                            state: state, messageID: message.id, roundsTop: roundsTop, roundsBottom: roundsBottom)
        } else if message.role == .user {
            UserMessageBubble(message: message)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.status == .failed {
                    Label("Failed", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
                if !message.text.isEmpty { MarkdownView(source: message.text, cache: state.markdown, isStreaming: message.status == .streaming) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel("Assistant reply")
        }
    }
}
