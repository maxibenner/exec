import SwiftUI

@main struct HarnessApp: App {
    @State private var store: ChatStore?
    @State private var startupError: String?

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
                    .padding().frame(width: 500, height: 200)
                } else {
                    ProgressView().frame(width: 500, height: 200)
                }
            }
            .task { if store == nil && startupError == nil { start() } }
        }
        .defaultSize(width: 760, height: 580)
    }

    private func start() {
        do {
            store = ChatStore(provider: try OpenAIProvider(), sessions: try SessionStore.applicationStore())
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }
}
