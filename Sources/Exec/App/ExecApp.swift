import SwiftUI

@main struct ExecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var startup = ChatStartup()

    var body: some Scene {
        Window("Exec", id: "chat") {
            ChatWindowLayout(workspace: startup.store?.workspace?.root) {
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
                } else {
                    Color.clear
                }
            }
            .task { if startup.store == nil && startup.error == nil { start() } }
            .onChange(of: startup.store.map(ObjectIdentifier.init)) { _, _ in
                delegate.store = startup.store
            }
        }
        .defaultSize(width: 980, height: 700)
        .windowToolbarStyle(.unified)
        .commands { SessionCommands(store: startup.store, windows: startup.windows) }

        Settings {
            if let store = startup.store {
                SettingsView(store: store)
            }
        }
        .defaultSize(width: 500, height: 420)
        .windowResizability(.contentSize)
    }

    private func start() {
        startup.start(makeSessions: SessionStore.applicationStore, cache: AccountMetadataCache.applicationCache()) {
            try await OpenAIProvider.restored()
        }
    }
}
