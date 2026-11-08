import AppKit
import Observation
import SwiftUI

@MainActor struct StartupWindowTests {
    @Observable fileprivate final class Presentation {
        var library: ChatLibrary?
        var failed = false
    }

    private struct Fixture: View {
        let presentation: Presentation
        @State private var transcript = TranscriptState()
        @FocusState private var focused: Bool

        var body: some View {
            ChatWindowLayout(workspace: presentation.library?.workspace?.root) {
                if let library = presentation.library {
                    SessionSidebar(store: library, open: { _ in }, delete: { _ in })
                } else {
                    Color.clear
                }
            } detail: {
                if let library = presentation.library {
                    ConversationView(library: library, conversation: library.current,
                                     presentation: transcript, focused: $focused)
                } else if presentation.failed {
                    VStack(spacing: 16) {
                        Text("Local setup failed")
                        Button("Try Again") { }
                    }
                    .padding().frame(maxWidth: 480)
                } else {
                    Color.clear
                }
            }
        }
    }

    func preservesGeometryAcrossStartup() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = FakeProvider()
        let messages = [Message(role: .user, text: "Restored conversation")]
        _ = try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity,
            workspace: Workspace.load(root), selectedModel: "test", messages: messages,
            history: messages, activeTurn: false), id: UUID())
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        defer { library.stopAll() }
        library.restore()
        for _ in 0..<400 where library.hasRunningOperations {
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(!library.hasRunningOperations && library.workspace != nil)

        for size in [NSSize(width: 980, height: 700), NSSize(width: 720, height: 480)] {
            let presentation = Presentation()
            let controller = NSHostingController(rootView: Fixture(presentation: presentation))
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(size)
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await settle(window)
            let frame = window.frame
            let content = window.contentLayoutRect
            let toolbar = window.toolbar
            try expect(toolbar != nil)
            let minimum = controller.view.fittingSize
            for stage in 0..<3 {
                presentation.failed = stage == 0
                presentation.library = stage == 2 ? library : nil
                try await settle(window)
                guard window.frame == frame else {
                    throw CheckFailure(description: "Startup stage \(stage), size \(size): frame \(frame) → \(window.frame), fitting \(minimum) → \(controller.view.fittingSize)")
                }
                try expect(window.contentLayoutRect == content)
                try expect(window.toolbar === toolbar)
                try expect(controller.view.fittingSize == minimum)
            }
        }
    }

    private func settle(_ window: NSWindow) async throws {
        // Allow SwiftUI observation and native layout to complete on the run loop.
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}
