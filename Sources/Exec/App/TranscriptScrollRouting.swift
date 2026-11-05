import AppKit

/// Route vertical gestures before nested text/horizontal scroll views consume
/// them. This is a local event monitor, scoped to this transcript's hit-tested
/// subtree and window; composer, sidebar and modal scrolling remain untouched.
@MainActor final class TranscriptScrollRouting {
    private weak var scrollView: NSScrollView?
    private var monitor: Any?
    private var verticalGesture: Bool?

    init(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        verticalGesture = nil
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard monitor != nil, let scrollView, let window = scrollView.window,
              event.window === window, let root = window.contentView else { return event }
        // hitTest expects a point in the receiver's superview coordinates.
        let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = root.hitTest(point), hit === scrollView || hit.isDescendant(of: scrollView) else {
            verticalGesture = nil
            return event
        }
        let x = abs(event.scrollingDeltaX)
        let y = abs(event.scrollingDeltaY)
        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { verticalGesture = nil }
        if phased, verticalGesture == nil, x > 0 || y > 0 { verticalGesture = y >= x }
        let vertical = phased ? verticalGesture == true : y > 0 && y >= x
        // Keep the chosen axis through momentum and zero-delta end events so
        // horizontal gestures stay local and vertical rubber-banding can finish.
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            verticalGesture = nil
        }
        guard vertical else { return event }
        scrollView.scrollWheel(with: event)
        return nil // Consumed exactly once, not delivered again to the child.
    }
}
