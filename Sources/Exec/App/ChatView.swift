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
    }

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
                .task(id: ComposerFocusTarget(conversation: ObjectIdentifier(store.current),
                                              request: windows.composerFocusRequest,
                                              navigating: store.navigating)) {
                    // Deletion mounts the replacement before navigation finishes.
                    // Wait until its composer is enabled before requesting focus.
                    guard !store.navigating else { return }
                    composerFocused = false
                    await Task.yield()
                    guard !Task.isCancelled, !store.navigating else { return }
                    composerFocused = true
                }
                .id(ObjectIdentifier(store.current))
                .transaction(value: ObjectIdentifier(store.current)) { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarItem(placement: .primaryAction) {
                            WorkspaceBar(root: store.workspace?.root)
                                .frame(maxWidth: 300)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .primaryAction) {
                            WorkspaceBar(root: store.workspace?.root)
                                .frame(maxWidth: 300)
                        }
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 480)
        .modifier(SessionCommandScope(windows: windows, conversation: store.current))
        .background(WindowReference { windows.mainWindow = $0 })
        .onChange(of: store.detachedSessionIDs) { _, _ in windows.closeInvalidWindows() }
        .onAppear { windows.reopenMainWindow = { openWindow(id: "chat") } }
    }
}
