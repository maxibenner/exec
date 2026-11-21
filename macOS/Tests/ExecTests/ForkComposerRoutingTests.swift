import AppKit

/// Control for the old "a /forkb" source-typing failure. A windowNumber on a
/// posted key is not necessarily a routing guarantee once another window is key.
/// This does not fork or repair focus: it characterizes NSApp event delivery.
@MainActor struct ForkComposerRoutingTests {
    func postedKeysFollowTheKeyWindow() async throws {
        func makeWindow() -> (ForkComposerEventWindow, ComposerTextInput.EditorScrollView) {
            let window = ForkComposerEventWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                                                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = ComposerTextInput.EditorScrollView()
            view.update(text: "", session: ObjectIdentifier(view), request: nil, enabled: true, focused: false)
            window.contentView = view
            window.center()
            return (window, view)
        }
        let (outgoing, outgoingEditor) = makeWindow()
        let (source, sourceEditor) = makeWindow()
        defer {
            for window in [source, outgoing] { window.orderOut(nil); window.contentView = nil; window.close() }
        }
        outgoing.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(100))
        try outgoing.postClick(outgoingEditor)
        try await Task.sleep(for: .milliseconds(100))
        try expect(outgoing.isKeyWindow && NSApp.isActive)
        source.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        try source.postClick(sourceEditor)
        try await Task.sleep(for: .milliseconds(100))
        try expect(source.isKeyWindow && NSApp.isActive)

        // Deliberately interleave events targeted at two different window numbers.
        outgoing.postKey("a", code: 0)
        outgoing.postKey(" ", code: 49)
        for (character, code) in [("/", UInt16(44)), ("f", 3), ("o", 31), ("r", 15), ("k", 40)] {
            source.postKey(character, code: code)
        }
        outgoing.postKey("b", code: 11)
        try await Task.sleep(for: .milliseconds(100))
        let contaminated = sourceEditor.editor.string == "a /forkb"
        print("Fork routing control: outgoingWindow=\(outgoing.windowNumber) sourceWindow=\(source.windowNumber) active=\(NSApp.isActive) sourceKey=\(source.isKeyWindow) sourceEditable=\(sourceEditor.editor.isEditable) reproduces-a-/forkb=\(contaminated) outgoingUTF16=\(outgoingEditor.editor.string.utf16.count)")
        guard contaminated && outgoingEditor.editor.string.isEmpty else {
            throw CheckFailure(description: "Posted keys were not retargeted to the key window; sourceUTF16=\(sourceEditor.editor.string.utf16.count), outgoingUTF16=\(outgoingEditor.editor.string.utf16.count)")
        }
        try source.checkDelivery()
    }
}
