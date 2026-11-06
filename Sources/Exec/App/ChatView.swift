import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatLibrary
    let windows: SessionWindows
    @FocusState private var composerFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, open: { windows.openSession($0) }, delete: {
                guard store.canNavigate, !store.isSessionRunning($0.id) else { return }
                store.deleteSession($0.id)
            })
        } detail: {
            ConversationView(library: store, conversation: store.current,
                             presentation: windows.presentation(for: store.current),
                             focused: $composerFocused, showsNavigationError: true)
                .id(ObjectIdentifier(store.current))
                .transaction(value: ObjectIdentifier(store.current)) { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { store.newConversation(); composerFocused = true } label: {
                            Label("New Conversation", systemImage: "square.and.pencil")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .help("New conversation (⌘N)")
                        .disabled(!store.canNavigate)
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 480)
        .modifier(SessionCommandScope(windows: windows, conversation: store.current))
        .background(WindowReference { windows.mainWindow = $0 })
        .onChange(of: store.detachedSessionIDs) { _, _ in windows.closeInvalidWindows() }
        .onAppear { windows.reopenMainWindow = { openWindow(id: "chat") } }
        .task(id: windows.composerFocusRequest) {
            // Let the replacement composer mount and the list finish handling selection.
            composerFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            composerFocused = true
        }
    }
}
