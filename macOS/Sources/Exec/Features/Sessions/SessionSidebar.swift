import SwiftUI

private struct SidebarSessionGroup: Identifiable, Equatable {
    let session: SessionSummary
    let children: [SessionSummary]
    var id: UUID { session.id }

    @MainActor static func snapshot(_ store: ChatLibrary) -> [Self] {
        // Build the ordered catalog once, not once again for every parent.
        let sessions = store.sessionList
        var children: [UUID: [SessionSummary]] = [:]
        for session in sessions {
            if let parent = session.parent?.sessionId { children[parent, default: []].append(session) }
        }
        return sessions.filter { $0.parent == nil && !store.detachedSessionIDs.contains($0.id) }
            .map { Self(session: $0, children: children[$0.id] ?? []) }
    }
}

struct SessionSidebar: View {
    @Bindable var store: ChatLibrary
    let open: (UUID) -> Void
    let delete: (SessionSummary) -> Void
    @State private var renaming = false
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var rowBackgroundWidths: [UUID: CGFloat] = [:]
    private var groups: [SidebarSessionGroup] { SidebarSessionGroup.snapshot(store) }

    private func activate(_ id: UUID) {
        guard store.canNavigate else { return }
        open(id)
    }

    var body: some View {
        let sessions = groups
        let shortcutIDs = sessions.prefix(9).map(\.id)
        List {
            ForEach(sessions) { group in
                let session = group.session
                VStack(alignment: .leading, spacing: 2) {
                    SessionRow(session: session, store: store,
                               rename: {
                                   guard store.canRenameSession(session.id) else { return }
                                   renameID = session.id; renameTitle = session.title; renaming = true
                               }, delete: { delete(session) })
                        .onTapGesture { activate(session.id) }
                        .accessibilityAction { activate(session.id) }
                        .accessibilityAddTraits(store.sidebarSelectionID == session.id ? [.isSelected] : [])
                    ForEach(group.children) { child in
                        HStack(spacing: 6) {
                            Text(verbatim: child.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            if store.needsApproval(child.id) {
                                Image(systemName: "hand.raised").foregroundStyle(.orange)
                                    .accessibilityLabel("Approval required")
                            } else if store.needsAttention(child.id) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            } else if store.isSessionWaiting(child.id) {
                                Image(systemName: "stopwatch").foregroundStyle(.green)
                                    .accessibilityLabel("Waiting")
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(store.sidebarSelectionID == child.id ? Color.primary.opacity(0.08) : Color.clear)
                                .frame(width: rowBackgroundWidths[session.id])
                        }
                        .onTapGesture { activate(child.id) }
                        .accessibilityAction { activate(child.id) }
                        .accessibilityAction(named: "Delete Sub-agent") {
                            if store.canDeleteSession(child.id) { delete(child) }
                        }
                        .accessibilityAddTraits(store.sidebarSelectionID == child.id ? [.isSelected] : [])
                        .overlay {
                            SessionContextMenu(items: [
                                .action("Delete Sub-agent", enabled: store.canDeleteSession(child.id)) { delete(child) }
                            ])
                        }
                    }
                    SessionRowMetadata(session: session, shortcut: shortcutIDs.firstIndex(of: session.id).map { $0 + 1 })
                        .padding(.top, 3).padding(.bottom, 5)
                        .contentShape(Rectangle())
                        .onTapGesture { activate(session.id) }
                        .accessibilityAction { activate(session.id) }
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(store.sidebarSelectionID == session.id
                              ? Color.primary.opacity(0.08) : Color.clear)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                            rowBackgroundWidths[session.id] = $0
                        }
                )
                .moveDisabled(!store.canReorderSessions)
            }
            .onMove { offsets, destination in
                withAnimation {
                    store.moveSidebarSessions(from: offsets, to: destination)
                }
            }
        }
        .listStyle(.sidebar)
        .padding(.horizontal, 10)
        .animation(.default, value: sessions)
        .alert("Rename Conversation", isPresented: $renaming) {
            TextField("Name", text: $renameTitle)
            Button("Rename") {
                if let id = renameID { store.renameSession(id, title: renameTitle) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct SessionRowMetadata: View {
    let session: SessionSummary
    let shortcut: Int?

    var body: some View {
        HStack {
            if let shortcut {
                Text("⌘\(shortcut)").monospacedDigit().fixedSize()
                    .help("Switch to session (⌘\(shortcut))")
                    .accessibilityLabel("Keyboard shortcut: Command \(shortcut)")
            }
            if let workspace = session.workspace {
                Text(URL(fileURLWithPath: workspace).lastPathComponent).lineLimit(1).help(workspace)
            }
            Spacer(minLength: 4)
            if !session.unreadable {
                Text(session.updatedAt, format: .dateTime.month(.abbreviated).day()).fixedSize()
                    .help(session.updatedAt.formatted(date: .long, time: .shortened))
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let store: ChatLibrary
    private var needsApproval: Bool { store.needsApproval(session.id) }
    private var needsAttention: Bool { store.needsAttention(session.id) }
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: session.title).font(.body.weight(.regular)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if needsApproval {
                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                        .help("Approval required").accessibilityLabel("Approval required")
                } else if needsAttention {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        .help("Conversation needs attention").accessibilityLabel("Conversation needs attention")
                } else if store.isSessionWaiting(session.id) {
                    Image(systemName: "stopwatch").foregroundStyle(.green)
                        .accessibilityLabel("Waiting")
                } else if store.isSessionResponding(session.id) {
                    ProgressView().controlSize(.mini).accessibilityLabel("Running")
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 20)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .overlay {
            SessionContextMenu(items: [
                .action("Rename…", enabled: store.canRenameSession(session.id), perform: rename),
                .separator,
                .action("Delete Conversation", enabled: store.canDeleteSession(session.id), perform: delete)
            ])
        }
        .accessibilityAction(named: "Rename Conversation") { if store.canRenameSession(session.id) { rename() } }
        .accessibilityAction(named: "Delete Conversation") { if store.canDeleteSession(session.id) { delete() } }
    }
}
