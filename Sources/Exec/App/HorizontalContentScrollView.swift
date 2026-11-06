import AppKit

/// Embedded content always uses its full height. Each trackpad gesture stays on
/// its initial axis through momentum, so diagonal drift cannot move the chat.
@MainActor class HorizontalContentScrollView: NSScrollView {
    private var gestureAxis = ScrollGestureAxis()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func scrollWheel(with event: NSEvent) {
        let axis = gestureAxis.route(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                     phase: event.phase, momentum: event.momentumPhase)
        switch axis {
        case .vertical:
            nextResponder?.scrollWheel(with: event)
        case .horizontal:
            super.scrollWheel(with: event)
        case nil:
            break
        }
    }
}

/// Phase-less mouse wheels choose per event; trackpads retain the choice until
/// momentum ends or a new touch gesture begins. A zero-delta begin doesn't choose.
struct ScrollGestureAxis {
    enum Axis { case horizontal, vertical }
    private var axis: Axis?

    mutating func route(x: CGFloat, y: CGFloat, phase: NSEvent.Phase,
                        momentum: NSEvent.Phase) -> Axis? {
        if phase.contains(.began) || phase.contains(.mayBegin) {
            axis = nil
        }
        if phase.isEmpty && momentum.isEmpty {
            axis = nil
            return x == 0 && y == 0 ? nil : (abs(x) > abs(y) ? .horizontal : .vertical)
        }
        if axis == nil && (x != 0 || y != 0) {
            axis = abs(x) > abs(y) ? .horizontal : .vertical
        }
        let destination = axis
        // Touch ended may be followed by momentum began: keep the lock across it.
        if phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled) {
            axis = nil
        }
        return destination
    }
}
