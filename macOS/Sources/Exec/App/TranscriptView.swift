import AppKit
import SwiftUI
import Observation

/// Only data survives a conversation switch. No hidden scroll views or row hosts.
@MainActor @Observable final class TranscriptState {
    var followsLatest = true
    var jumpRequest = 0
    var trailingInset: CGFloat = 0
    var overlayScrollerInset: CGFloat = 0
    @ObservationIgnored var anchor: TranscriptLayout.Anchor?
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
            .overlay(alignment: .bottomTrailing) {
                if !state.followsLatest {
                    Button(action: state.jumpToLatest) { Image(systemName: "arrow.down") }
                        .buttonStyle(.bordered).buttonBorderShape(.circle)
                        .help("Jump to latest message").accessibilityLabel("Jump to latest message")
                        .padding(16).padding(.bottom, bottomInset)
                }
            }
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
@MainActor final class TranscriptScrollView: NSScrollView {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }
    private let content = DocumentView()
    let state: TranscriptState
    private var messages: [Message] = []
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
    private var lastMessageID: UUID?
    private var requestedScroll = false
    private var pendingContentFollow = false
    private var bottomInset: CGFloat = 0
    private var renderedBottomInset: CGFloat = 0
    private var selectionClearing: TranscriptSelectionClearing?
    var mountedRowCount: Int { rows.count }
    private(set) var rowMeasurementCount = 0

