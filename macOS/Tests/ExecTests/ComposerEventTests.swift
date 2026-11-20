import AppKit
import SwiftUI

/// Run only with --composer-events: NSApplication.run(), not merely the async
/// test runner, must dequeue these events. Direct editor.mouseDown calls miss
/// NSWindow making the editor first responder BEFORE dispatching mouseDown.
@MainActor
struct ComposerEventTests {
    private static let draft = (1...40).map {
        "Line \($0): " + String(repeating: "wrapped composer text ", count: 8)
    }.joined(separator: "\n")

    @MainActor @Observable final class Model {
        var focused = false
        var mounted = true
        var identity = 0
        var focusRequest: Int?
        var panel: ChatPanel
        init(panel: ChatPanel) { self.panel = panel }
    }

    private struct Host: View {
        @Bindable var model: Model
        let presentation: TranscriptState
        var body: some View {
            if model.mounted {
                ConversationView(panel: model.panel, presentation: presentation,
                                 focused: $model.focused, composerFocusRequest: model.focusRequest)
                    .id(model.identity)
            }
        }
    }

    private static func describe(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return "\(type(of: object))@\(ObjectIdentifier(object))"
    }

    private final class EventWindow: NSWindow {
        var postedEventNumbers = Set<Int>()
        var deliveredDowns = 0
        var lastMouseDown = "none"

        override func sendEvent(_ event: NSEvent) {
            guard event.type == .leftMouseDown else { super.sendEvent(event); return }
            // Count our queued events, not unrelated desktop clicks received while
            // an asynchronous check is settling. Duplicate fixture events still fail.
            if postedEventNumbers.contains(event.eventNumber) { deliveredDowns += 1 }
            let before = "active=\(NSApp.isActive), key=\(isKeyWindow), responder=\(describe(firstResponder))"
            let hit = describe(contentView?.hitTest(event.locationInWindow))
            super.sendEvent(event)
            lastMouseDown = "#\(deliveredDowns) at \(event.locationInWindow), hit=\(hit); before: \(before); after: active=\(NSApp.isActive), key=\(isKeyWindow), responder=\(describe(firstResponder))"
        }
    }

    @MainActor private struct Position {
        let selection: NSRange
        let origin: NSPoint
        init(_ view: ComposerTextInput.EditorScrollView) {
            selection = view.editor.selectedRange()
            origin = view.contentView.bounds.origin
        }
        func check(_ view: ComposerTextInput.EditorScrollView, _ context: String) throws {
            guard view.editor.selectedRange() == selection, view.contentView.bounds.origin == origin else {
                throw CheckFailure(description: "\(context): expected selection \(selection), scroll \(origin); got \(view.editor.selectedRange()), \(view.contentView.bounds.origin)")
            }
        }
    }

    @MainActor private final class Harness {
        let transport = FakeAgentTransport()
        let suite = "ComposerEventTests.\(UUID().uuidString)"
        let preferences: UserDefaults
        let library: ChatLibrary
        let model: Model
        let presentation = TranscriptState()
        let host: NSHostingView<Host>
        let window: EventWindow
        let other = NSTextField(string: "Real blur target")
        private var eventNumber = 0

