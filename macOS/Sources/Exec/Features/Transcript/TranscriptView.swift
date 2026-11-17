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
    // Reserve a viewport for a newly sent turn, including across view remounts.
    @ObservationIgnored var sentMessageID: UUID?
    @ObservationIgnored var layout = TranscriptLayout()
    @ObservationIgnored var expanded: [UUID: Bool] = [:]
    @ObservationIgnored let markdown = MarkdownCache()
    func jumpToLatest() { followsLatest = true; jumpRequest += 1 }
}

struct TranscriptView: View {
    let messages: [Message]
    let state: TranscriptState
    var bottomInset: CGFloat = 0
    var body: some View {
        VirtualTranscript(messages: messages, state: state, jumpRequest: state.jumpRequest, bottomInset: bottomInset)
            .ignoresSafeArea(.container, edges: .top)
            .focusedSceneValue(\.transcriptNavigation, messages.contains { $0.role == .user } ? state : nil)
    }
}

private struct VirtualTranscript: NSViewRepresentable {
    let messages: [Message]
    let state: TranscriptState
    let jumpRequest: Int
    let bottomInset: CGFloat
    func makeNSView(context: Context) -> TranscriptScrollView { TranscriptScrollView(state: state) }
    func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.update(messages: messages, jumpRequest: jumpRequest, bottomInset: bottomInset)
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
    private let content = DocumentView()
    let state: TranscriptState
    private var messages: [Message] = []
    private var arrivingToolIDs: Set<UUID> = []
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
    private var scrollAnimation: (origin: CGFloat, started: TimeInterval, duration: TimeInterval, followsBottom: Bool)?
    private var scrollAnimationTask: Task<Void, Never>?
    private var pendingContentFollow = false
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
        hasVerticalScroller = true
        verticalScrollElasticity = .allowed
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        documentView = content
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateHeaderInset(_ inset: CGFloat) {
        topInset = max(0, inset)
        if scrollerInsets.top != topInset { scrollerInsets.top = topInset }
    }

