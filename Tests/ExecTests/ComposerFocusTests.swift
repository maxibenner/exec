import AppKit
import SwiftUI

@MainActor struct ComposerFocusTests {
    private struct Host: View {
        @Bindable var library: ChatLibrary
        let windows: SessionWindows
        @FocusState private var composerFocused: Bool

        var body: some View {
            ConversationView(library: library, conversation: library.current,
                             presentation: windows.presentation(for: library.current), focused: $composerFocused)
                .id(ObjectIdentifier(library.current))
        }
    }

    func switchingSessionsDoesNotStealFocus() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root), residentLimit: 1)
        let windows = SessionWindows(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds)
        let host = NSHostingView(rootView: Host(library: library, windows: windows))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        container.addSubview(host)
        let selection = NSTextView(frame: NSRect(x: 0, y: 610, width: 800, height: 60))
        selection.string = "Selectable transcript text"
        selection.isEditable = false
        selection.isSelectable = true
        container.addSubview(selection)
        window.contentView = container
        defer { library.stopAll(); window.orderOut(nil); window.contentView = nil }
        library.restore()
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func expectSelectionPreserved() async throws {
            // Allow remounting and any focus tasks to run before checking.
            try await Task.sleep(for: .milliseconds(50))
            try expect(window.firstResponder === selection && selection.selectedRange().length == 10)
        }
        try await wait { !library.hasRunningOperations }
        library.draft = "First"; library.send()
        try await wait { !library.hasRunningOperations }
        let first = library.current
        let firstID = first.currentSessionID!
        try expect(window.makeFirstResponder(selection))
        selection.setSelectedRange(NSRange(location: 0, length: 10))
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try await expectSelectionPreserved()
        let second = library.current
        let secondProvider = provider.children.last!
        try expect(second !== first && !library.openConversations.contains { $0 === first })
        library.draft = "Keep this draft" // Keep the second runner resident for the warm switch.
        let secondID = second.currentSessionID!
        library.openSession(firstID)
        try await wait { library.current.currentSessionID == firstID && !library.hasRunningOperations }
        try await expectSelectionPreserved()
        library.openSession(secondID)
        try await wait { library.current === second && !library.hasRunningOperations }
        try await expectSelectionPreserved()

        library.send()
        try await wait { !library.hasRunningOperations }
        try await expectSelectionPreserved()
        var compacting = false
        secondProvider.manualCompactionAction = { _ in
            compacting = true
            try await Task.sleep(for: .seconds(60))
        }
        library.compact()
        try await wait { compacting }
        library.openSession(firstID)
        try await wait { library.current.currentSessionID == firstID && !library.navigating }
        try await expectSelectionPreserved()
        library.openSession(secondID)
        try await wait { library.current === second && !library.navigating }
        try await expectSelectionPreserved()
        try expect(ChatPanel(library: library, conversation: second).canEditDraft)
        library.stop()
        try await wait { !library.hasRunningOperations }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Composer focus or navigation did not settle")
    }
}
