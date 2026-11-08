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
            ChatWindowLayout(workspace: presentation.library?.workspace?.root,
                             hasSessions: presentation.library.flatMap { $0.authenticating ? nil : !$0.sessionList.isEmpty }) {
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
            let minimum = window.contentMinSize
            for stage in 0..<3 {
                presentation.failed = stage == 0
                presentation.library = stage == 2 ? library : nil
                try await settle(window)
                guard window.frame == frame else {
                    throw CheckFailure(description: "Startup stage \(stage), size \(size): frame \(frame) → \(window.frame), fitting \(minimum) → \(controller.view.fittingSize)")
                }
                try expect(window.contentLayoutRect == content)
                try expect(window.toolbar === toolbar)
                // macOS 26 overlays the sidebar and changes the detail safe area.
                // Its intrinsic fitting size changes; the window minimum must not.
                try expect(window.contentMinSize == minimum)
            }
            guard let split = splitView(in: controller.view),
                  let splitController = split.delegate as? NSSplitViewController,
                  let sidebar = split.arrangedSubviews.first,
                  let transcript = descendant(TranscriptScrollView.self, in: controller.view),
                  let composer = descendant(ComposerCursor.CursorView.self, in: controller.view) else {
                throw CheckFailure(description: "Missing native chat layout views")
            }
            for collapsed in [true, false, true, false] {
                if split.isSubviewCollapsed(sidebar) != collapsed {
                    splitController.toggleSidebar(nil)
                    try await Task.sleep(for: .milliseconds(350))
                }
                try await settle(window)
                try expect(split.isSubviewCollapsed(sidebar) == collapsed)
                try expect(window.frame == frame && window.contentMinSize == minimum)
                let transcriptFrame = transcript.convert(transcript.bounds, to: controller.view)
                let composerFrame = composer.convert(composer.bounds, to: controller.view)
                let sidebarFrame = sidebar.convert(sidebar.bounds, to: controller.view)
                let expectedLeft = collapsed ? controller.view.bounds.minX : sidebarFrame.maxX
                try expect(abs(transcriptFrame.minX - expectedLeft) < 2)
                try expect(abs(transcriptFrame.maxX - controller.view.bounds.maxX) < 2)
                let contentWidth = min(820, transcript.contentSize.width - 40)
                try expect(abs(composerFrame.width - contentWidth) < 2)
                try expect(abs(transcript.state.layout.width - contentWidth) < 2)
                try expect(composerFrame.minX >= transcriptFrame.minX && composerFrame.maxX <= transcriptFrame.maxX)
            }
            if size.width == 980, let path = ProcessInfo.processInfo.environment["EXEC_SETTINGS_PREVIEWS"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for dark in [false, true] {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    try await settle(window)
                    let view = controller.view
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to:
                            directory.appendingPathComponent(dark ? "sidebar-dark.png" : "sidebar-light.png"))
                    }
                }
            }
        }
    }

    @Observable fileprivate final class SidebarPresentation {
        var hasSessions: Bool?
    }

    private struct SidebarFixture: View {
        let presentation: SidebarPresentation
        var body: some View {
            ChatWindowLayout(workspace: nil, hasSessions: presentation.hasSessions) {
                Text("Sessions")
            } detail: {
                Text("Conversation")
            }
        }
    }

    func choosesSidebarVisibilityOnceAfterRestoration() async throws {
        _ = NSApplication.shared
        for hasSessions in [false, true] {
            let presentation = SidebarPresentation()
            let controller = NSHostingController(rootView: SidebarFixture(presentation: presentation))
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 980, height: 700))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await settle(window)
            let frame = window.frame
            presentation.hasSessions = hasSessions
            try await settle(window)
            guard let split = splitView(in: controller.view), let sidebar = split.arrangedSubviews.first else {
                throw CheckFailure(description: "Missing native sidebar split view")
            }
            try expect(split.isSubviewCollapsed(sidebar) == !hasSessions)
            try expect(window.frame == frame)
            // Adding/deleting chats after startup must not override visibility.
            presentation.hasSessions = !hasSessions
            try await settle(window)
            try expect(split.isSubviewCollapsed(sidebar) == !hasSessions)
        }
    }

    private func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical { return split }
        return view.subviews.lazy.compactMap { splitView(in: $0) }.first
    }

    private func descendant<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func settle(_ window: NSWindow) async throws {
        // Allow SwiftUI observation and native layout to complete on the run loop.
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}
