import AppKit

@MainActor struct SidebarTableTests {
    func snapshotsReuseCellsAndValidateDrops() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        let table = SidebarTableView(frame: scroll.bounds)
        scroll.documentView = table
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.close() }

        let a = UUID(), b = UUID(), c = UUID(), inserted = UUID()
        var ids = [a, b, c]
        var title = "Initial"
        var canMove = true
        var moveCalls = 0
        table.makeCell = { _, reusable in
            let field = reusable as? NSTextField ?? NSTextField(labelWithString: "")
            field.stringValue = title
            return field
        }
        table.canMove = { canMove }
        table.move = { [weak table] id, next in
            moveCalls += 1
            ids.removeAll { $0 == id }
            let index = next.flatMap { ids.firstIndex(of: $0) } ?? ids.count
            ids.insert(id, at: index)
            table?.update(ids: ids, animated: true)
            return true
        }
        table.update(ids: ids, animated: false)
        table.layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField else {
            throw CheckFailure(description: "Missing native sidebar cell")
        }
        title = "Updated"
        table.update(ids: ids, animated: true)
        try expect(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === cell)
        try expect(cell.stringValue == "Updated")
        try expect(!table.acceptsFirstResponder && table.selectionHighlightStyle == .none)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try expect(table.selectionHighlightStyle == .none)

        // Inserts between drag start and drop must not reinterpret the source ID.
        ids.insert(inserted, at: 0)
        table.update(ids: ids, animated: true)
        try expect(table.acceptMove(a, before: c))
        try expect(table.itemIDs == [inserted, b, a, c])
        ids.removeAll { $0 == inserted }
        table.update(ids: ids, animated: true)
        try expect(!table.acceptMove(inserted, before: nil))
        try expect(!table.acceptMove(a, before: inserted))
        canMove = false
        try expect(!table.acceptMove(a, before: nil))
        try expect(moveCalls == 1)
        canMove = true
        try expect(table.acceptMove(b, before: nil))
        try expect(table.itemIDs == [a, c, b])
        try await Task.sleep(for: .milliseconds(300))
        try expect(table.numberOfRows == 3)
        // Reduced-motion and failure reconciliation use the same snapshot path.
        table.update(ids: [a, b, c], animated: false)
        try expect(table.itemIDs == [a, b, c] && table.numberOfRows == 3)
    }
}
