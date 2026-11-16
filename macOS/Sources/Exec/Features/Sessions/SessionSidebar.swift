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

    private var selection: Binding<UUID?> {
        Binding(get: { store.sidebarSelectionID }, set: { id in
            guard store.canNavigate, let id, id != store.sidebarSelectionID else { return }
            open(id)
        })
    }

    var body: some View {
        let sessions = store.sidebarSessions
        let shortcutIDs = displayedSessions.prefix(9).map(\.id)
        List(selection: selection) {
            ForEach(displayedSessions) { session in
                SessionRow(session: session, store: store,
                           shortcut: shortcutIDs.firstIndex(of: session.id).map { $0 + 1 },
                           rename: {
                               guard store.canNavigate, !store.isSessionRunning(session.id) else { return }
                               renameID = session.id; renameTitle = session.title; renaming = true
                           }, delete: { delete(session) })
                    .tag(session.id)
                    .moveDisabled(!store.canReorderSessions)
            }
            .onMove { offsets, destination in
                // Offsets must still refer to the current catalog when a drag ends.
                guard displayedSessions.map(\.id) == store.sidebarSessions.map(\.id) else { return }
                store.moveSidebarSessions(from: offsets, to: destination)
            }
        }
        .listStyle(.sidebar)
        // Select conversations without making the sidebar a keyboard-focus target.
        // Conversation shortcuts remain available through SessionCommands.
        .focusable(false)
        .onChange(of: sessions) { _, updated in
            let structuralChange = displayedSessions.map(\.id) != updated.map(\.id)
            withAnimation(structuralChange && !reduceMotion ? .default : nil) {
                displayedSessions = updated
            }
        }
        .disabled(!store.canNavigate)
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
