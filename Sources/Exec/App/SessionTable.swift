import AppKit
import SwiftUI

/// A native sidebar table supplies both the system insertion indicator and the
/// drag-session end callback that SwiftUI's reorder-only List does not expose.
struct SessionTable: NSViewRepresentable {
    let store: ChatLibrary
    let windows: SessionWindows
    let open: (UUID) -> Void
    let delete: (SessionSummary) -> Void
    let rename: (SessionSummary) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = SidebarTable()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .sourceList
        table.draggingDestinationFeedbackStyle = .regular
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes([SessionDrag.pasteboardType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.move, forLocal: false)
        table.setAccessibilityLabel("Sessions")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? SidebarTable else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        let rows = store.sidebarSessions
        let changed = rows.map(\.id) != coordinator.rows.map(\.id)
        coordinator.rows = rows
        if changed { table.reloadData() }
        else {
            for row in rows.indices {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSHostingView<SessionRow> {
                    cell.rootView = coordinator.rowView(row)
                }
            }
        }
        let index = rows.firstIndex { $0.id == store.sidebarSelectionID }
        table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        table.deleteSelection = { [weak coordinator, weak table] in
            guard let coordinator, let table, coordinator.parent.store.canNavigate,
                  coordinator.rows.indices.contains(table.selectedRow) else { return }
            let session = coordinator.rows[table.selectedRow]
            if !coordinator.parent.store.isSessionRunning(session.id) { coordinator.parent.delete(session) }
        }
    }

    final class SidebarTable: NSTableView {
        var deleteSelection: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                deleteSelection?()
            } else { super.keyDown(with: event) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SessionTable
        var rows: [SessionSummary] = []
        var updating = false
        private var draggedID: UUID?
        init(_ parent: SessionTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func rowView(_ row: Int) -> SessionRow {
            let session = rows[row]
            let shortcut = parent.store.sessionShortcuts.first { $0.session.id == session.id }?.number
            return SessionRow(session: session, store: parent.store, shortcut: shortcut,
                              rename: { self.parent.rename(session) },
                              detach: { self.parent.windows.detach(session.id) },
                              delete: { self.parent.delete(session) })
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("SessionCell")
            if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSHostingView<SessionRow> {
                cell.rootView = rowView(row)
                return cell
            }
            let cell = NSHostingView(rootView: rowView(row))
            cell.identifier = identifier
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { parent.store.canNavigate }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView,
                  rows.indices.contains(table.selectedRow) else { return }
            parent.open(rows[table.selectedRow].id)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.store.canReorderSessions, rows.indices.contains(row) else { return nil }
            return SessionDrag.item(for: rows[row].id)
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            guard let row = rowIndexes.first, rows.indices.contains(row) else { return }
            draggedID = rows[row].id
            parent.windows.draggingSessionID = draggedID
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.store.canReorderSessions, SessionDrag.session(in: info.draggingPasteboard, windows: parent.windows) != nil else { return [] }
            tableView.setDropRow(max(0, min(row, rows.count)), dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent.store.canReorderSessions,
                  let id = SessionDrag.session(in: info.draggingPasteboard, windows: parent.windows) else { return false }
            let nextID = rows.indices.contains(row) ? rows[row].id : nil
            if parent.store.detachedSessionIDs.contains(id) {
                parent.windows.attach(id, before: nextID, reorder: true)
            } else { parent.store.moveSession(id, before: nextID) }
            return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let id = draggedID else { return }
            draggedID = nil
            SessionDrag.finish(id: id, windows: parent.windows, source: tableView.window,
                               point: screenPoint, operation: operation)
        }
    }
}
