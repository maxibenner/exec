import AppKit

/// Native editor boundary checks, without personal stores or a live backend.
@MainActor
struct ComposerLifecycleTests {
    @MainActor private final class Fixture {
        let window: NSWindow
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        let other = NSTextField(string: "Blur target")
        let session = NSObject()
        let state = ComposerEditingState()
        let draft = (1...30).map { "Line \($0): composer selection and viewport" }.joined(separator: "\n")

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            other.frame = NSRect(x: 20, y: 310, width: 300, height: 24)
            root.addSubview(other)
            window.contentView = root
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.makeKeyAndOrderFront(nil)
        }

        func mount(sized: Bool = true) -> ComposerTextInput.EditorScrollView {
            let view = ComposerTextInput.EditorScrollView()
            if sized { view.frame = NSRect(x: 20, y: 20, width: 500, height: 100) }
            root.addSubview(view)
            return view
        }

        func update(_ view: ComposerTextInput.EditorScrollView, state: ComposerEditingState? = nil,
                    text: String? = nil, request: Int? = nil, enabled: Bool = true, focused: Bool = false) {
            view.update(text: text ?? draft, session: ObjectIdentifier(session), request: request,
                        enabled: enabled, focused: focused, editingState: state ?? self.state)
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    func restoresLatestPositionOnOwnershipAndStateChanges() async throws {
        var failures: [String] = []
        for replaceState in [false, true] {
            let f = Fixture()
            defer { f.close() }
            let survivor = f.mount()
            f.update(survivor)
            try await settle()
            survivor.editor.setSelectedRange(NSRange(location: 10, length: 3))
            let latestState = replaceState ? ComposerEditingState() : f.state
            let temporary = f.mount()
            f.update(temporary, state: latestState)
            try await settle()
            let latestSelection = NSRange(location: 80, length: 12)
            temporary.editor.setSelectedRange(latestSelection)
            temporary.contentView.scroll(to: NSPoint(x: 0, y: 160))
            temporary.reflectScrolledClipView(temporary.contentView)
            temporary.capturePosition()
            let latestOrigin = temporary.contentView.bounds.origin
            try expect(latestOrigin.y > 0 && latestState.position?.selections == temporary.editor.selectedRanges)
            temporary.detach()
            temporary.removeFromSuperview()

            f.update(survivor, state: latestState)
            survivor.layoutSubtreeIfNeeded()
            try await settle()
            if survivor.editor.selectedRange() != latestSelection || survivor.contentView.bounds.origin != latestOrigin {
                failures.append("\(replaceState ? "Changed editing state" : "Reacquired ownership") lost the latest native position: selection=\(survivor.editor.selectedRange()), origin=\(survivor.contentView.bounds.origin)")
            }
            var changed = ""
            survivor.onChange = { changed = $0 }
            survivor.editor.insertText("replacement", replacementRange: survivor.editor.selectedRange())
            if changed != (f.draft as NSString).replacingCharacters(in: latestSelection, with: "replacement") {
                failures.append("Replacement used the stale native selection (replaceState=\(replaceState))")
            }
        }
        if !failures.isEmpty { throw CheckFailure(description: failures.joined(separator: "\n")) }
    }

    func pendingRestoresCannotOverwriteNewNativeInput() async throws {
        var failures: [String] = []
        for selectionOnly in [false, true] {
            let f = Fixture()
            defer { f.close() }
            f.state.position = position(f, selection: NSRange(location: 80, length: 12))
            let view = f.mount(sized: false)
            f.update(view)
            // Input can arrive before SwiftUI assigns the first usable viewport.
            // Neither a fresh selection nor a replacement may be undone by layout.
            view.editor.setSelectedRange(NSRange(location: 2, length: 4))
            if !selectionOnly { view.editor.insertText("new", replacementRange: view.editor.selectedRange()) }
            let selection = view.editor.selectedRange()
            let text = view.editor.string
            view.frame = NSRect(x: 20, y: 20, width: 500, height: 100)
            view.layoutSubtreeIfNeeded()
            try await settle()
            if view.editor.selectedRange() != selection || view.editor.string != text {
                failures.append("Deferred restore overwrote fresh \(selectionOnly ? "selection" : "input"): expected \(selection), got \(view.editor.selectedRange())")
            }
        }
        if !failures.isEmpty { throw CheckFailure(description: failures.joined(separator: "\n")) }
    }

    func nonOwnersCannotRestoreOrPublishEditingCallbacks() async throws {
        let f = Fixture()
        defer { f.close() }
        f.state.position = position(f, selection: NSRange(location: 80, length: 12))
        let retired = f.mount(sized: false)
        f.update(retired)
        let current = f.mount()
        f.update(current)
        try await settle()
        current.editor.setSelectedRange(NSRange(location: 30, length: 6))
        current.capturePosition()
        let latest = f.state.position?.selections
        retired.frame = NSRect(x: 20, y: 160, width: 500, height: 100)
        retired.layoutSubtreeIfNeeded()
        let restoredWhileRetired = retired.editor.selectedRange() != NSRange(location: 0, length: 0)
        try expect(f.state.position?.selections == latest)

        var edits = 0
        var commands = 0
        retired.onChange = { _ in edits += 1 }
        retired.onSubmit = { commands += 1 }
        retired.onMove = { _ in commands += 1; return true }
        retired.onEscape = { commands += 1 }
        retired.editor.insertText("stale", replacementRange: NSRange(location: 0, length: 0))
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveUp(_:)),
                         #selector(NSResponder.cancelOperation(_:))] {
            _ = retired.textView(retired.editor, doCommandBy: selector)
        }
        retired.detach()
        retired.textDidChange(Notification(name: NSText.didChangeNotification, object: retired.editor))
        _ = retired.textView(retired.editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        guard !restoredWhileRetired, edits == 0, commands == 0 else {
            throw CheckFailure(description: "Nonowner restored=\(restoredWhileRetired), published edits=\(edits), commands=\(commands)")
        }
    }