    func update(messages: [Message], jumpRequest: Int, bottomInset: CGFloat = 0) {
        self.bottomInset = max(0, bottomInset)
        // Empty inference placeholders have no visible content, but mounting them
        // adds row spacing and moves the bottom anchor between every tool result.
        // Keep terminal error labels visible even when no text arrived.
        let filtered = messages.filter {
            $0.compaction != nil || $0.role != .assistant || !$0.text.isEmpty || $0.status == .failed
        }
        // Look for the latest user row, not the last visible row: the first
        // response chunk may arrive in the same SwiftUI update as the send.
        if hasReceivedMessages, let sent = filtered.last(where: { $0.role == .user }),
           !self.messages.contains(where: { $0.id == sent.id }) {
            beginScrollAnimation(followsBottom: false)
            state.sentMessageID = sent.id
            state.followsLatest = false
            navigationAnchor = TranscriptLayout.Anchor(id: sent.id, offset: -Self.navigationPadding)
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
            if state.followsLatest { pendingContentFollow = true }
            messagesChanged = true
            self.messages = filtered
        }
        if jumpRequest != self.jumpRequest {
            cancelScrollAnimation()
            state.sentMessageID = nil
            state.followsLatest = true
            self.jumpRequest = jumpRequest
            requestedScroll = true
        }
        refresh()
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
        if contentSize != lastSize || topInset != renderedTopInset { refresh() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelScrollAnimation() }
        selectionClearing?.stop()
        selectionClearing = nil
        if window != nil, !detached {
            selectionClearing = TranscriptSelectionClearing(self)
            scheduleRefresh()
        }
    }
    /// Use the current viewport after manual scrolling, or the last explicit target
    /// for repeated commands. Native clip-view scrolling is intentionally immediate.
    func navigateSentMessage(_ direction: MessageNavigationDirection) {
        guard !detached, !updating, contentSize.width > 0, contentSize.height > 0 else { return }
        cancelScrollAnimation()
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
        detached = true
        if state.scrollView === self { state.scrollView = nil }
        selectionClearing?.stop()
        selectionClearing = nil
        rememberAnchor()
        NotificationCenter.default.removeObserver(self)
        for row in rows.values { row.didInvalidateSize = nil; row.removeFromSuperview() }
        rows.removeAll()
        reuse.removeAll()
    }
    @objc private func scrolled() {
        guard !updating else { return }
        let wasFollowingAnimation = scrollAnimation?.followsBottom == true
        cancelScrollAnimation()
        // Our own geometry corrections run under `updating`. Other offset changes
        // include keyboard, wheel and scrollbar navigation; resizing isn't a scroll.
        if initialized, contentSize == lastSize {
            navigationAnchor = nil
            readingAnchor = nil
            let maximum = max(0, content.bounds.height - contentView.bounds.height)
            let position = min(maximum, max(0, contentView.bounds.minY))
            let previousPosition = state.anchor.flatMap { state.layout.position(of: $0) } ?? position
            let scrolledDown = contentView.bounds.minY > max(0, previousPosition)
            let distanceFromBottom = maximum - position
            // A new turn resumes following only after a downward scroll reaches
            // the bottom. Streaming/measurement corrections run under `updating`,
            // and merely filling the reserved space leaves the reader in place.
            // Preserve the usual near-bottom tolerance after following resumes.
            let interruptedUpward = wasFollowingAnimation && position < previousPosition
            let nearBottom = !interruptedUpward && (state.sentMessageID == nil ? distanceFromBottom <= 40 :
                scrolledDown && distanceFromBottom < 1)
            if nearBottom { state.sentMessageID = nil }
            if state.followsLatest != nearBottom { state.followsLatest = nearBottom }
        }
        rememberAnchor()
        scheduleRefresh()
    }
    override func scrollWheel(with event: NSEvent) {
        // Stop before AppKit moves the clip view, including at a scroll boundary.
        if scrollAnimation != nil {
            cancelScrollAnimation()
            navigationAnchor = nil
            readingAnchor = nil
        }
        super.scrollWheel(with: event)
        if event.scrollingDeltaY > 0 {
            // Upward intent opts out even inside the usual near-bottom tolerance.
            state.followsLatest = false
            pendingContentFollow = false
            navigationAnchor = nil
            readingAnchor = nil
            rememberAnchor()
        }
    }

    private func cancelScrollAnimation() {
        scrollAnimationTask?.cancel()
        scrollAnimationTask = nil
        scrollAnimation = nil
    }

