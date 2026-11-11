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
            ChatWindowLayout(initiallyShowsSidebar: true) {
                if let library = presentation.library {
                    SessionSidebar(store: library, open: { _ in }, delete: { _ in })
                } else {
                    Color.clear
                }
            } detail: {
                if let library = presentation.library {
                    ConversationView(library: library, conversation: library.current,
                                     presentation: transcript, focused: $focused)
                        .onAppear { focused = true }
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
            let scheme: ColorScheme = size.width == 980 ? .dark : .light
            let controller = NSHostingController(rootView: Fixture(presentation: presentation).environment(\.colorScheme, scheme))
            let window = NSWindow(contentViewController: controller)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.setContentSize(size)
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await settle(window)
            let frame = window.frame
            let content = window.contentLayoutRect
            let toolbar = window.toolbar
            let systemSpacing: Set<NSToolbarItem.Identifier> = [.space, .flexibleSpace, .sidebarTrackingSeparator]
            let controls = toolbar?.items.filter { !systemSpacing.contains($0.itemIdentifier) } ?? []
            // Newer macOS draws the native toggle outside the toolbar. Either
            // way, there must not be an additional custom toolbar button.
            try expect(controls.count <= 1 && controls.allSatisfy { $0.itemIdentifier == .toggleSidebar })
            try expect(window.titleVisibility == .visible)
            try expect(window.titlebarSeparatorStyle == .automatic)
            let minimum = window.contentMinSize
            let initialSidebarColor = try sidebarBackground(in: controller.view)
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
                let restoredColor = try sidebarBackground(in: controller.view)
                try expect(zip(initialSidebarColor, restoredColor).allSatisfy { abs($0 - $1) < 1.0 / 255 })
            }
            try expect(window.title == "Restored conversation")
            try expect(window.titlebarSeparatorStyle == .automatic)
            guard let split = splitView(in: controller.view),
                  let splitController = split.delegate as? NSSplitViewController,
                  let sidebar = split.arrangedSubviews.first,
                  let transcript = descendant(TranscriptScrollView.self, in: controller.view),
                  let composer = descendant(ComposerCursor.CursorView.self, in: controller.view) else {
                throw CheckFailure(description: "Missing native chat layout views")
            }
            for (index, collapsed) in [true, false, true, false].enumerated() {
                let startingWidth = transcript.bounds.width
                var animationWidths: [CGFloat] = []
                if split.isSubviewCollapsed(sidebar) != collapsed {
                    if index < 2 {
                        // ⌘S must both close and reopen the native sidebar while
                        // editing, without inserting text into the draft.
                        try expect((window.firstResponder as? NSTextView)?.isEditable == true)
                        let draft = library.draft
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "s",
                            charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
                        try expect(window.performKeyEquivalent(with: event))
                        try expect(library.draft == draft)
                    } else {
                        splitController.toggleSidebar(nil)
                    }
                    // Check intermediate geometry too: AppKit can temporarily
                    // enlarge the split view and only snap back at completion.
                    for _ in 0..<25 {
                        try await Task.sleep(for: .milliseconds(16))
                        let splitFrame = split.convert(split.bounds, to: controller.view)
                        let transcriptFrame = transcript.convert(transcript.bounds, to: controller.view)
                        let composerFrame = composer.convert(composer.bounds, to: controller.view)
                        animationWidths.append(transcriptFrame.width)
                        try expect(abs(splitFrame.maxX - controller.view.bounds.maxX) < 2)
                        try expect(abs(transcriptFrame.maxX - controller.view.bounds.maxX) < 2)
                        try expect(composerFrame.maxX <= transcriptFrame.maxX + 1)
                        try expect(window.frame == frame)
                    }
                }
                try await settle(window)
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let lower = min(startingWidth, transcript.bounds.width)
                    let upper = max(startingWidth, transcript.bounds.width)
                    // Both the shortcut and the native action must animate,
                    // rather than jumping directly to the final column width.
                    try expect(animationWidths.contains { $0 > lower + 1 && $0 < upper - 1 })
                }
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
            if size.width == 980 {
                for sidebarWidth in [CGFloat(266), CGFloat(320)] {
                    window.setContentSize(size)
                    try await settle(window)
                    split.setPosition(sidebarWidth, ofDividerAt: 0)
                    try await settle(window)
                    let heldWidth = sidebar.frame.width
                    for width in [800, 740, 730, 725, 721, 720, 721, 730, 980] {
                        window.setContentSize(NSSize(width: CGFloat(width), height: size.height))
                        try await settle(window)
                        let transcriptFrame = transcript.convert(transcript.bounds, to: controller.view)
                        let composerFrame = composer.convert(composer.bounds, to: controller.view)
                        try expect(abs(sidebar.frame.width - heldWidth) < 1)
                        try expect(abs(transcriptFrame.maxX - controller.view.bounds.maxX) < 2)
                        try expect(abs(composerFrame.width - min(820, transcript.contentSize.width - 40)) < 2)
                        try expect(abs(transcript.state.layout.width - composerFrame.width) < 2)
                    }
                }
            }
            if size.width == 980, let path = ProcessInfo.processInfo.environment["EXEC_SETTINGS_PREVIEWS"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for dark in [false, true] {
                    controller.rootView = Fixture(presentation: presentation).environment(\.colorScheme, dark ? .dark : .light)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    try await settle(window)
                    let view = window.contentView!.superview!
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to:
                            directory.appendingPathComponent(dark ? "sidebar-dark.png" : "sidebar-light.png"))
                    }
                }
            }
        }
    }

    @MainActor @Observable fileprivate final class SidebarPresentation {
        var hasSessions = false
        var revealRequest = 0
        let transcript = TranscriptState()
        let messages = [Message(role: .user, text: String(repeating: "Long wrapped sidebar reflow text. ", count: 600))]
    }

    private struct SidebarFixture: View {
        let presentation: SidebarPresentation
        var body: some View {
            ChatWindowLayout(initiallyShowsSidebar: presentation.hasSessions, sidebarRevealRequest: presentation.revealRequest) {
                Text("Sessions")
            } detail: {
                TranscriptView(messages: presentation.messages, state: presentation.transcript, bottomInset: 140)
            }
        }
    }

    func choosesSidebarVisibilityBeforeRestoration() async throws {
        _ = NSApplication.shared
        for hasSessions in [false, true] {
            let presentation = SidebarPresentation()
            presentation.hasSessions = hasSessions
            let controller = NSHostingController(rootView: SidebarFixture(presentation: presentation))
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 980, height: 700))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await settle(window)
            let frame = window.frame
            guard let split = splitView(in: controller.view), let sidebar = split.arrangedSubviews.first else {
                throw CheckFailure(description: "Missing native sidebar split view")
            }
            try expect(split.isSubviewCollapsed(sidebar) == !hasSessions)
            try expect(window.frame == frame)
            guard let splitController = split.delegate as? NSSplitViewController else {
                throw CheckFailure(description: "Missing sidebar controller")
            }
            try expect(splitController.splitViewItems.first?.collapseBehavior == .useConstraints)
            // Adding/deleting chats after startup must not override visibility.
            presentation.hasSessions = !hasSessions
            try await settle(window)
            try expect(split.isSubviewCollapsed(sidebar) == !hasSessions)
            if !split.isSubviewCollapsed(sidebar) {
                splitController.toggleSidebar(nil)
                try await Task.sleep(for: .milliseconds(350))
            }
            presentation.revealRequest += 1
            try await settle(window)
            try expect(!split.isSubviewCollapsed(sidebar))
            // The reveal request must not keep forcing the sidebar open.
            splitController.toggleSidebar(nil)
            try await Task.sleep(for: .milliseconds(350))
            presentation.hasSessions.toggle()
            try await settle(window)
            try expect(split.isSubviewCollapsed(sidebar))
            for width: CGFloat in [720, 980] {
                window.setContentSize(NSSize(width: width, height: 700))
                try await settle(window)
                for toggle in 0..<4 {
                    let closing = !split.isSubviewCollapsed(sidebar)
                    let transcript = presentation.transcript.scrollView!
                    var previousWidth = transcript.contentSize.width
                    if toggle.isMultiple(of: 2) {
                        splitController.toggleSidebar(nil) // Native toolbar action.
                    } else {
                        func configuration(in view: NSView) -> SidebarResizeBehavior.ConfigurationView? {
                            (view as? SidebarResizeBehavior.ConfigurationView) ?? view.subviews.lazy.compactMap { configuration(in: $0) }.first
                        }
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
                        try expect(configuration(in: controller.view)!.performKeyEquivalent(with: event))
                    }
                    // Presentation changes during and after the animation must
                    // not replay the previous visibility or reverse pane width.
                    for sample in 0..<24 {
                        if sample.isMultiple(of: 4) { presentation.hasSessions.toggle() }
                        window.contentView?.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                        let currentWidth = transcript.contentSize.width
                        try expect(closing ? currentWidth >= previousWidth - 2 : currentWidth <= previousWidth + 2)
                        previousWidth = currentWidth
                    }
                    try expect(split.isSubviewCollapsed(sidebar) == closing)
                    try expect(presentation.transcript.followsLatest)
                    guard abs(transcript.contentView.bounds.maxY - transcript.documentView!.bounds.height) < 1 else {
                        throw CheckFailure(description: "Sidebar width=\(width) closing=\(closing) clip=\(transcript.contentView.bounds) document=\(transcript.documentView!.bounds) follows=\(presentation.transcript.followsLatest)")
                    }
                }
            }
        }
    }

    func readsExistingSessionFilesBeforeStartup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try expect(!SessionStore.hasSavedSessions(in: root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try expect(!SessionStore.hasSavedSessions(in: root))
        // An orphaned index or unfinished atomic save must not open the sidebar.
        for name in ["index.json", "account.json", "temporary.json"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try expect(!SessionStore.hasSavedSessions(in: root))
        for name in [UUID().uuidString + ".json", "session.json"] {
            let file = root.appendingPathComponent(name)
            // Unreadable snapshots still have a recoverable sidebar entry.
            try Data("invalid snapshot".utf8).write(to: file)
            try expect(SessionStore.hasSavedSessions(in: root))
            try FileManager.default.removeItem(at: file)
            try expect(!SessionStore.hasSavedSessions(in: root))
        }
    }

    private func sidebarBackground(in view: NSView) throws -> [CGFloat] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CheckFailure(description: "Cannot render startup sidebar")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Sample empty sidebar space, away from rows, dividers and the toolbar.
        let x = Int(60 * CGFloat(bitmap.pixelsWide) / view.bounds.width)
        guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
            throw CheckFailure(description: "Cannot read startup sidebar background")
        }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
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
