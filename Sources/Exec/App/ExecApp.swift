import SwiftUI

@main struct ExecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: ChatLibrary?
    @State private var windows: SessionWindows?
    @State private var startupError: String?
    @State private var starting = false

    var body: some Scene {
        Window("Exec", id: "chat") {
            ChatWindowLayout(workspace: store?.workspace?.root) {
                if let store, let windows {
                    SessionSidebar(store: store, open: { windows.openSession($0) }, delete: {
                        guard store.canNavigate, !store.isSessionRunning($0.id) else { return }
                        store.deleteSession($0.id)
                    })
                } else {
                    Color.clear
                }
            } detail: {
                if let store, let windows {
                    ChatView(store: store, windows: windows)
                } else if let startupError {
                    VStack(spacing: 16) {
                        Text(startupError).textSelection(.enabled)
                        Button("Try Again", action: start)
                    }
                    .padding().frame(maxWidth: 480)
                } else {
                    Color.clear
                }
            }
            .task { if store == nil && startupError == nil { start() } }
        }
        .defaultSize(width: 980, height: 700)
        .commands { SessionCommands(store: store, windows: windows) }

        Settings {
            if let store {
                SettingsView(store: store)
            }
        }
        .defaultSize(width: 500, height: 420)
        .windowResizability(.contentSize)
    }

    private func start() {
        guard !starting else { return }
        starting = true
        startupError = nil
        Task { @MainActor in
            defer { starting = false }
            do {
                let provider = try await OpenAIProvider.restored()
                let library = try ChatLibrary(provider: provider, sessions: try SessionStore.applicationStore(),
                                              metadataCache: AccountMetadataCache.applicationCache())
                library.restore()
                store = library
                windows = SessionWindows(library: library)
                delegate.store = library
            } catch {
                startupError = error.localizedDescription
            }
        }
    }
}
