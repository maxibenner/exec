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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root), residentLimit: 1)
        // Focus checks use a selected workspace; initial picker presentation is
        // covered separately and intentionally takes focus from the composer.
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(root)
        try await wait { !library.hasRunningOperations }
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

    func nativeDropsRouteOutsideTheEditor() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = window.contentView!
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 300, height: 30))
        field.stringValue = "Keep this draft"
        root.addSubview(field)
        let routing = ComposerDropRouting.RoutingView(frame: field.frame)
        root.addSubview(routing)
        defer { routing.restore(); window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        try expect(window.makeFirstResponder(field))
        guard let editor = window.firstResponder as? NSTextView else {
            throw CheckFailure(description: "Missing native field editor")
        }
        // Include string fallback: Finder can advertise a path as plain text.
        let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .string]
        field.registerForDraggedTypes(types)
        editor.registerForDraggedTypes(types)
        root.registerForDraggedTypes([.fileURL])
        routing.updateRouting()
        try expect(field.registeredDraggedTypes.isEmpty && editor.registeredDraggedTypes.isEmpty)
        try expect(root.registeredDraggedTypes.contains(.fileURL))
        try expect(field.stringValue == "Keep this draft")
        try expect(window.firstResponder === editor)
        routing.restore()
        try expect(types.allSatisfy { field.registeredDraggedTypes.contains($0) })
        try expect(types.allSatisfy { editor.registeredDraggedTypes.contains($0) })
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Composer focus or navigation did not settle")
    }
}