    private func beginScrollAnimation(followsBottom: Bool) {
        cancelScrollAnimation()
        // Initial mounting/reopening and offscreen geometry remain immediate.
        guard initialized, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        scrollAnimation = (contentView.bounds.minY, ProcessInfo.processInfo.systemUptime,
                           followsBottom ? 0.24 : 0.2, followsBottom)
        scrollAnimationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard let self, let scroll = self.scrollAnimation else { return }
                let finished = ProcessInfo.processInfo.systemUptime - scroll.started >= scroll.duration
                // Use the normal virtualization/measurement pass at every frame;
                // all our bounds changes stay under `updating`, not manual scrolls.
                self.refresh()
                if finished { self.cancelScrollAnimation(); return }
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
           bounds.minY < 0 || bounds.maxY > content.bounds.height { return }
        updating = true
        refreshNeeded = false
        defer { updating = false }
        let width = max(1, min(820, size.width - 40))
        if requestedScroll && state.followsLatest { navigationAnchor = nil }
        if let navigationAnchor, !messages.contains(where: { $0.id == navigationAnchor.id }) {
            self.navigationAnchor = nil
        }
        var anchor = navigationAnchor ?? (initialized ? state.layout.anchor(at: contentView.bounds.minY) : state.anchor)
        let reading = !state.followsLatest && navigationAnchor == nil && width != state.layout.width ? readingAnchor : nil
        let oldHeight = state.layout.totalHeight
        let needsRestore = !initialized || requestedScroll || size != lastSize ||
            bottomInset != renderedBottomInset || topInset != renderedTopInset
        let pinBottom = state.followsLatest && (needsRestore || pendingContentFollow ||
            scrollAnimation?.followsBottom == true || abs(content.bounds.height - bounds.maxY) < 1)
        pendingContentFollow = false
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
        if needsRestore || oldHeight != state.layout.totalHeight || scrollAnimation != nil {
            restore(anchor, pinBottom: pinBottom, animateBottom: !needsRestore)
        }
        requestedScroll = false
        initialized = true
        // Measuring estimates can reveal another row; settle a bounded number of
        // passes, then continue on the next run-loop turn if more work is needed.
        var changed = false
        for _ in 0..<3 {
            let range = state.layout.visibleRange(y: contentView.bounds.minY - topInset,
                                                  height: size.height, overscan: size.height * 0.5)
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
                setDocumentSize()
                restore(anchor, pinBottom: pinBottom, animateBottom: !needsRestore)
            }
            for index in range {
                let frame = CGRect(x: (size.width - width) / 2, y: state.layout.offsets[index] + topInset,
                                   width: width, height: state.layout.heights[index])
                if rows[messages[index].id]?.frame != frame { rows[messages[index].id]?.frame = frame }
            }
            if let reading, let row = rows[reading.id] {
                row.layoutSubtreeIfNeeded()
                if let text = row.readingText, let y = text.position(of: reading.position) {
                    let offset = text.convert(NSPoint(x: 0, y: y), to: row).y
                    anchor = TranscriptLayout.Anchor(id: reading.id, offset: offset)
                    restore(anchor, pinBottom: false)
                }
            }
            if !changed { break }
        }
        // Ordinary navigation clamps to the natural bottom. A newly sent turn
        // keeps its padded top anchor even while the response area is empty.
        if state.sentMessageID == nil, navigationAnchor != nil,
           contentView.bounds.maxY >= content.bounds.height - 1 {
            navigationAnchor = nil
            state.followsLatest = true
        }
        // Only newly delivered cards, never virtualized history or status updates.
        for id in arrivingToolIDs {
            guard let row = rows[id], window != nil,
                  row.frame.intersects(contentView.bounds),
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { continue }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.55
            animation.toValue = 1
            animation.duration = 0.18
            row.layer?.add(animation, forKey: "streamEntrance")
        }
        arrivingToolIDs.removeAll()
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
                                      state.layout.totalHeight + bottomInset + topInset))
        if content.frame.size != size { content.setFrameSize(size) }
    }
    private func restore(_ anchor: TranscriptLayout.Anchor?, pinBottom: Bool, animateBottom: Bool = false) {
        let maximum = max(0, content.bounds.height - contentView.bounds.height)
        let y = pinBottom ? maximum : anchor.flatMap { state.layout.position(of: $0) } ?? contentView.bounds.minY
        var target = min(maximum, max(0, y))
        // Coalesce streaming growth into a bounded window. New chunks update the
        // destination, never the start time, so a busy stream cannot keep us behind.
        // Do not animate initial restoration, resizing, or explicit bottom jumps.
        if scrollAnimation == nil, animateBottom, pinBottom,
           state.sentMessageID == nil, target > contentView.bounds.minY + 1 {
            beginScrollAnimation(followsBottom: true)
        }
        if let scroll = scrollAnimation, target > scroll.origin {
            let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - scroll.started) / scroll.duration))
            let eased = 1 - pow(1 - progress, 3)
            target = scroll.origin + (target - scroll.origin) * eased
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
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.images.isEmpty { AttachmentStrip(images: message.images) }
                    if !message.files.isEmpty { FileAttachmentStrip(files: message.files) }
                    if !message.text.isEmpty {
                        LinkedText(source: AttributedString(message.text), foregroundColor: .white)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(AppColors.blue, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 600, alignment: .trailing)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("You: \(message.text)")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.status == .failed {
                    Label("Failed", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
                if !message.text.isEmpty { MarkdownView(source: message.text, cache: state.markdown)
                    .environment(\.animatesStreamedText, message.status == .streaming) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel("Assistant reply")
        }
    }
}
