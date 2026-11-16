import AppKit
import SwiftUI

/// Leave left-button tracking (including dragging) to the table. Hosting views
/// otherwise consume it even when their SwiftUI content has no tap gesture.
final class SidebarRowHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { super.mouseDown(with: event); return }
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? SidebarTableView {
                table.mouseDown(with: event)
                return
            }
            ancestor = view.superview
        }
        super.mouseDown(with: event)
    }
}

/// One owner for row identity and structural animation. Content updates do not
/// reapply snapshots, and SwiftUI transactions cannot suppress native row moves.
@MainActor final class SidebarTableView: NSTableView {
    static let rowIdentifier = NSUserInterfaceItemIdentifier("session")
    static let dragType = NSPasteboard.PasteboardType("app.exec.sidebar-session")

    var makeCell: ((UUID, NSView?) -> NSView)?
    var activate: ((UUID) -> Void)?
    var canMove: (() -> Bool)?
    var move: ((UUID, UUID?) -> Bool)?
    private var hasSnapshot = false
    private lazy var source = SidebarTableDataSource(tableView: self) { [weak self] table, _, _, id in
        let reusable = table.makeView(withIdentifier: Self.rowIdentifier, owner: nil)
        let view = self?.makeCell?(id, reusable) ?? NSView()
        view.identifier = Self.rowIdentifier
        return view
    }

    override var acceptsFirstResponder: Bool { false }
    var itemIDs: [UUID] { source.snapshot().itemIdentifiers }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        headerView = nil
        style = .sourceList
        // AppKit can track a drag selection, but never draws it. The active
        // conversation's neutral background is owned by the row content.
        selectionHighlightStyle = .none
        focusRingType = .none
        allowsMultipleSelection = false
        backgroundColor = .clear
        rowHeight = 48
        intercellSpacing = NSSize(width: 0, height: 4)
        usesAutomaticRowHeights = true
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        autoresizingMask = [.width]
        target = self
        action = #selector(activateClickedRow)
        registerForDraggedTypes([Self.dragType])
        setDraggingSourceOperationMask(.move, forLocal: true)
        setDraggingSourceOperationMask([], forLocal: false)
        draggingDestinationFeedbackStyle = .gap
        source.owner = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(ids: [UUID], animated: Bool) {
        if itemIDs != ids || !hasSnapshot {
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            let animate = animated && hasSnapshot && window != nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animate ? 0.2 : 0
                context.allowsImplicitAnimation = animate
                source.apply(snapshot, animatingDifferences: animate)
            }
            hasSnapshot = true
        }
        // Reconfigure only mounted cells. No reloadData/reloadItems: those would
        // replace hosts and interrupt an insertion or drag animation in flight.
        let visible = rows(in: visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) {
            guard let id = source.itemIdentifier(forRow: row),
                  let view = view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            _ = makeCell?(id, view)
        }
    }

    @objc private func activateClickedRow() {
        guard clickedRow >= 0, let id = source.itemIdentifier(forRow: clickedRow) else { return }
        activate?(id)
    }

    /// Validate using stable IDs, not offsets captured before a concurrent insert.
    func acceptMove(_ id: UUID, before nextID: UUID?) -> Bool {
        let ids = itemIDs
        guard canMove?() == true, ids.contains(id), nextID != id,
              nextID.map({ ids.contains($0) }) ?? true else { return false }
        return move?(id, nextID) ?? false
    }
}

@MainActor private final class SidebarTableDataSource: NSTableViewDiffableDataSource<Int, UUID> {
    weak var owner: SidebarTableView?

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard owner?.canMove?() == true, let id = itemIdentifier(forRow: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: SidebarTableView.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView, owner?.canMove?() == true,
              operation == .above, (0...tableView.numberOfRows).contains(row) else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === tableView, operation == .above,
              (0...tableView.numberOfRows).contains(row),
              let raw = info.draggingPasteboard.string(forType: SidebarTableView.dragType),
              let id = UUID(uuidString: raw) else { return false }
        return owner?.acceptMove(id, before: itemIdentifier(forRow: row)) ?? false
    }
}
