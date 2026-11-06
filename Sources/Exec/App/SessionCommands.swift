import SwiftUI

private struct DeleteSidebarSessionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

private struct DetachSidebarSessionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var detachSidebarSession: (@MainActor () -> Void)? {
        get { self[DetachSidebarSessionKey.self] }
        set { self[DetachSidebarSessionKey.self] = newValue }
    }

    var deleteSidebarSession: (@MainActor () -> Void)? {
        get { self[DeleteSidebarSessionKey.self] }
        set { self[DeleteSidebarSessionKey.self] = newValue }
    }
}

/// Menu shortcuts work even when the composer is focused or the sidebar is hidden.
struct SessionCommands: Commands {
    let store: ChatLibrary?
    let windows: SessionWindows?
    @FocusedValue(\.deleteSidebarSession) private var deleteSidebarSession
    @FocusedValue(\.detachSidebarSession) private var detachSidebarSession

    var body: some Commands {
        CommandMenu("Sessions") {
            Button("New Session") {
                store?.newConversation()
                windows?.showMainWindow()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(store?.canNavigate != true)

            Button("Delete Conversation", role: .destructive) {
                deleteSidebarSession?()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(deleteSidebarSession == nil || windows?.activeDetachedID != nil)

            if let id = windows?.activeDetachedID {
                Button("Move Back to Main Window") { windows?.attach(id) }
            } else {
                Button("Open in New Window") { detachSidebarSession?() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(detachSidebarSession == nil)
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
