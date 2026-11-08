import SwiftUI

@main struct ExecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let initiallyHasSavedSessions = SessionStore.applicationHasSavedSessions()
    @State private var startup = ChatStartup()
    @State private var windowGeometry = MainWindowGeometry()

    var body: some Scene {
        startupWindow

        Settings {
            if let store = startup.store {
                SettingsView(store: store)
            }
        }
        .defaultSize(width: 500, height: 560)
        .windowResizability(.contentSize)
    }

    private var startupWindow: some Scene {
        // SceneBuilder has no if/else support; erase both branches through its
        // availability wrapper to keep macOS 14 support without duplicating windows.
        if #available(macOS 15.0, *) {
            // Native restoration caused a visible startup resize. Supply our saved
            // geometry during initial placement instead, before the window appears.
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(
                chatWindow.restorationBehavior(.disabled)
                    .defaultWindowPlacement { content, context in
                        guard let placement = windowGeometry.placement(
                            minimumContentSize: content.sizeThatFits(.zero),
                            defaultDisplayBounds: context.defaultDisplay.bounds) else { return WindowPlacement() }
                        return WindowPlacement(placement.position, size: placement.size)
                    }))
        } else {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(chatWindow))
        }
    }

    private var chatWindow: some Scene {
        Window("Exec", id: "chat") {
            ChatWindowLayout(workspace: startup.store?.workspace?.root,
                             initiallyShowsSidebar: initiallyHasSavedSessions) {
                if let store = startup.store, let windows = startup.windows {
                    SessionSidebar(store: store, open: { windows.openSession($0) }, delete: {
                        guard store.canNavigate, !store.isSessionRunning($0.id) else { return }
                        store.deleteSession($0.id)
                    })
                } else {
                    Color.clear
                }
            } detail: {
                if let error = startup.error {
                    VStack(spacing: 16) {
                        Text(error).textSelection(.enabled)
                        Button("Try Again", action: start)
                    }
                    .padding().frame(maxWidth: 480)
                } else if let store = startup.store, let windows = startup.windows {
                    ChatView(store: store, windows: windows)
                        .overlay {
                            // Keep the first-frame empty state visible while the
                            // blank runner restores, without remounting ChatView.
                            if !initiallyHasSavedSessions, store.current.isRestoringSession,
                               !store.hasConversation(store.current) {
                                NoSessionsView()
                            }
                        }
                } else if !initiallyHasSavedSessions {
                    NoSessionsView()
                } else {
                    Color.clear
                }
            }
            .background(WindowReference { windowGeometry.observe($0) })
            .task { if startup.store == nil && startup.error == nil { start() } }
            .onChange(of: startup.store.map(ObjectIdentifier.init)) { _, _ in
                delegate.store = startup.store
            }
        }
        .defaultSize(width: 980, height: 700)
        .commands { SessionCommands(store: startup.store, windows: startup.windows) }
    }

    private func start() {
        startup.start(makeSessions: SessionStore.applicationStore, cache: AccountMetadataCache.applicationCache()) {
            try await MultiProvider(registry: ProviderRegistry.restored())
        }
    }
}
