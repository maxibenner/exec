import AppKit

@MainActor struct TranscriptScrollTests {
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
