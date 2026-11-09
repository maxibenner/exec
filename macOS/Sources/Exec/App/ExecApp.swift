import SwiftUI

@main struct ExecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let initiallyHasSavedSessions = SessionStore.applicationHasSavedSessions()
    @State private var startup = ChatStartup()
    @StateObject private var updater = SparkleUpdater()
    @State private var windowGeometry = MainWindowGeometry()
    @State private var hasPresentedMainWindow = false
    @State private var hasStarted = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        startupWindow

        Settings {
            if let store = startup.store {
                SettingsView(store: store, canCheckForUpdates: updater.canCheckForUpdates,
                             checkForUpdates: updater.checkForUpdates)
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
                    .defaultLaunchBehavior(hasPresentedMainWindow ? .automatic : .suppressed)
                    .defaultWindowPlacement { content, context in
                        // Configure before ordering onscreen; the view's window
                        // reference can attach after the opening animation starts.
                        windowGeometry.observe(NSApp.windows.first { $0.identifier?.rawValue == "chat" })
                        guard let placement = windowGeometry.placement(
                            minimumContentSize: content.sizeThatFits(.zero),
                            defaultDisplayBounds: context.defaultDisplay.bounds) else { return WindowPlacement() }
                        return WindowPlacement(placement.position, size: placement.size)
                    }
                    .onChange(of: scenePhase, initial: true) { _, _ in
                        guard !hasStarted else { return }
                        hasStarted = true
                        start()
                    }
                    .onChange(of: startup.isReadyForPresentation, initial: true) { _, ready in
                        guard ready, !hasPresentedMainWindow else { return }
                        hasPresentedMainWindow = true
                        openWindow(id: "chat")
                    }))
        } else {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(chatWindow))
        }
    }

    private var chatWindow: some Scene {
        Window("", id: "chat") {
            ChatWindowLayout(initiallyShowsSidebar: initiallyHasSavedSessions,
                             sidebarRevealRequest: startup.windows?.sidebarRevealRequest ?? 0) {
                Group {
                    if let store = startup.store, let windows = startup.windows {
                        SessionSidebar(store: store, open: { windows.openSession($0) }, delete: {
                            guard store.canNavigate, !store.isSessionRunning($0.id) else { return }
                            store.deleteSession($0.id)
                        })
                    } else {
                        Color.clear
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if updater.notice.isVisible {
                        UpdateBadge(canCheckForUpdates: updater.canCheckForUpdates,
                                    update: updater.checkForUpdates, dismiss: updater.notice.dismiss)
                            .padding(12)
                    }
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
            .task {
                // macOS 14 lacks suppressed scene launch; retain its existing path.
                if #unavailable(macOS 15.0), startup.store == nil, startup.error == nil { start() }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { updater.checkSilentlyIfNeeded() }
            }
            .onChange(of: startup.store.map(ObjectIdentifier.init), initial: true) { _, _ in
                delegate.store = startup.store
            }
        }
        .defaultSize(width: 980, height: 700)
        .commands { SessionCommands(store: startup.store, windows: startup.windows) }
    }

    private func start() {
        startup.start(makeSessions: SessionStore.applicationStore, cache: AccountMetadataCache.applicationCache(),
                      localPresentation: ProviderRegistry.localPresentation()) {
            try await MultiProvider(registry: ProviderRegistry.restored())
        }
    }
}
