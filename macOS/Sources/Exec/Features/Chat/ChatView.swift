import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatLibrary
    let windows: SessionWindows
    @FocusState private var composerFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ConversationView(library: store, conversation: store.current,
                         presentation: windows.presentation(for: store.current),
                         focused: $composerFocused, showsNavigationError: true,
                         composerFocusRequest: windows.composerFocusRequest)
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
