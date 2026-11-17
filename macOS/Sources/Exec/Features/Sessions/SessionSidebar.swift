import SwiftUI

private struct SidebarSessionGroup: Identifiable, Equatable {
    let session: SessionSummary
    let children: [SessionSummary]
    var id: UUID { session.id }
}

struct SessionSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: ChatLibrary
    let open: (UUID) -> Void
    let delete: (SessionSummary) -> Void
    @State private var renaming = false
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    private let horizontalPadding: CGFloat = 12
    private var rowAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.25) }

    // A presentation snapshot gives asynchronous catalog changes an explicit
    // transaction before List reconciles its native rows. No timers or delays.
    // Children are part of the native row's presentation snapshot, so catalog
    // changes invalidate its height without replacing its stable parent identity.
    @State private var displayedGroups: [SidebarSessionGroup]
    // Keep appearance state above List's recycled rows. Scrolling an existing
    // child back into view must not replay its insertion fade.
    @State private var revealedChildIDs: Set<UUID>
    private var groups: [SidebarSessionGroup] {
        store.sidebarSessions.map { SidebarSessionGroup(session: $0, children: store.childSessions(of: $0.id)) }
    }

    init(store: ChatLibrary, open: @escaping (UUID) -> Void,
         delete: @escaping (SessionSummary) -> Void) {
        self.store = store
        self.open = open
        self.delete = delete
        let initial = store.sidebarSessions.map {
            SidebarSessionGroup(session: $0, children: store.childSessions(of: $0.id))
        }
        _displayedGroups = State(initialValue: initial)
        _revealedChildIDs = State(initialValue: Set(initial.flatMap { $0.children.map(\.id) }))
    }

    private func activate(_ id: UUID) {
        guard store.canNavigate else { return }
        open(id)
    }

    var body: some View {
        let sessions = groups
        let shortcutIDs = displayedGroups.prefix(9).map(\.id)
        // The library owns the active session; do not give the native table a
        // selection binding (its active selection can turn blue on mouse-down).
        List {
            ForEach(displayedGroups) { group in
                let session = group.session
                VStack(alignment: .leading, spacing: 2) {
                    SessionRow(session: session, store: store,
                               rename: {
                                   guard store.canNavigate, !store.isSessionRunning(session.id) else { return }
                                   renameID = session.id; renameTitle = session.title; renaming = true
                               }, delete: { delete(session) })
                        .padding(.horizontal, horizontalPadding)
                        // A row-wide Button interferes with native drag reordering.
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .padding(.horizontal, horizontalPadding)
                        .contentShape(Rectangle())
                        .background(store.sidebarSelectionID == child.id ? Color.primary.opacity(0.08) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .modifier(SidebarChildAppearance(visible: revealedChildIDs.contains(child.id), animation: rowAnimation) {
                            revealedChildIDs.insert(child.id)
                        })
                        .transition(.opacity)
                        .onTapGesture { activate(child.id) }
                        .accessibilityAction { activate(child.id) }
                        .accessibilityAction(named: "Delete Sub-agent") {
                            if store.canDeleteSession(child.id) { delete(child) }
                        }
                        .accessibilityAddTraits(store.sidebarSelectionID == child.id ? [.isSelected] : [])
                        .contextMenu {
                            Button("Delete Sub-agent", role: .destructive) { delete(child) }
                                .disabled(!store.canDeleteSession(child.id))
                        }
                    }
                    SessionRowMetadata(session: session, shortcut: shortcutIDs.firstIndex(of: session.id).map { $0 + 1 })
                        .padding(.top, 3).padding(.bottom, 5)
                        .padding(.horizontal, horizontalPadding)
                        .contentShape(Rectangle())
                        .onTapGesture { activate(session.id) }
                        .accessibilityAction { activate(session.id) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(SidebarAnimatedHeight(children: group.children.map(\.id), animation: rowAnimation))
                // macOS sidebar rows retain a 16-point content gutter even
                // with zero listRowInsets. Cancel it on the content only; keep
                // the native row background and the list's outer margin intact.
                .padding(.horizontal, -16)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(store.sidebarSelectionID == session.id
                              ? Color.primary.opacity(0.08) : Color.clear)
                )
                .moveDisabled(!store.canReorderSessions)
            }
            .onMove { offsets, destination in
                // Offsets must still refer to the current catalog when a drag ends.
                guard displayedGroups.map(\.id) == store.sidebarSessions.map(\.id) else { return }
                store.moveSidebarSessions(from: offsets, to: destination)
                // Commit in the native drop transaction, not a later catalog animation.
                displayedGroups = groups
                revealedChildIDs.formIntersection(displayedGroups.flatMap { $0.children.map(\.id) })
            }
        }
        .listStyle(.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        // Select conversations without making the sidebar a keyboard-focus target.
        // Conversation shortcuts remain available through SessionCommands.
        .focusable(false)
        .onChange(of: sessions) { _, updated in
            guard displayedGroups != updated else { return }
            let previousStructure = displayedGroups.map { [$0.id] + $0.children.map(\.id) }
            let nextStructure = updated.map { [$0.id] + $0.children.map(\.id) }
            let structuralChange = previousStructure != nextStructure
            withAnimation(structuralChange ? rowAnimation : nil) {
                revealedChildIDs.formIntersection(updated.flatMap { $0.children.map(\.id) })
                displayedGroups = updated
            }
        }
        // Keep native row appearance stable during deletion and reordering.
        // Activation/mutation guards block conflicting actions without dimming
        // and re-enabling the entire list (which flashes all child rows).
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
    private var running: Bool { store.isSessionRunning(session.id) }
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
        .contextMenu {
            Button("Rename…", action: rename).disabled(session.unreadable || store.navigating || running)
            Divider()
            Button("Delete Conversation", role: .destructive, action: delete).disabled(!store.canDeleteSession(session.id))
        }
        .accessibilityAction(named: "Rename Conversation") { if !session.unreadable { rename() } }
        .accessibilityAction(named: "Delete Conversation") { if store.canDeleteSession(session.id) { delete() } }
    }
}