        init() throws {
            preferences = UserDefaults(suiteName: suite)!
            library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
            let panel = ChatPanel(library: library, conversation: library.current)
            try panel.current.apply(AgentIntegrationTests.fixture(state: "completed", result: true).decoded(AgentSnapshot.self))
            panel.draft = ComposerEventTests.draft
            model = Model(panel: panel)
            host = NSHostingView(rootView: Host(model: model, presentation: presentation))
            window = EventWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 650),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Composer event regression checks"
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 650))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 550)
            root.addSubview(host)
            other.frame = NSRect(x: 30, y: 600, width: 250, height: 24)
            root.addSubview(other)
            window.contentView = root
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            library.current.closePresentation()
            model.panel.current.closePresentation()
            preferences.removePersistentDomain(forName: suite)
        }

        func settle() async throws {
            // Let posted events, SwiftUI binding updates and deferred layout/focus
            // complete on the running application loop (including a second turn).
            for _ in 0..<2 {
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
            }
        }

        func findEditor(_ root: NSView) -> ComposerTextInput.EditorScrollView? {
            if let view = root as? ComposerTextInput.EditorScrollView { return view }
            for child in root.subviews {
                if let view = findEditor(child) { return view }
            }
            return nil
        }

        func diagnostics(_ view: ComposerTextInput.EditorScrollView? = nil) -> String {
            let view = view ?? findEditor(host)
            let editorState = view.map {
                "editor=\(describe($0.editor)), window=\(describe($0.window)), editable=\($0.editor.isEditable), pendingFocus=\($0.pendingFocus), position=\($0.editor.hasEditingPosition), selection=\($0.editor.selectedRange()), viewport=\($0.contentView.bounds), textUTF16=\($0.editor.string.utf16.count), matchesDraft=\($0.editor.string == model.panel.draft)"
            } ?? "editor=nil"
            return "app: running=\(NSApp.isRunning), active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), keyWindow=\(describe(NSApp.keyWindow)); fixture: window=\(describe(window)), key=\(window.isKeyWindow), visible=\(window.isVisible), responder=\(describe(window.firstResponder)); \(editorState); model: focused=\(model.focused), mounted=\(model.mounted), identity=\(model.identity), request=\(String(describing: model.focusRequest)), draftUTF16=\(model.panel.draft.utf16.count); last mouseDown: \(window.lastMouseDown)"
        }

        func check(_ condition: Bool, _ context: String, view: ComposerTextInput.EditorScrollView? = nil) throws {
            guard condition else { throw CheckFailure(description: "\(context)\n\(diagnostics(view))") }
        }

        func editor() throws -> ComposerTextInput.EditorScrollView {
            guard let view = findEditor(host) else {
                throw CheckFailure(description: "ConversationView composer not mounted\n\(diagnostics())")
            }
            try check(view.editor.isEditable, "Composer is not editable", view: view)
            return view
        }

        private func requireActiveWindow() async throws {
            guard !NSApp.isActive || !window.isKeyWindow else { return }
            // Posting directly to NSApp bypasses the Window Server's activation
            // click. Another app may have become active during an awaited layout.
            // Restore that precondition, without assigning the editor's responder.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<100 {
                if NSApp.isActive && window.isKeyWindow { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(false, "Fixture did not acquire its active key window")
        }

        func click(_ point: NSPoint, flags: NSEvent.ModifierFlags = []) async throws {
            try await requireActiveWindow()
            let before = window.deliveredDowns
            eventNumber += 1
            // Window Server event numbers are nonnegative; reserve negatives for
            // this harness so real input cannot satisfy the delivery assertion.
            window.postedEventNumbers.insert(-eventNumber)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: -eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                else { throw CheckFailure(description: "Could not construct mouse event\n\(diagnostics())") }
                NSApp.postEvent(event, atStart: false)
            }
            try await settle()
            try check(window.deliveredDowns == before + 1,
                      "Click #\(eventNumber) at \(point): expected one delivered mouseDown, got \(window.deliveredDowns - before)")
        }

        func clickEditor(_ view: ComposerTextInput.EditorScrollView, flags: NSEvent.ModifierFlags = []) async throws {
            let point = view.contentView.convert(NSPoint(x: 75, y: view.contentView.bounds.minY + 30), to: nil)
            // Verify the actual hit target, not only that our window saw an event.
            let hit = window.contentView?.hitTest(point)
            try check(hit === view.editor, "Editor click hit \(describe(hit)) at \(point)", view: view)
            let before = diagnostics(view)
            try await click(point, flags: flags)
            try check(window.firstResponder === view.editor,
                      "Editor click #\(eventNumber) did not focus editor; before click: \(before)", view: view)
            try check(model.focused, "Editor click #\(eventNumber) did not update focus binding", view: view)
        }

        func type(_ character: String, keyCode: UInt16) async throws {
            try await requireActiveWindow()
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: keyCode)!
                NSApp.postEvent(event, atStart: false)
            }
            try await settle()
        }

        func blur() async throws {
            try await click(other.convert(NSPoint(x: 40, y: 12), to: nil))
            try check(other.currentEditor() != nil, "Blur click did not start field editing")
            try check(window.firstResponder === other.currentEditor(), "Blur click did not focus field editor")
            try check(!model.focused, "Blur click did not clear focus binding")
        }

        func scroll(_ view: ComposerTextInput.EditorScrollView, to y: CGFloat) async throws {
            view.contentView.scroll(to: NSPoint(x: 0, y: y))
            view.reflectScrolledClipView(view.contentView)
            try await settle()
        }

        func prepare() async throws -> (ComposerTextInput.EditorScrollView, CGFloat) {
            try await settle()
            let view = try editor()
            try await clickEditor(view)
            view.editor.setSelectedRange(NSRange(location: view.editor.string.utf16.count, length: 0))
            view.editor.scrollRangeToVisible(view.editor.selectedRange())
            try await settle()
            let bottom = view.contentView.bounds.minY
            try expect(bottom > view.contentView.bounds.height * 4)
            return (view, bottom)
        }

        func unmount() async throws {
            model.mounted = false
            try await settle()
            try expect(findEditor(host) == nil)
        }

        func mount(replacing old: ComposerTextInput.EditorScrollView) async throws -> ComposerTextInput.EditorScrollView {
            model.mounted = true
            try await settle()
            let replacement = try editor()
            try expect(replacement !== old && replacement.editor !== old.editor)
            try expect(old.window == nil)
            return replacement
        }

        func checkNoRequests() async throws {
            let requests = await transport.requests
            guard requests.isEmpty else {
                throw CheckFailure(description: "Composer UI made unexpected transport requests: \(requests.map { $0.method + " " + $0.path })")
            }
        }
    }

    func survivingEditorResumesAfterTemporaryReplacement() async throws {
        for updateBeforeDetach in [false, true] {
            let h = try Harness()
            defer { h.close() }
            let (view, _) = try await h.prepare()
            let session = ObjectIdentifier(h.model.panel.current)
            let state = h.presentation.composerEditingState
            let draft = h.model.panel.draft
            // Navigation can disable the current editor while SwiftUI briefly mounts
            // another representable for the same presentation, then keeps the first.
            view.update(text: draft, session: session, request: nil, enabled: false,
                        focused: true, editingState: state)
            let temporary = ComposerTextInput.EditorScrollView()
            temporary.update(text: draft, session: session, request: nil, enabled: false,
                             focused: false, editingState: state)
            if updateBeforeDetach {
                h.model.focusRequest = 1
                try await h.settle()
            }
            ComposerTextInput.dismantleNSView(temporary, coordinator: ())
            if !updateBeforeDetach { h.model.focusRequest = 1 }
            try await h.settle()
            // A highlighted border and first-responder identity alone are not proof
            // of an editable native text view. Click and deliver actual key events.
            try await h.clickEditor(view)
            try h.check(view.editor.isEditable && view.editor.isSelectable && view.editor.shouldDrawInsertionPoint,
                        "Surviving composer remained disabled after its replacement was dismantled (updateBeforeDetach=\(updateBeforeDetach))", view: view)
            let before = h.model.panel.draft
            try await h.type("a", keyCode: 0)
            try h.check(h.model.panel.draft.utf16.count == before.utf16.count + 1,
                        "Surviving composer did not accept native keyboard input", view: view)
            try await h.checkNoRequests()
        }
    }

    func realBlurAndRefocusPreserveSelectionAndViewport() async throws {
        let h = try Harness()
        defer { h.close() }
        let (view, bottom) = try await h.prepare()
        let end = view.editor.string.utf16.count
        for (name, y, selection) in [
            ("bottom/caret elsewhere", bottom, NSRange(location: 12, length: 0)),
            ("manual-mid/caret elsewhere", bottom / 2, NSRange(location: end - 6, length: 0)),
            ("manual-mid/nonempty selection", bottom / 2, NSRange(location: end - 30, length: 9))
        ] {
            view.editor.setSelectedRange(selection)
            try await h.scroll(view, to: y)
            let saved = Position(view)
            try await h.blur()
            try saved.check(view, "\(name) blur")
            try await h.clickEditor(view)
            try saved.check(view, "\(name) first refocus click")
            try expect(try h.editor() === view)
            // The suppression must be consumed by precisely that first event.
            try await h.clickEditor(view)
            try expect(view.editor.selectedRange().length == 0)
            try expect(view.editor.selectedRange() != saved.selection)
        }

        // Shift-click on refocus must extend the selection, not resume it.
        view.editor.setSelectedRange(NSRange(location: end - 6, length: 0))
        try await h.scroll(view, to: bottom / 2)
        try await h.blur()
        try await h.clickEditor(view, flags: [.shift])
        let extended = view.editor.selectedRange()
        try expect(extended.length > 0 && NSMaxRange(extended) == end - 6)

        // Explicit background focus and the keyboard-command focus request path
        // must preserve position too, without leaving a stale mouse suppression.
        for background in [true, false] {
            view.editor.setSelectedRange(NSRange(location: end - 25, length: 7))
            try await h.scroll(view, to: bottom / 2)
            let saved = Position(view)
            try await h.blur()
            if background {
                try await h.click(view.convert(NSPoint(x: -8, y: 30), to: nil))
            } else {
                h.model.focusRequest = (h.model.focusRequest ?? 0) + 1
                try await h.settle()
            }
            try h.check(h.window.firstResponder === view.editor && h.model.focused,
                        background ? "Composer background click did not focus editor" : "Composer focus request did not focus editor",
                        view: view)
            try saved.check(view, background ? "background focus" : "keyboard focus request")
            try await h.clickEditor(view)
            try expect(view.editor.selectedRange().length == 0 && view.editor.selectedRange() != saved.selection)
        }
        try await h.checkNoRequests()
    }

    func remountRestoresSelectionAndViewportAfterLayout() async throws {
        let h = try Harness()
        defer { h.close() }
        var (view, bottom) = try await h.prepare()
        for (y, selection) in [
            (bottom, NSRange(location: 12, length: 0)),
            (bottom / 2, NSRange(location: view.editor.string.utf16.count - 30, length: 9))
        ] {
            view.editor.setSelectedRange(selection)
            try await h.scroll(view, to: y)
            let saved = Position(view)
            try await h.blur()
            try await h.unmount()
            view = try await h.mount(replacing: view)
            try expect(view.editor.string == Self.draft)
            try saved.check(view, "same-session same-width remount before focus")
            try await h.clickEditor(view)
            try saved.check(view, "same-session remount refocus")
        }

        // An identity replacement may mount the new editor before dismantling
        // the old one. Position must already be captured, not only saved on exit.
        let active = Position(view)
        h.model.identity += 1
        try await h.settle()
        let replacement = try h.editor()
        try expect(replacement !== view)
        try active.check(replacement, "focused atomic identity replacement")
        let retired = view
        view = replacement
        view.editor.setSelectedRange(NSRange(location: 25, length: 4))
        try await h.scroll(view, to: (bottom / 3).rounded(.down))
        let latest = Position(view)
        // Late callbacks from an outgoing editor must not replace the new
        // editor's snapshot, even though its draft and session still match.
        retired.editor.setSelectedRange(NSRange(location: 0, length: 0))
        retired.contentView.scroll(to: .zero)
        retired.capturePosition()
        h.model.identity += 1
        try await h.settle()
        view = try h.editor()
        try latest.check(view, "late retired-editor callbacks")

        // Width changes must restore the top *text*, not the old pixel offset or
        // the offscreen selection. Record the top line's character and its inset.
        let anchor = view.editor.characterIndexForInsertion(at: NSPoint(x: 0, y: view.contentView.bounds.minY + 1))
        let offset = try characterTop(anchor, in: view) - view.contentView.bounds.minY
        let saved = Position(view)
        try await h.blur()
        try await h.unmount()
        h.host.frame.size.width = 480
        view = try await h.mount(replacing: view)
        try expect(view.editor.string == Self.draft && view.editor.selectedRange() == saved.selection)
        let restoredOffset = try characterTop(anchor, in: view) - view.contentView.bounds.minY
        try expect(abs(restoredOffset - offset) <= 1)
        try expect(abs(view.contentView.bounds.minY - saved.origin.y) > 20)
        let resized = Position(view)
        try await h.clickEditor(view)
        try resized.check(view, "width-changing remount refocus")
        try await h.checkNoRequests()
    }

    private func characterTop(_ character: Int, in view: ComposerTextInput.EditorScrollView) throws -> CGFloat {
        guard let layout = view.editor.layoutManager, let container = view.editor.textContainer else {
            throw CheckFailure(description: "Composer has no text layout")
        }
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: character)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.editor.textContainerOrigin.y
    }

    func changedDraftAndSessionDoNotReuseSnapshot() async throws {
        let h = try Harness()
        defer { h.close() }
        var (view, bottom) = try await h.prepare()
        // Same-length replacement catches snapshots validated only by length.
        for replacement in ["", Self.draft.replacingOccurrences(of: "composer", with: "replaced")] {
            h.model.panel.draft = Self.draft
            try await h.settle()
            try await h.clickEditor(view)
            view.editor.setSelectedRange(NSRange(location: 100, length: 11))
            try await h.scroll(view, to: bottom / 2)
            try await h.blur()
            try await h.unmount()
            h.model.panel.draft = replacement
            view = try await h.mount(replacing: view)
            try expect(view.editor.string == replacement)
            try expect(view.editor.selectedRange() == NSRange(location: 0, length: 0))
            try expect(view.contentView.bounds.origin == .zero)
            if !replacement.isEmpty { try await h.clickEditor(view) }
        }

        h.model.panel.draft = Self.draft
        try await h.settle()
        view.editor.setSelectedRange(NSRange(location: 100, length: 11))
        try await h.scroll(view, to: bottom / 2)
        try await h.blur()
        try await h.unmount()
        // Reuse even the presentation state, but with a different conversation
        // and identical draft. Session identity must prevent a snapshot leak.
        let otherLibrary = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: h.transport)), preferences: h.preferences)
        defer { otherLibrary.current.closePresentation() }
        guard case .object(var fixture) = try AgentIntegrationTests.fixture(state: "completed", result: true) else {
            throw CheckFailure(description: "Expected object fixture")
        }
        fixture["id"] = .string(UUID().uuidString)
        try otherLibrary.current.apply(AgentJSON.object(fixture).decoded(AgentSnapshot.self))
        let otherPanel = ChatPanel(library: otherLibrary, conversation: otherLibrary.current)
        otherPanel.draft = Self.draft
        h.model.panel = otherPanel
        view = try await h.mount(replacing: view)
        try expect(view.editor.string == Self.draft)
        try expect(view.editor.selectedRange() == NSRange(location: 0, length: 0))
        try expect(view.contentView.bounds.origin == .zero)
        try await h.checkNoRequests()
    }
}
