import AppKit

@MainActor struct TranscriptScrollTests {
    func pinsEveryMeasuredPassAndRespectsManualOptOut() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        window.contentView = view
        defer { view.detach(); window.contentView = nil }
        var messages = [Message(role: .assistant, text: String(repeating: "Answer paragraph.\n\n", count: 30),
                                status: .streaming)]
        func assertPinned() throws {
            try expect(state.followsLatest && !view.isAnimatingScroll)
            try expect(view.contentView.bounds.maxY == view.documentView!.bounds.height)
            for row in view.documentView!.subviews {
                try expect(abs(row.frame.height - ceil(row.fittingSize.height)) < 1)
            }
        }
        func update(inset: CGFloat = 0) throws {
            view.update(messages: messages, jumpRequest: state.jumpRequest, bottomInset: inset)
            try assertPinned() // No timer, Task sleep, or additional refresh allowed.
            view.layoutSubtreeIfNeeded()
            try assertPinned()
            view.viewWillDraw()
            try assertPinned()
        }
        try update()
        for count in [1, 10, 300] {
            messages[0].text += String(repeating: "More answer.\n\n", count: count)
            try update()
        }
        // A burst of initially estimated rows must be measured/mounted before
        // returning to paint, not just pinned to an old document-height estimate.
        messages += (0..<40).map { Message(role: .assistant, text: "Row \($0) with `code`", status: .streaming) }
        try update()
        for inset: CGFloat in [100, 20, 180, 0] { try update(inset: inset) }
        view.updateHeaderInset(52)
        try update(inset: 80)
        for width: CGFloat in [430, 820, 700] {
            view.frame.size.width = width
            try update()
        }
        // A keyboard/scrollbar movement of only two pixels must not be swallowed
        // by the old 40pt tolerance, even after no-op bounds notifications.
        view.contentView.scroll(to: NSPoint(x: 0, y: view.contentView.bounds.minY - 2))
        try expect(!state.followsLatest)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.contentView)
        let readingY = view.contentView.bounds.minY
        messages[0].text += String(repeating: "While reading.\n\n", count: 50)
        view.update(messages: messages, jumpRequest: state.jumpRequest)
        view.layoutSubtreeIfNeeded(); view.viewWillDraw()
        try expect(view.contentView.bounds.minY == readingY && !state.followsLatest)
        state.jumpToLatest()
        try update()
        messages[0].status = .complete
        try update()
        messages.append(Message(role: .user, text: "Next question"))
        view.update(messages: messages, jumpRequest: state.jumpRequest)
        try expect(!state.followsLatest)
        try expect(view.isAnimatingScroll == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        state.jumpToLatest()
        try update()
        // Native wheel delivery is local, not posted to the system.
        let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                            wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!
        view.scrollWheel(with: wheel)
        try expect(!state.followsLatest && !view.isAnimatingScroll)
    }

    func onlyNewLiveRowsRevealOnFirstMount() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        var view = TranscriptScrollView(state: state)
        window.contentView = view
        defer { view.detach(); window.contentView = nil }
        func textViews(in root: NSView) -> [LinkedText.TextView] {
            if let text = root as? LinkedText.TextView { return [text] }
            return root.subviews.flatMap { textViews(in: $0) }
        }
        func update(_ messages: [Message]) {
            view.update(messages: messages, jumpRequest: state.jumpRequest)
            view.layoutSubtreeIfNeeded(); view.viewWillDraw()
        }
        let history = Message(role: .assistant, text: "Existing live history", status: .streaming)
        update([history])
        try expect(textViews(in: view).allSatisfy { ($0.layoutManager as? StreamedTextLayoutManager)?.fades.entrances.isEmpty == true })
        var reply = Message(role: .assistant, text: "", status: .streaming)
        update([history, reply]) // Filtered inference placeholder.
        reply.text = "First live chunk"
        update([history, reply])
        let text = textViews(in: view).first { $0.string == reply.text }!
        let layout = text.layoutManager as! StreamedTextLayoutManager
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try expect(!layout.fades.entrances.isEmpty)
            try expect(layout.fades.entrances.allSatisfy { $0.waitingForPaint })
        }
        reply.status = .complete
        let count = layout.fades.entrances.count
        update([history, reply])
        try expect(layout.fades.entrances.count == count)
        view.detach()
        try expect(layout.fades.entrances.isEmpty)
        view = TranscriptScrollView(state: state)
        window.contentView = view
        reply.status = .streaming
        update([history, reply])
        try expect(textViews(in: view).allSatisfy { ($0.layoutManager as? StreamedTextLayoutManager)?.fades.entrances.isEmpty == true })
    }

    func headerUnderlapPreservesGeometryAndAnchors() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        let messages = (0..<8).map { Message(role: .user, text: "Message \($0)") }
        func settle(header: CGFloat, height: CGFloat = 300, width: CGFloat = 700) {
            view.frame.size = NSSize(width: width, height: height + header)
            view.updateHeaderInset(header)
            view.update(messages: messages, jumpRequest: state.jumpRequest, bottomInset: 100)
            for _ in 0..<8 { view.layoutSubtreeIfNeeded(); view.refresh() }
        }
        settle(header: 0)
        // Measure the whole fixture before comparing geometry; otherwise a
        // larger overscan region can legitimately replace more estimates.
        for _ in messages { view.navigateSentMessage(.previous); settle(header: 0) }
        state.jumpToLatest()
        settle(header: 0)
        let heights = state.layout.heights
        let width = state.layout.width
        let maximum = view.documentView!.frame.height - view.contentView.bounds.height
        try expect(maximum > 40)
        for header: CGFloat in [52, 0, 78] {
            settle(header: header)
            try expect(state.layout.width == width && state.layout.heights == heights)
            try expect(abs(view.contentView.bounds.minY - maximum) < 1)
            try expect(state.followsLatest)
        }
        // Keep a manually chosen reading position while the header changes.
        view.contentView.scroll(to: NSPoint(x: 0, y: 50))
        view.reflectScrolledClipView(view.contentView)
        view.refresh()
        try expect(!state.followsLatest)
        // Rows are actually mounted in the header-covered portion of the clip
        // view, not merely moved out of sight at the safe-area boundary.
        try expect(view.documentView!.subviews.contains {
            $0.frame.minY < view.contentView.bounds.minY + view.topInset &&
            $0.frame.maxY > view.contentView.bounds.minY
        })
        let anchor = state.anchor!
        for header: CGFloat in [0, 52, 78] {
            settle(header: header)
            try expect(state.anchor?.id == anchor.id)
            try expect(abs(state.anchor!.offset - anchor.offset) < 1)
            try expect(state.layout.heights == heights)
        }
        view.navigateSentMessage(.previous)
        let target = state.anchor!
        settle(header: 52)
        try expect(state.anchor?.id == target.id && abs(state.anchor!.offset - target.offset) < 1)
        // Reflow still preserves a message anchor, and jump-to-latest stays at
        // the natural bottom with both header and composer space included.
        settle(header: 52, height: 360, width: 540)
        state.jumpToLatest()
        settle(header: 52, height: 360, width: 540)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.frame.height) < 1)
        try expect(state.followsLatest)
        view.update(messages: [messages[0]], jumpRequest: state.jumpRequest, bottomInset: 100)
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); view.refresh() }
        try expect(view.contentView.bounds.minY == 0)
        try expect(view.documentView!.frame.height == view.contentSize.height)
        try expect(view.documentView!.subviews.allSatisfy { $0.frame.minY >= view.topInset })
    }

    func routesVerticalGesturesWithoutStealingOtherScrolling() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        let transcript = ScrollRecorder(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        root.addSubview(transcript)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1_000))
        transcript.documentView = document
        let table = LinkedText.TextView(frame: NSRect(x: 30, y: 30, width: 300, height: 100))
        table.isEditable = false
        table.update(MarkdownText.render(MarkdownDocument.parse("| A | B |\n| --- | --- |\n| one | two |")))
        document.addSubview(table)
        let horizontal = HorizontalContentScrollView(frame: NSRect(x: 30, y: 200, width: 300, height: 100))
        horizontal.hasHorizontalScroller = true
        horizontal.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 100))
        document.addSubview(horizontal)
        root.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        let point = table.convert(NSPoint(x: 15, y: 15), to: nil)
        let selection = NSRange(location: 0, length: 1)
        table.setSelectedRange(selection)
        // Full-height text passes every original event onward, without choosing
        // or retaining an axis, including zero-delta end and momentum events.
        for (x, y, phase, momentum) in [
            (1.0, -20.0, NSEvent.Phase.began, NSEvent.Phase()),
            (20.0, -1.0, .changed, []),
            (0.0, 0.0, .ended, []),
            (0.0, -5.0, [], .began),
            (0.0, 0.0, [], .ended)
        ] {
            let event = WheelEvent(window: window, point: point, x: x, y: y,
                                   phase: phase, momentum: momentum)
            table.scrollWheel(with: event)
            try expect(transcript.lastEvent === event)
        }
        try expect(transcript.events == 5)
        try expect(table.selectedRange() == selection && table.isSelectable)

        // The same behavior applies inside a horizontal-only content surface.
        let text = LinkedText.TextView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 100))
        text.isEditable = false
        text.isSelectable = true
        horizontal.documentView = text
        let vertical = WheelEvent(window: window, point: point, x: 0, y: -20)
        text.scrollWheel(with: vertical)
        try expect(transcript.events == 6 && transcript.lastEvent === vertical)
        let sideways = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                               wheelCount: 2, wheel1: 0, wheel2: -20, wheel3: 0)!)!
        text.scrollWheel(with: sideways)
        try expect(transcript.events == 6)

        // A vertical gesture stays with the transcript even when later deltas
        // become predominantly horizontal, including its momentum tail.
        for (x, y, phase, momentum) in [
            (1.0, -20.0, NSEvent.Phase.began, NSEvent.Phase()),
            (20.0, -1.0, .changed, []),
            (0.0, 0.0, .ended, []),
            (10.0, -1.0, [], .began),
            (0.0, 0.0, [], .ended)
        ] {
            let event = WheelEvent(window: window, point: point, x: x, y: y,
                                   phase: phase, momentum: momentum)
            text.scrollWheel(with: event)
            try expect(transcript.lastEvent === event)
        }
        try expect(transcript.events == 11)
        try gestureAxisStaysLocked()
        try selectionScrollingStaysOnItsSurface(window: window)
    }

    private func selectionScrollingStaysOnItsSurface(window: NSWindow) throws {
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let clip = AutoscrollRecorder(frame: outer.bounds)
        outer.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1_000))
        outer.documentView = document
        window.contentView = outer
        let horizontal = HorizontalContentScrollView(frame: NSRect(x: 50, y: 100, width: 300, height: 100))
        document.addSubview(horizontal)
        let text = LinkedText.TextView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 150))
        text.isEditable = false
        horizontal.documentView = text
        outer.layoutSubtreeIfNeeded()

        // Even a temporarily oversized document cannot scroll vertically. Its
        // horizontal offset remains available to selection and wheel scrolling.
        horizontal.contentView.scroll(to: NSPoint(x: 80, y: 20))
        try expect(horizontal.contentView.bounds.minY == 0)
        try expect(horizontal.contentView.bounds.minX == 80)
        let rightEdge = horizontal.contentView.convert(NSPoint(
            x: horizontal.contentView.bounds.maxX + 10,
            y: horizontal.contentView.bounds.midY), to: nil)
        _ = text.autoscroll(with: WheelEvent(window: window, point: rightEdge, x: 0, y: 0))
        try expect(horizontal.contentView.bounds.minX > 80)
        try expect(clip.events == 0)

        // Leaving the diff vertically while still inside the transcript must not
        // start the transcript's repeated selection autoscroll.
        let inside = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
        let event = WheelEvent(window: window, point: inside, x: 0, y: 0)
        _ = text.autoscroll(with: event)
        try expect(clip.events == 0)
        try expect(horizontal.contentView.bounds.minY == 0)

        for y in [clip.bounds.minY - 10, clip.bounds.maxY + 10] {
            let outside = clip.convert(NSPoint(x: clip.bounds.midX, y: y), to: nil)
            _ = text.autoscroll(with: WheelEvent(window: window, point: outside, x: 0, y: 0))
        }
        try expect(clip.events == 2)

        clip.scroll(to: NSPoint(x: 0, y: 200))
        clip.useNativeAutoscroll = true
        let previousY = clip.bounds.minY
        let outside = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.minY - 20), to: nil)
        _ = text.autoscroll(with: WheelEvent(window: window, point: outside, x: 0, y: 0))
        try expect(clip.bounds.minY != previousY)
        try expect(horizontal.contentView.bounds.minY == 0)
    }

    private final class AutoscrollRecorder: NSClipView {
        var events = 0
        var useNativeAutoscroll = false
        override func autoscroll(with event: NSEvent) -> Bool {
            events += 1
            return useNativeAutoscroll ? super.autoscroll(with: event) : true
        }
    }

    private func gestureAxisStaysLocked() throws {
        var routing = ScrollGestureAxis()
        try expect(routing.route(x: 0, y: 0, phase: .began, momentum: []) == nil)
        try expect(routing.route(x: 20, y: 1, phase: .changed, momentum: []) == .horizontal)
        try expect(routing.route(x: 1, y: 20, phase: .changed, momentum: []) == .horizontal)
        try expect(routing.route(x: 0, y: 0, phase: .ended, momentum: []) == .horizontal)
        try expect(routing.route(x: 1, y: 20, phase: [], momentum: .began) == .horizontal)
        try expect(routing.route(x: 0, y: 0, phase: [], momentum: .ended) == .horizontal)
        try expect(routing.route(x: 1, y: 20, phase: .began, momentum: []) == .vertical)
        try expect(routing.route(x: 20, y: 1, phase: .changed, momentum: []) == .vertical)
        try expect(routing.route(x: 0, y: 0, phase: .cancelled, momentum: []) == .vertical)
        try expect(routing.route(x: 20, y: 1, phase: .began, momentum: []) == .horizontal)
        // A fresh touch also interrupts a previous gesture without momentum.
        try expect(routing.route(x: 0, y: 0, phase: .ended, momentum: []) == .horizontal)
        try expect(routing.route(x: 1, y: 20, phase: .began, momentum: []) == .vertical)
        // Ordinary mouse wheels have no gesture phases and must not get stuck.
        try expect(routing.route(x: 20, y: 0, phase: [], momentum: []) == .horizontal)
        try expect(routing.route(x: 0, y: 20, phase: [], momentum: []) == .vertical)
    }

    private final class ScrollRecorder: NSScrollView {
        var events = 0
        var lastEvent: NSEvent?
        override func scrollWheel(with event: NSEvent) { events += 1; lastEvent = event }
    }

    private final class WheelEvent: NSEvent {
        private let targetWindow: NSWindow
        private let point: NSPoint
        private let x: CGFloat
        private let y: CGFloat
        private let eventPhase: NSEvent.Phase
        private let momentum: NSEvent.Phase

        init(window: NSWindow, point: NSPoint, x: CGFloat, y: CGFloat,
             phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) {
            targetWindow = window; self.point = point; self.x = x; self.y = y
            eventPhase = phase; self.momentum = momentum
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var window: NSWindow? { targetWindow }
        override var locationInWindow: NSPoint { point }
        override var scrollingDeltaX: CGFloat { x }
        override var scrollingDeltaY: CGFloat { y }
        override var phase: NSEvent.Phase { eventPhase }
        override var momentumPhase: NSEvent.Phase { momentum }
    }
}
