import SwiftUI

@main struct ExecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: ChatLibrary?
    @State private var windows: SessionWindows?
    @State private var startupError: String?
    @State private var starting = false

    var body: some Scene {
        Window("Exec", id: "chat") {
            Group {
                if let store, let windows {
                    ChatView(store: store, windows: windows)
                } else if let startupError {
                    VStack(spacing: 16) {
                        Text(startupError).textSelection(.enabled)
                        Button("Try Again", action: start)
                    }
                    .padding().frame(maxWidth: 480)
                } else {
                    ProgressView().accessibilityLabel("Opening Exec")
                }
            }
            .frame(minWidth: 720, minHeight: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                let library = try ChatLibrary(provider: provider, sessions: try SessionStore.applicationStore())
                store = library
                windows = SessionWindows(library: library)
                delegate.store = library
                library.restore()
            } catch {
                startupError = error.localizedDescription
            }
        }
    }
}
