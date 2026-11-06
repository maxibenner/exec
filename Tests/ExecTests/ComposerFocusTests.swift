import AppKit
import SwiftUI

@MainActor struct ComposerFocusTests {
    private struct Host: View {
        @Bindable var library: ChatLibrary
        let windows: SessionWindows

        var body: some View {
            ConversationView(library: library, conversation: library.current,
                             presentation: windows.presentation(for: library.current))
                .id(ObjectIdentifier(library.current))
        }
    }

    func focusesNewAndSwitchedSessionsWithoutStealingSelection() async throws {
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
        // Mount while navigation has disabled the composer; focus must wait.
        library.restore()
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func composerHasFocus() -> Bool {
            guard let editor = window.firstResponder as? NSTextView else { return false }
            return editor !== selection && editor.isEditable
        }
        func selectTranscript() throws {
            try expect(window.makeFirstResponder(selection))
            selection.setSelectedRange(NSRange(location: 0, length: 10))
        }
        try await wait { !library.hasRunningOperations && composerHasFocus() }
        library.draft = "First"; library.send()
        try await wait { !library.hasRunningOperations }
        let first = library.current
        let firstID = first.currentSessionID!
        try selectTranscript()
        library.newConversation()
        try await wait { !library.hasRunningOperations && composerHasFocus() }
        let second = library.current
        let secondProvider = provider.children.last!
        try expect(second !== first && !library.openConversations.contains { $0 === first })
        library.draft = "Keep this draft" // Keep the second runner resident for the warm switch.
        let secondID = second.currentSessionID!
        try selectTranscript()
        library.openSession(firstID)
        try await wait { library.current.currentSessionID == firstID && !library.hasRunningOperations && composerHasFocus() }
        try selectTranscript()
        library.openSession(secondID)
        try await wait { library.current === second && !library.hasRunningOperations && composerHasFocus() }

        // Ordinary rendering and navigation-state updates must not pull focus
        // away from a native selection (and therefore its Copy command).
        try selectTranscript()
        library.draft = "Changed draft"
        library.send()
        try await wait { !library.hasRunningOperations }
        try await Task.sleep(for: .milliseconds(50))
        try expect(window.firstResponder === selection && selection.selectedRange().length == 10)

        var compacting = false
        secondProvider.manualCompactionAction = { _ in
            compacting = true
            try await Task.sleep(for: .seconds(60))
        }
        library.compact()
        try await wait { compacting }
        try expect(window.firstResponder === selection)
        // Switching to a compacting session must still focus an editable input.
        library.openSession(firstID)
        try await wait { library.current.currentSessionID == firstID && !library.navigating && composerHasFocus() }
        try selectTranscript()
        library.openSession(secondID)
        try await wait { library.current === second && composerHasFocus() }
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
