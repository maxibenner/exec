import AppKit
import SwiftUI

@MainActor enum SessionDrag {
    static let pasteboardType = NSPasteboard.PasteboardType("com.exec.session")

    static func item(for id: UUID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: pasteboardType)
        return item
    }

    /// Accept only an in-process drag we started, never an arbitrary external UUID.
    static func session(in pasteboard: NSPasteboard, windows: SessionWindows) -> UUID? {
        guard let value = pasteboard.string(forType: pasteboardType), let id = UUID(uuidString: value),
              id == windows.draggingSessionID,
              windows.library.sessionList.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    static func shouldDetach(operation: NSDragOperation, point: NSPoint, sourceFrame: NSRect,
                             mouseReleased: Bool, cancelled: Bool) -> Bool {
        operation.isEmpty && mouseReleased && !cancelled && !sourceFrame.contains(point)
    }

    static func finish(id: UUID, windows: SessionWindows, source: NSWindow?, point: NSPoint,
                       operation: NSDragOperation) {
        defer { windows.draggingSessionID = nil }
        guard !windows.library.detachedSessionIDs.contains(id), let source else { return }
        let event = NSApp.currentEvent
        let cancelled = event?.type == .keyDown && event?.keyCode == 53
        // Escape ends a native drag with .none too. A held mouse button must not
        // turn that cancellation into a new window.
        if shouldDetach(operation: operation, point: point, sourceFrame: source.frame,
                        mouseReleased: NSEvent.pressedMouseButtons & 1 == 0, cancelled: cancelled) {
            windows.detach(id, at: point)
        }
    }
}

/// A detached window's title is a real AppKit drag source. It has no click action,
/// so tracking a drag here does not interfere with text editing or row selection.
struct SessionDragSource: NSViewRepresentable {
    let windows: SessionWindows
    let sessionID: UUID

    func makeNSView(context: Context) -> TitleView { TitleView(windows: windows, sessionID: sessionID) }
    func updateNSView(_ view: TitleView, context: Context) {
        view.title.stringValue = windows.title(for: sessionID)
        view.setAccessibilityLabel(view.title.stringValue)
    }

    final class TitleView: NSView, NSDraggingSource {
        let windows: SessionWindows
        let sessionID: UUID
        let title = NSTextField(labelWithString: "")
        init(windows: SessionWindows, sessionID: UUID) {
            self.windows = windows
            self.sessionID = sessionID
            super.init(frame: .zero)
            title.lineBreakMode = .byTruncatingTail
            title.font = .systemFont(ofSize: NSFont.systemFontSize)
            addSubview(title)
            title.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: leadingAnchor),
                title.trailingAnchor.constraint(equalTo: trailingAnchor),
                title.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            toolTip = "Drag to the session sidebar"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

        override func mouseDown(with event: NSEvent) {
            guard windows.library.canReorderSessions, let window else { return }
            let origin = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { return }
                guard hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y) >= 4 else { continue }
                let item = NSDraggingItem(pasteboardWriter: SessionDrag.item(for: sessionID))
                let image = NSImage(size: bounds.size)
                image.lockFocus()
                title.stringValue.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                        .foregroundColor: NSColor.labelColor])
                image.unlockFocus()
                item.setDraggingFrame(bounds, contents: image)
                windows.draggingSessionID = sessionID
                beginDraggingSession(with: [item], event: event, source: self)
                return
            }
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            SessionDrag.finish(id: sessionID, windows: windows, source: window, point: screenPoint, operation: operation)
        }
    }
}
