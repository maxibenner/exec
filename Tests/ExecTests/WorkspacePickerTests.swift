import AppKit
import SwiftUI

@MainActor struct WorkspacePickerTests {
    private struct Host: View {
        @Bindable var library: ChatLibrary
        let picker: ChatPanel.WorkspacePicker
        @FocusState private var focused: Bool
        let presentation = TranscriptState()

        var body: some View {
            ConversationView(panel: ChatPanel(library: library, conversation: library.current,
                                               presentWorkspacePicker: picker),
                             presentation: presentation, focused: $focused)
                .id(ObjectIdentifier(library.current))
        }
    }

    func presentsPickerInOwningWindow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ChatLibrary(provider: FakeProvider(), sessions: SessionStore(directory: root))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        var owners: [NSWindow] = []
        let host = NSHostingView(rootView: Host(library: library, picker: { owner, _, complete in
            owners.append(owner)
            complete(nil)
        }))
        defer {
            window.orderOut(nil)
            window.contentView = nil
            library.stopAll()
        }
        // Restore before attachment: the request must survive having no window.
        library.restore()
        try await wait { !library.hasRunningOperations }
        try expect(library.current.needsInitialWorkspaceSelection)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait { owners.count == 1 }
        try expect(owners[0] === window)
        try expect(!library.current.needsInitialWorkspaceSelection)

        // Replacing the conversation must present again, even after cancellation.
        library.newConversation()
        try await wait { owners.count == 2 }
        try expect(owners[1] === window)
        try await Task.sleep(for: .milliseconds(100))
        try expect(owners.count == 2)
    }

    func sendRequiresWorkspaceAndPreservesDraft() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")))
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        let conversation = library.current
        let runner = provider.children.last!
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        var presentations = 0
        var complete: (@MainActor (URL?) -> Void)?
        let panel = ChatPanel(library: library, conversation: conversation) { owner, _, completion in
            precondition(owner === window)
            presentations += 1
            complete = completion
        }
        panel.draft = "Keep this message"
        panel.chooseInitialWorkspaceIfNeeded()
        panel.send()
        try expect(presentations == 0 && conversation.needsInitialWorkspaceSelection)
        try expect(runner.inputs.isEmpty && conversation.messages.isEmpty)
        panel.window = window
        panel.chooseInitialWorkspaceIfNeeded()
        panel.send() // Cannot bypass or duplicate an open picker.
        try expect(presentations == 1 && panel.isChoosingWorkspace)
        complete?(nil)
        panel.chooseInitialWorkspaceIfNeeded()
        try expect(presentations == 1 && panel.draft == "Keep this message")
        panel.send() // Explicit send reopens after Cancel.
        try expect(presentations == 2 && runner.inputs.isEmpty)
        complete?(root.appendingPathComponent("missing"))
        try await wait { !library.hasRunningOperations }
        try expect(panel.workspace == nil && panel.draft == "Keep this message" && runner.inputs.isEmpty)
        panel.send()
        try expect(presentations == 3)
        complete?(root)
        try await wait { !library.hasRunningOperations }
        try expect(panel.workspace != nil && panel.draft == "Keep this message")
        try expect(runner.inputs.isEmpty && library.current === conversation)
        panel.send()
        try await wait { !library.hasRunningOperations }
        try expect(runner.inputs.count == 1 && panel.draft.isEmpty)
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.workspace?.root == panel.workspace?.root)
        try expect(!library.current.needsInitialWorkspaceSelection)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Workspace picker did not settle")
    }
}
