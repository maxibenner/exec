import SwiftUI

@main struct HarnessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: ChatLibrary?
    @State private var startupError: String?
    @State private var starting = false

    var body: some Scene {
        Window("Harness", id: "chat") {
            Group {
                if let store {
                    ChatView(store: store)
                } else if let startupError {
                    VStack(spacing: 16) {
                        Text(startupError).textSelection(.enabled)
                        Button("Try Again", action: start)
                    }
                    .padding().frame(maxWidth: 480)
                } else {
                    ProgressView().accessibilityLabel("Opening Harness")
                }
            }
            .frame(minWidth: 720, minHeight: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { if store == nil && startupError == nil { start() } }
        }
        .defaultSize(width: 980, height: 700)
        .commands { SessionCommands(store: store) }
    }

    private func start() {
        guard !starting else { return }
        starting = true
        startupError = nil
        Task { @MainActor in
            defer { starting = false }
            do {
                let provider = try await OpenAIProvider.restored()
                store = try ChatLibrary(provider: provider, sessions: try SessionStore.applicationStore())
                delegate.store = store
            } catch {
                startupError = error.localizedDescription
            }
        }
    }
}
