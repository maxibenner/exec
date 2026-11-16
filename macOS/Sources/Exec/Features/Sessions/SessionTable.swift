import SwiftUI

/// SwiftUI owns row content and actions; AppKit owns the table and its diff.
struct SessionTable: NSViewRepresentable {
    static let cornerRadius: CGFloat = 6
    let store: ChatLibrary
    let sessions: [SessionSummary]
    let reduceMotion: Bool
    let open: (UUID) -> Void
    let rename: (SessionSummary) -> Void
    let delete: (SessionSummary) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        // Clip scrolling/entering rows at the same rounded boundary as each row,
        // without masking the scrollbar or involving SwiftUI animation transactions.
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.cornerRadius = Self.cornerRadius
        scroll.contentView.layer?.masksToBounds = true
        let table = SidebarTableView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.table = table
        table.makeCell = { [weak coordinator] id, reusable in
            coordinator?.cell(id, reusing: reusable) ?? NSView()
        }
        table.activate = { [weak coordinator] id in
            guard let coordinator, coordinator.parent.store.canNavigate else { return }
            coordinator.parent.open(id)
        }
        table.canMove = { [weak coordinator] in coordinator?.parent.store.canReorderSessions == true }
        table.move = { [weak coordinator] id, nextID in
            guard let coordinator else { return false }
            let store = coordinator.parent.store
            guard store.canReorderSessions,
                  store.sidebarSessions.contains(where: { $0.id == id }),
                  nextID == nil || store.sidebarSessions.contains(where: { $0.id == nextID }) else { return false }
            store.moveSession(id, before: nextID)
            // Commit immediately inside AppKit's drop callback. A later SwiftUI
            // update with the same IDs only refreshes content, not the snapshot.
            coordinator.updateSessions(store.sidebarSessions)
            return true
        }
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateSessions(sessions)
    }

    @MainActor final class Coordinator {
        var parent: SessionTable
        weak var table: SidebarTableView?
        private var summaries: [UUID: SessionSummary] = [:]
        private var shortcuts: [UUID: Int] = [:]

        init(_ parent: SessionTable) { self.parent = parent }

        func updateSessions(_ sessions: [SessionSummary]) {
            summaries = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            shortcuts = Dictionary(uniqueKeysWithValues: sessions.prefix(9).enumerated().map { ($0.element.id, $0.offset + 1) })
            table?.update(ids: sessions.map(\.id), animated: !parent.reduceMotion)
        }

        func cell(_ id: UUID, reusing view: NSView?) -> NSView {
            guard let session = summaries[id] else { return view ?? NSView() }
            let content = SessionTableRow(session: session, store: parent.store, shortcut: shortcuts[id],
                                          open: parent.open, rename: parent.rename, delete: parent.delete)
            if let host = view as? SidebarRowHostingView<SessionTableRow> {
                host.rootView = content
                return host
            }
            let host = SidebarRowHostingView(rootView: content)
            host.sizingOptions = [.intrinsicContentSize]
            return host
        }
    }
}

private struct SessionTableRow: View {
    let session: SessionSummary
    let store: ChatLibrary
    let shortcut: Int?
    let open: (UUID) -> Void
    let rename: (SessionSummary) -> Void
    let delete: (SessionSummary) -> Void

    var body: some View {
        SessionRow(session: session, store: store, shortcut: shortcut,
                   rename: { rename(session) }, delete: { delete(session) })
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SessionTable.cornerRadius, style: .circular)
                .fill(store.sidebarSelectionID == session.id ? Color.primary.opacity(0.08) : Color.clear))
            .accessibilityAction { if store.canNavigate { open(session.id) } }
            .accessibilityAddTraits(store.sidebarSelectionID == session.id ? [.isSelected] : [])
            .focusable(false)
    }
}
