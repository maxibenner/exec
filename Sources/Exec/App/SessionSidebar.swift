import SwiftUI

struct SessionSidebar: View {
    @Bindable var store: ChatLibrary
    let windows: SessionWindows
    let open: (UUID) -> Void
    let delete: (SessionSummary) -> Void
    @State private var renaming = false
    @State private var renameID: UUID?
    @State private var renameTitle = ""

    private var deleteSelection: (@MainActor () -> Void)? {
        guard store.canNavigate,
              let selected = store.sessionList.first(where: { $0.id == store.sidebarSelectionID }),
              !store.isSessionRunning(selected.id) else { return nil }
        return {
            guard store.canNavigate, store.sidebarSelectionID == selected.id,
                  !store.isSessionRunning(selected.id) else { return }
            delete(selected)
        }
    }

    var body: some View {
        SessionTable(store: store, windows: windows, open: open, delete: delete, rename: { session in
            guard store.canNavigate else { return }
            renameID = session.id; renameTitle = session.title; renaming = true
        })
        .disabled(store.authenticating)
        .allowsHitTesting(store.canNavigate)
        // Keep deletion scoped to sidebar focus; text fields retain their native
        // Command-Delete. The native table also handles this in its responder chain.
        .focusedValue(\.deleteSidebarSession, deleteSelection)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("Sessions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Group {
                    if let account = store.account {
                        Menu {
                            Button("Refresh Models", action: store.restore)
                            Button("Reconnect", action: store.connect)
                            Divider()
                            Button("Sign Out", role: .destructive) {
                                if store.canNavigate && !store.accountBusy { store.disconnect() }
                            }
                        } label: {
                            Label { Text(verbatim: account).lineLimit(1).truncationMode(.middle) }
                            icon: { Image(systemName: "person.crop.circle") }
                        }
                        .menuStyle(.borderlessButton).help(account).accessibilityLabel("Account: \(account)")
                    } else {
                        Button(store.connectionTitle, action: store.connect)
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    }
                }
                .disabled(store.accountBusy).allowsHitTesting(store.canNavigate).padding(14)
            }
        }
        .alert("Rename Conversation", isPresented: $renaming) {
            TextField("Name", text: $renameTitle)
            Button("Rename") {
                if let id = renameID { store.renameSession(id, title: renameTitle) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
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
    let detach: () -> Void
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
                } else if running {
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
            Button("Open in New Window", action: detach).disabled(session.unreadable || !store.canReorderSessions)
            Button("Rename…", action: rename).disabled(session.unreadable || store.navigating)
            Divider()
            Button("Delete Conversation", role: .destructive, action: delete).disabled(running)
        }
        .accessibilityAction(named: "Rename Conversation") { if !session.unreadable { rename() } }
        .accessibilityAction(named: "Delete Conversation") { if !running { delete() } }
    }
}
