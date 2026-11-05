import SwiftUI

/// Menu shortcuts work even when the composer is focused or the sidebar is hidden.
struct SessionCommands: Commands {
    let store: ChatLibrary?

    var body: some Commands {
        CommandMenu("Sessions") {
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
