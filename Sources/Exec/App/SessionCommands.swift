import SwiftUI

struct SessionWindowActions {
    var delete: (@MainActor () -> Void)?
    var detach: (@MainActor () -> Void)?
    var attach: (@MainActor () -> Void)?
}

private struct SessionWindowActionsKey: FocusedValueKey {
    typealias Value = SessionWindowActions
}

extension FocusedValues {
    var sessionWindowActions: SessionWindowActions? {
        get { self[SessionWindowActionsKey.self] }
        set { self[SessionWindowActionsKey.self] = newValue }
    }
}

/// Scope commands to a conversation window, not whichever control has focus.
struct SessionCommandScope: ViewModifier {
    let windows: SessionWindows
    let conversation: ChatStore
    @State private var pendingDeletion: SessionSummary?

    private var actions: SessionWindowActions {
        let library = windows.library
        var actions = SessionWindowActions()
        guard let id = conversation.currentSessionID,
              let session = library.sessionList.first(where: { $0.id == id }) else { return actions }
        if library.canDeleteSession(id) {
            actions.delete = { pendingDeletion = session }
        }
        if library.detachedSessionIDs.contains(id) {
            actions.attach = { windows.attach(id) }
        } else if library.canReorderSessions, !session.unreadable {
            actions.detach = { windows.detach(id) }
        }
        return actions
    }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.sessionWindowActions, actions)
            .alert("Delete Conversation?", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { session in
                Button("Delete", role: .destructive) {
                    // Retain the original target across focus/selection changes,
                    // and recheck eligibility when the confirmation is accepted.
                    windows.library.deleteSession(session.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { session in
                Text("Delete “\(session.title)”? This cannot be undone.")
            }
    }
}

/// Menu shortcuts work even when the composer is focused or the sidebar is hidden.
struct SessionCommands: Commands {
    let store: ChatLibrary?
    let windows: SessionWindows?
    @FocusedValue(\.sessionWindowActions) private var actions

    var body: some Commands {
        CommandMenu("Sessions") {
            Button("New Session") {
                store?.newConversation()
                windows?.showMainWindow()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(store?.canNavigate != true)

            Button("Delete Conversation", role: .destructive) {
                actions?.delete?()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(actions?.delete == nil)

            if let attach = actions?.attach {
                Button("Move Back to Main Window", action: attach)
                    .keyboardShortcut("w", modifiers: .command)
            } else {
                Button("Detach Window") { actions?.detach?() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(actions?.detach == nil)
            }

            Divider()

            if let store {
                ForEach(store.sessionShortcuts, id: \.session.id) { shortcut in
                    Button {
                        windows?.openSession(shortcut.session.id)
                        windows?.showMainWindow()
                    } label: {
                        Text(verbatim: shortcut.session.title)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(shortcut.number))), modifiers: .command)
                    .disabled(!store.canNavigate)
                }
            }
        }
    }
}
