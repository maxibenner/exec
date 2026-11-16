import SwiftUI

struct SessionSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: ChatLibrary
    let open: (UUID) -> Void
    let delete: (SessionSummary) -> Void
    @State private var renaming = false
    @State private var renameID: UUID?
    @State private var renameTitle = ""

    // A presentation snapshot gives asynchronous catalog changes an explicit
    // transaction before List reconciles its native rows. No timers or delays.
    @State private var displayedSessions: [SessionSummary]

    init(store: ChatLibrary, open: @escaping (UUID) -> Void,
         delete: @escaping (SessionSummary) -> Void) {
        self.store = store
        self.open = open
        self.delete = delete
        _displayedSessions = State(initialValue: store.sidebarSessions)
    }

    private func activate(_ id: UUID) {
        guard store.canNavigate else { return }
        open(id)
    }

    var body: some View {
        let sessions = store.sidebarSessions
        let shortcutIDs = displayedSessions.prefix(9).map(\.id)
        // The library owns the active session; do not give the native table a
        // selection binding (its active selection can turn blue on mouse-down).
        List {
            ForEach(displayedSessions) { session in
                VStack(alignment: .leading, spacing: 2) {
                    SessionRow(session: session, store: store,
                               shortcut: shortcutIDs.firstIndex(of: session.id).map { $0 + 1 },
                               rename: {
                                   guard store.canNavigate, !store.isSessionRunning(session.id) else { return }
                                   renameID = session.id; renameTitle = session.title; renaming = true
                               }, delete: { delete(session) })
                        // A row-wide Button interferes with native drag reordering.
                        .onTapGesture { activate(session.id) }
                        .accessibilityAction { activate(session.id) }
                        .accessibilityAddTraits(store.sidebarSelectionID == session.id ? [.isSelected] : [])
                    ForEach(store.childSessions(of: session.id)) { child in
                        Button { activate(child.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                                Text(verbatim: child.title).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                if store.needsApproval(child.id) {
                                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                                        .accessibilityLabel("Approval required")
                                } else if store.isSessionResponding(child.id) {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Running")
                                } else if store.needsAttention(child.id) {
                                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 12).padding(.vertical, 3)
                            .padding(.trailing, 4)
                            .contentShape(Rectangle())
                            .background(store.sidebarSelectionID == child.id ? Color.primary.opacity(0.08) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.sidebarSelectionID == child.id ? [.isSelected] : [])
                        .contextMenu {
                            Button("Delete Sub-agent", role: .destructive) { delete(child) }
                                .disabled(!store.canDeleteSession(child.id) || store.isSessionRunning(session.id))
                        }
                    }
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(store.sidebarSelectionID == session.id
                              ? Color.primary.opacity(0.08) : Color.clear)
                )
                .moveDisabled(!store.canReorderSessions)
            }
            .onMove { offsets, destination in
                // Offsets must still refer to the current catalog when a drag ends.
                guard displayedSessions.map(\.id) == store.sidebarSessions.map(\.id) else { return }
                store.moveSidebarSessions(from: offsets, to: destination)
                // Commit in the native drop transaction, not a later catalog animation.
                displayedSessions = store.sidebarSessions
            }
        }
        .listStyle(.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        // Select conversations without making the sidebar a keyboard-focus target.
        // Conversation shortcuts remain available through SessionCommands.
        .focusable(false)
        .onChange(of: sessions) { _, updated in
            guard displayedSessions != updated else { return }
            let structuralChange = displayedSessions.map(\.id) != updated.map(\.id)
            withAnimation(structuralChange && !reduceMotion ? .default : nil) {
                displayedSessions = updated
            }
        }
        // Do not disable the native table mid-drop. Action guards still prevent
        // navigation and additional mutations while the order is being persisted.
        .disabled(!store.canNavigate && !store.isReorderingSessions)
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

struct SessionRow: View {
    let session: SessionSummary
    let store: ChatLibrary
    let shortcut: Int?
    private var running: Bool { store.isSessionRunning(session.id) }
    private var needsApproval: Bool { store.needsApproval(session.id) }
    private var needsAttention: Bool { store.needsAttention(session.id) }
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: session.title).font(.body.weight(.regular)).lineLimit(2)
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
            Group {
                if needsApproval {
                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                        .help("Approval required").accessibilityLabel("Approval required")
                } else if store.isSessionResponding(session.id) {
                    ProgressView().controlSize(.mini).accessibilityLabel("Running")
                } else if needsAttention {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        .help("Conversation needs attention").accessibilityLabel("Conversation needs attention")
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 20)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…", action: rename).disabled(session.unreadable || store.navigating || running)
            Divider()
            Button("Delete Conversation", role: .destructive, action: delete).disabled(running)
        }
        .accessibilityAction(named: "Rename Conversation") { if !session.unreadable { rename() } }
        .accessibilityAction(named: "Delete Conversation") { if !running { delete() } }
    }
}