    init(state: TranscriptState) {
        self.state = state
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        verticalScrollElasticity = .allowed
        autohidesScrollers = true
        documentView = content
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(messages: [Message], jumpRequest: Int, bottomInset: CGFloat = 0) {
        self.bottomInset = max(0, bottomInset)
        // Empty inference placeholders have no visible content, but mounting them
        // adds row spacing and moves the bottom anchor between every tool result.
        // Keep terminal error/stop labels visible even when no text arrived.
        let filtered = messages.filter {
            $0.role != .assistant || !$0.text.isEmpty ||
                $0.status == .interrupted || $0.status == .failed
        }
        if initialized, let last = filtered.last, last.id != lastMessageID, last.role == .user {
            state.followsLatest = true
            requestedScroll = true
        }
        lastMessageID = filtered.last?.id
        if self.messages != filtered {
            if state.followsLatest { pendingContentFollow = true }
            messagesChanged = true
            self.messages = filtered
        }
        if jumpRequest != self.jumpRequest {
            state.followsLatest = true
            self.jumpRequest = jumpRequest
            requestedScroll = true
        }
        refresh()
    }
    override func layout() {
        super.layout()
        // Commit row widths in this layout pass. Deferring to the main queue lets
        // a live split-view resize display one frame with the previous text width.
        if contentSize != lastSize { refresh() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionClearing?.stop()
        selectionClearing = nil
        if window != nil, !detached {
            selectionClearing = TranscriptSelectionClearing(self)
            scheduleRefresh()
        }
    }
    func detach() {
        detached = true
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
        // Our own geometry corrections run under `updating`. Other offset changes
        // include keyboard, wheel and scrollbar navigation; resizing isn't a scroll.
        if initialized, contentSize == lastSize {
            let maximum = max(0, content.bounds.height - contentView.bounds.height)
            let position = min(maximum, max(0, contentView.bounds.minY))
            let nearBottom = maximum - position <= 40
            if state.followsLatest != nearBottom { state.followsLatest = nearBottom }
        }
        rememberAnchor()
        scheduleRefresh()
    }
    private func rememberAnchor() {
        if initialized { state.anchor = state.layout.anchor(at: contentView.bounds.minY) }
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

    // Overlay scrollers share the viewport. Reserve their full interactive width
    // in footer backgrounds, including while auto-hidden, without moving the text.
    private var overlayScrollerInset: CGFloat {
        guard hasVerticalScroller, scrollerStyle == .overlay else { return 0 }
        return NSScroller.scrollerWidth(for: verticalScroller?.controlSize ?? .regular, scrollerStyle: .overlay)
    }

    func refresh() {
        guard !updating, !detached, contentSize.width > 0, contentSize.height > 0 else { return }
        let size = contentSize
        // Match overlays to the actual viewport, not an assumed scrollbar style.
        // Publish outside the representable update/layout pass to avoid mutating
        // SwiftUI state while it is rendering. Read current geometry when delivered.
        if state.trailingInset != max(0, self.bounds.width - size.width) ||
            state.overlayScrollerInset != overlayScrollerInset {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.detached else { return }
                self.state.trailingInset = max(0, self.bounds.width - self.contentSize.width)
                self.state.overlayScrollerInset = self.overlayScrollerInset
            }
        }
        // AppKit owns rubber-banding and its spring back. Defer content geometry
        // changes until the clip view returns in bounds, unless explicitly jumping.
        let bounds = contentView.bounds
        if initialized, size == lastSize, !requestedScroll,
           bounds.minY < 0 || bounds.maxY > content.bounds.height { return }
        updating = true
        refreshNeeded = false
        defer { updating = false }
        let width = max(1, min(820, size.width - 40))
        let anchor = initialized ? state.layout.anchor(at: contentView.bounds.minY) : state.anchor
        let oldHeight = state.layout.totalHeight
        let needsRestore = !initialized || requestedScroll || size != lastSize || bottomInset != renderedBottomInset
        let pinBottom = state.followsLatest && (needsRestore || pendingContentFollow || abs(content.bounds.height - bounds.maxY) < 1)
        pendingContentFollow = false
        renderedBottomInset = bottomInset
        if messagesChanged {
            state.layout.update(messages: messages, width: width)
            messagesChanged = false
        } else {
            state.layout.resize(to: width, messages: messages)
        }
        lastSize = size
        setDocumentSize()
        if needsRestore || oldHeight != state.layout.totalHeight { restore(anchor, pinBottom: pinBottom) }
        requestedScroll = false
        initialized = true
        // Measuring estimates can reveal another row; settle a bounded number of
        // passes, then continue on the next run-loop turn if more work is needed.
        var changed = false
        for _ in 0..<3 {
            let range = state.layout.visibleRange(y: contentView.bounds.minY, height: size.height, overscan: size.height * 0.5)
            let wanted = Set(range.map { messages[$0].id })
            for id in Array(rows.keys) where !wanted.contains(id) {
                if let row = rows.removeValue(forKey: id) {
                    row.didInvalidateSize = nil
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
                if row.rootView.message != message || row.rootView.width != width {
                    row.rootView = TranscriptRow(message: message, state: state, width: width)
                }
                if let height = row.measureHeightIfNeeded() {
                    rowMeasurementCount += 1
                    measurements.append((message.id, height))
                }
            }
            changed = state.layout.measure(measurements)
            if changed {
                setDocumentSize()
                restore(anchor, pinBottom: pinBottom)
            }
            for index in range {
                let frame = CGRect(x: (size.width - width) / 2, y: state.layout.offsets[index],
                                   width: width, height: state.layout.heights[index])
                if rows[messages[index].id]?.frame != frame { rows[messages[index].id]?.frame = frame }
            }
            if !changed { break }
        }
        rememberAnchor()
        if changed { scheduleRefresh() }
    }
    private func setDocumentSize() {
        let size = CGSize(width: contentSize.width, height: max(contentSize.height, state.layout.totalHeight + bottomInset))
        if content.frame.size != size { content.setFrameSize(size) }
    }
    private func restore(_ anchor: TranscriptLayout.Anchor?, pinBottom: Bool) {
        let maximum = max(0, content.bounds.height - contentView.bounds.height)
        let y = pinBottom ? maximum : anchor.flatMap { state.layout.position(of: $0) } ?? contentView.bounds.minY
        let origin = NSPoint(x: 0, y: min(maximum, max(0, y)))
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
    var heightDidChange: ((CGFloat) -> Void)?
    var body: some View {
        Group {
            if let message { MessageView(message: message, state: state).id(message.id) }
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

private struct MessageView: View {

    let message: Message
    let state: TranscriptState
    var body: some View {
        if let result = message.toolResult {
            ToolMessageView(result: result, state: state, messageID: message.id)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.images.isEmpty { AttachmentStrip(images: message.images) }
                    if !message.text.isEmpty {
                        LinkedText(source: AttributedString(message.text))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 600, alignment: .trailing)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("You: \(message.text)")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.status == .interrupted {
                    Label("Stopped", systemImage: "stop.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if message.status == .failed {
                    Label("Failed · excluded from context", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
                if !message.text.isEmpty { MarkdownView(source: message.text, cache: state.markdown) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel("Assistant reply")
        }
    }
}
