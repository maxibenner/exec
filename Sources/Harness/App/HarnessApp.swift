import SwiftUI

@main struct HarnessApp: App {
    private let store: ChatStore?
    private let startupError: String?

    init() {
        do {
            store = ChatStore(provider: try OpenAIProvider())
            startupError = nil
        } catch {
            store = nil
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        Window("Harness", id: "chat") {
            if let store {
                ChatView(store: store)
            } else {
                Text(startupError ?? "Unable to start.").padding().frame(width: 500, height: 200)
            }
        }
        .defaultSize(width: 760, height: 580)
    }
}
