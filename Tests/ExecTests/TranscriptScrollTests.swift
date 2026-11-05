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
        let horizontal = NSScrollView(frame: NSRect(x: 30, y: 200, width: 300, height: 100))
        horizontal.hasHorizontalScroller = true
        horizontal.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 100))
        document.addSubview(horizontal)
        root.layoutSubtreeIfNeeded()
        let routing = TranscriptScrollRouting(transcript)
        defer { routing.stop(); window.contentView = nil }
        let tablePoint = table.convert(NSPoint(x: 15, y: 15), to: nil)
        let horizontalPoint = horizontal.convert(NSPoint(x: 15, y: 50), to: nil)
        func event(_ x: CGFloat, _ y: CGFloat, point: NSPoint? = nil,
                   phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) -> WheelEvent {
            WheelEvent(window: window, point: point ?? tablePoint, x: x, y: y, phase: phase, momentum: momentum)
        }
        try expect(routing.handle(event(0, -20)) == nil)
        try expect(routing.handle(event(2, 20, point: horizontalPoint)) == nil)
        try expect(transcript.events == 2)
        let sideways = event(20, 0, point: horizontalPoint)
        try expect(routing.handle(sideways) === sideways && transcript.events == 2)

        // A trackpad gesture keeps its axis through diagonal movement and momentum.
        try expect(routing.handle(event(1, -20, phase: .began)) == nil)
        try expect(routing.handle(event(20, -1, phase: .changed)) == nil)
        try expect(routing.handle(event(0, 0, phase: .ended)) == nil)
        try expect(routing.handle(event(0, -5, momentum: .began)) == nil)
        try expect(routing.handle(event(0, 0, momentum: .ended)) == nil)
        try expect(transcript.events == 7)
        for wheel in [event(20, 1, phase: .began), event(1, 20, phase: .changed),
                      event(0, 0, phase: .ended), event(5, 0, momentum: .began), event(0, 0, momentum: .ended)] {
            try expect(routing.handle(wheel) === wheel)
        }
        try expect(transcript.events == 7)

        // A footer or approval panel layered over the transcript must keep its
        // own scrolling; checking just the transcript rectangle is insufficient.
        let overlay = NSScrollView(frame: table.convert(table.bounds, to: root))
        root.addSubview(overlay)
        let covered = event(0, -20)
        try expect(routing.handle(covered) === covered)
        overlay.removeFromSuperview()
        let sidebar = event(0, -20, point: NSPoint(x: 700, y: 100))
        try expect(routing.handle(sidebar) === sidebar)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let foreign = WheelEvent(window: otherWindow, point: tablePoint, x: 0, y: -20)
        try expect(routing.handle(foreign) === foreign && transcript.events == 7)
        routing.stop()
        let stopped = event(0, -20)
        try expect(routing.handle(stopped) === stopped && transcript.events == 7)
    }

    private final class ScrollRecorder: NSScrollView {
        var events = 0
        override func scrollWheel(with event: NSEvent) { events += 1 }
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