    func blurCancelsQueuedFocusAndConsumedRequestsStayConsumed() async throws {
        let f = Fixture()
        defer { f.close() }
        let view = f.mount()
        f.update(view, request: 1, focused: true)
        // An intentional binding blur before the queued focus executes cancels it.
        f.update(view, request: 1, focused: false)
        try await settle()
        let bindingBlurCancelled = f.window.firstResponder !== view.editor && !view.pendingFocus

        f.update(view, request: 2, focused: true)
        try await settle()
        try expect(f.window.firstResponder === view.editor)
        // A native blur must also cancel work already queued by an explicit request.
        f.update(view, request: 3, focused: true)
        try expect(f.window.makeFirstResponder(f.other))
        try await settle()
        let nativeBlurCancelled = f.window.firstResponder !== view.editor && !view.pendingFocus
        f.update(view, request: 3, enabled: false)
        f.update(view, request: 3)
        try await settle()
        let consumedRequestStayedConsumed = f.window.firstResponder !== view.editor && !view.pendingFocus
        guard bindingBlurCancelled, nativeBlurCancelled, consumedRequestStayedConsumed else {
            throw CheckFailure(description: "Binding blur cancelled=\(bindingBlurCancelled), native blur cancelled=\(nativeBlurCancelled), consumed request stayed consumed=\(consumedRequestStayedConsumed)")
        }
    }

    func disabledEditorsDeferOnlyUnconsumedFocusAndIgnoreCommands() async throws {
        let f = Fixture()
        defer { f.close() }
        let view = f.mount()
        var commands = 0
        view.onSubmit = { commands += 1 }
        f.update(view, request: 1, enabled: false)
        _ = view.textView(view.editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try expect(commands == 0)
        try await settle()
        try expect(f.window.firstResponder !== view.editor)
        f.update(view, request: 1)
        try await settle()
        try expect(f.window.firstResponder === view.editor && !view.pendingFocus)

        // Temporarily disabling a focused composer still restores its prior focus.
        f.update(view, request: 1, enabled: false, focused: true)
        try expect(f.window.makeFirstResponder(f.other))
        try await settle()
        f.update(view, request: 1)
        try await settle()
        try expect(f.window.firstResponder === view.editor && !view.pendingFocus)

        // Removing a request while disabled cancels it; a new token is independent.
        try expect(f.window.makeFirstResponder(f.other))
        try await settle()
        f.update(view, request: 2, enabled: false)
        f.update(view, enabled: false)
        f.update(view)
        try await settle()
        try expect(f.window.firstResponder !== view.editor && !view.pendingFocus)
        f.update(view, request: 3, enabled: false)
        f.update(view, request: 3)
        try await settle()
        try expect(f.window.firstResponder === view.editor && !view.pendingFocus)
    }

    private func position(_ f: Fixture, selection: NSRange) -> ComposerEditingState.Position {
        .init(session: ObjectIdentifier(f.session), text: f.draft, selections: [NSValue(range: selection)],
              origin: NSPoint(x: 0, y: 160), width: 500, topCharacter: nil, lineOffset: 0)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }
}
