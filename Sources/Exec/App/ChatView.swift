import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatLibrary
    let windows: SessionWindows
    @FocusState private var composerFocused: Bool
    @Environment(\.openWindow) private var openWindow

    private struct ComposerFocusTarget: Hashable {
        let conversation: ObjectIdentifier
        let request: Int
        let navigating: Bool
        let authenticating: Bool
    }

    var body: some View {
        ConversationView(library: store, conversation: store.current,
                         presentation: windows.presentation(for: store.current),
                         focused: $composerFocused, showsNavigationError: true)
            .task(id: ComposerFocusTarget(conversation: ObjectIdentifier(store.current),
                                          request: windows.composerFocusRequest,
                                          navigating: store.navigating,
                                          authenticating: store.authenticating)) {
                // Wait until local restoration/navigation enables the composer.
                guard !store.navigating, !store.authenticating else { return }
                composerFocused = false
                await Task.yield()
                guard !Task.isCancelled, !store.navigating, !store.authenticating else { return }
                composerFocused = true
            }
            .id(ObjectIdentifier(store.current))
            .transaction(value: ObjectIdentifier(store.current)) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .modifier(SessionCommandScope(windows: windows, conversation: store.current))
            .background(WindowReference { windows.mainWindow = $0 })
            .onChange(of: store.detachedSessionIDs) { _, _ in windows.closeInvalidWindows() }
            .onAppear { windows.reopenMainWindow = { openWindow(id: "chat") } }
    }
}
