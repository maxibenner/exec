import SwiftUI

private struct DeleteSidebarSessionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var deleteSidebarSession: (@MainActor () -> Void)? {
        get { self[DeleteSidebarSessionKey.self] }
        set { self[DeleteSidebarSessionKey.self] = newValue }
    }
}

/// Menu shortcuts work even when the composer is focused or the sidebar is hidden.
struct SessionCommands: Commands {
    let store: ChatLibrary?
    @FocusedValue(\.deleteSidebarSession) private var deleteSidebarSession

    var body: some Commands {
        CommandMenu("Sessions") {
            Button("New Session") {
                store?.newConversation()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(store?.canNavigate != true)

            Button("Delete Conversation", role: .destructive) {
                deleteSidebarSession?()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(deleteSidebarSession == nil)

            Divider()

            if let store {
                ForEach(store.sessionShortcuts, id: \.session.id) { shortcut in
                    Button {
                        store.openSession(shortcut.session.id)
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
