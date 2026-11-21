import AppKit

/// Fork-only event tracing. No global monitor, screen capture, or real input text.
/// Keep posted-event identities so a timeout cannot quietly become input for the
/// next fixture. NSApp dispatch, not insertText/sendEvent, delivers every event.
@MainActor final class ForkComposerEventWindow: NSWindow {
    private var posted: [TimeInterval: String] = [:]
    private var delivered: [TimeInterval: Int] = [:]
    private var trace: [String] = []
    private var eventNumber = 0

    static func describe(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return "\(type(of: object))@\(ObjectIdentifier(object))"
    }

    static func editors(in root: NSView) -> [ComposerTextInput.EditorScrollView] {
        (root as? ComposerTextInput.EditorScrollView).map { [$0] }
            ?? root.subviews.flatMap { editors(in: $0) }
    }

    static func sidebar(in root: NSView) -> NSSplitViewItem? {
        if let split = root as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) { return item }
        return root.subviews.lazy.compactMap { sidebar(in: $0) }.first
    }

    func visibleEditor() throws -> ComposerTextInput.EditorScrollView {
        let visible = contentView.map { Self.editors(in: $0) }?.filter {
            !$0.isHiddenOrHasHiddenAncestor && !$0.editor.visibleRect.isEmpty
        } ?? []
        guard visible.count == 1 else {
            throw CheckFailure(description: "Expected one visible fork composer, got \(visible.count)")
        }
        return visible[0]
    }

    func postKey(_ character: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code)!
            // Only describe characters we explicitly generated, never desktop input.
            if type == .keyDown { posted[event.timestamp] = "key \(character.debugDescription) flags=\(flags.rawValue)" }
            NSApp.postEvent(event, atStart: false)
        }
    }

    func clickPoint(_ view: ComposerTextInput.EditorScrollView) -> NSPoint {
        view.editor.convert(NSPoint(x: 30, y: view.editor.visibleRect.minY + 8), to: nil)
    }

    func postClick(_ view: ComposerTextInput.EditorScrollView) throws {
        let point = clickPoint(view)
        guard contentView?.hitTest(point) === view.editor else {
            throw CheckFailure(description: "Composer click misses editor at \(point); hit=\(Self.describe(contentView?.hitTest(point)))")
        }
        eventNumber += 1
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                context: nil, eventNumber: -eventNumber, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!
            if type == .leftMouseDown { posted[event.timestamp] = "click #\(eventNumber) at \(point)" }
            NSApp.postEvent(event, atStart: false)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .leftMouseDown else { super.sendEvent(event); return }
        // Posting round-trips timestamps through integer nanoseconds. Exact
        // Double equality mislabels our own delivered events as foreign input.
        let stamp = posted.keys.first { abs($0 - event.timestamp) < 0.00000001 }
        let label = stamp.flatMap { posted[$0] } ?? "UNREGISTERED \(event.type.rawValue) (text redacted)"
        if let stamp { delivered[stamp, default: 0] += 1 }
        let before = "active=\(NSApp.isActive) key=\(isKeyWindow) responder=\(Self.describe(firstResponder))"
        let hit = event.type == .leftMouseDown ? " hit=\(Self.describe(contentView?.hitTest(event.locationInWindow)))" : ""
        super.sendEvent(event)
        trace.append("\(label) eventWindow=\(event.windowNumber) receiver=\(windowNumber)\(hit) before[\(before)] after[active=\(NSApp.isActive) key=\(isKeyWindow) responder=\(Self.describe(firstResponder))]")
        if trace.count > 40 { trace.removeFirst() }
    }

    func checkDelivery() throws {
        let mismatches = posted.keys.sorted().filter { delivered[$0] != 1 }.map {
            "\(posted[$0]!) delivered=\(delivered[$0, default: 0])"
        }
        guard mismatches.isEmpty else {
            throw CheckFailure(description: "Native event delivery mismatch: \(mismatches.joined(separator: "; "))")
        }
    }

    func diagnostics(library: ChatLibrary, windows: SessionWindows,
                     retained: [ComposerTextInput.EditorScrollView] = []) -> String {
        // This fixture uses only synthetic drafts. Redact unexpected input rather
        // than printing text somebody might type while these windows are active.
        func draft(_ text: String) -> String {
            text.allSatisfy { "/forkabrcx ".contains($0) } ? String(text.prefix(80)).debugDescription : "<redacted UTF16=\(text.utf16.count)>"
        }
        let mounted = contentView.map { Self.editors(in: $0) } ?? []
        var all = mounted
        for view in retained where !all.contains(where: { $0 === view }) { all.append(view) }
        let editorStates = all.enumerated().map { index, view in
            let editor = view.editor, point = clickPoint(view)
            return "editor[\(index)] mounted=\(mounted.contains { $0 === view }) view=\(Self.describe(view)) textView=\(Self.describe(editor)) window=\(view.window?.windowNumber ?? -1) hidden=\(view.isHiddenOrHasHiddenAncestor) editable=\(editor.isEditable) selectable=\(editor.isSelectable) caret=\(editor.shouldDrawInsertionPoint) pendingFocus=\(view.pendingFocus) delegate=\(Self.describe(editor.delegate)) onChange=\(view.onChange != nil) onFocus=\(view.onFocus != nil) selection=\(editor.selectedRange()) frame=\(editor.frame) visible=\(editor.visibleRect) text=\(draft(editor.string)) hit=\(Self.describe(contentView?.hitTest(point)))"
        }
        let windowStates = NSApp.windows.map {
            // Window metadata only; do not inspect another test's text views.
            "window=\($0.windowNumber) fixture=\($0 === self) visible=\($0.isVisible) key=\($0.isKeyWindow) responder=\(Self.describe($0.firstResponder))"
        }
        let undelivered = posted.keys.sorted().filter { delivered[$0] != 1 }.map { "\(posted[$0]!)=\(delivered[$0, default: 0])" }
        return (["active=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow?.windowNumber ?? -1) fixtureWindow=\(windowNumber) current=\(Self.describe(library.current)) draft=\(draft(library.current.draft)) messages=\(library.current.messages.count) focusRequest=\(windows.composerFocusRequest) revealRequest=\(windows.sidebarRevealRequest) sidebarCollapsed=\(String(describing: contentView.flatMap { Self.sidebar(in: $0)?.isCollapsed }))",
                 "windows: " + windowStates.joined(separator: "; ")] + editorStates +
                ["delivery mismatches: \(undelivered)", "events:\n" + trace.joined(separator: "\n")]).joined(separator: "\n")
    }
}
