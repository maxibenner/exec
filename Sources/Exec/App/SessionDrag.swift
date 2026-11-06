import AppKit

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
