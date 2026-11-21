import AppKit
import SwiftUI
import Observation

/// A real SwiftUI scene is essential: NSHostingView + NSWindow does not reproduce
/// the synchronous GraphHost flush that used to mount the second fork disabled.
/// Only startup/accounts/persistence are replaced. Production UI is unmodified.
@MainActor private struct ProbeOptions {
    let screen: Int
    let forks: Int
    let slow: Bool
    let sidebar: Bool
    let moveTo: Int?

    init() throws {
        var values: [String: String] = [:]
        for argument in CommandLine.arguments.dropFirst() {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["--screen", "--forks", "--speed", "--sidebar", "--move-to"].contains(parts[0]),
                  values.updateValue(parts[1], forKey: parts[0]) == nil else {
                throw CheckFailure(description: "Use --screen=N --forks=2...20 --speed=fast|slow --sidebar=hidden|visible [--move-to=N]")
            }
        }
        guard let screen = Int(values["--screen"] ?? "0"), NSScreen.screens.indices.contains(screen),
              let forks = Int(values["--forks"] ?? "3"), (2...20).contains(forks),
              ["fast", "slow"].contains(values["--speed"] ?? "slow"),
              ["hidden", "visible"].contains(values["--sidebar"] ?? "hidden") else {
            throw CheckFailure(description: "Invalid probe options or unavailable display (found \(NSScreen.screens.count))")
        }
        self.screen = screen; self.forks = forks
        slow = values["--speed", default: "slow"] == "slow"
        sidebar = values["--sidebar", default: "hidden"] == "visible"
        if let value = values["--move-to"] {
            guard let index = Int(value), NSScreen.screens.indices.contains(index) else {
                throw CheckFailure(description: "Unavailable --move-to display")
            }
            moveTo = index
        } else { moveTo = nil }
    }
}

/// Observe only local, posted input; never inspect/log desktop text. Delivery is
/// checked separately from the draft, since posting to a window is not routing.
@MainActor private final class SceneInput {
    private var posted: [TimeInterval: Int] = [:]
    private var received: [TimeInterval: Int] = [:]
    private var foreign = 0
    private var misrouted = 0
    private var monitor: Any?
    private var clickNumber = 0

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [self] event in
            // AppKit round-trips timestamps through integer nanoseconds.
            if let stamp = posted.keys.first(where: { abs($0 - event.timestamp) < 0.00000001 }) {
                received[stamp, default: 0] += 1
                if event.windowNumber != posted[stamp] || event.window !== NSApp.keyWindow { misrouted += 1 }
            } else { foreign += 1 }
            return event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    private func post(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .leftMouseDown { posted[event.timestamp] = event.windowNumber }
        NSApp.postEvent(event, atStart: false)
    }
    func key(_ window: NSWindow, _ text: String, _ code: UInt16, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            post(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        }
    }
    func editor(_ window: NSWindow) throws -> ComposerTextInput.EditorScrollView {
        let views = window.contentView.map { ForkComposerEventWindow.editors(in: $0) }?.filter {
            !$0.isHiddenOrHasHiddenAncestor && !$0.editor.visibleRect.isEmpty
        } ?? []
        guard views.count == 1 else { throw CheckFailure(description: "Expected one visible composer, got \(views.count)") }
        return views[0]
    }
    func click(_ window: NSWindow) throws {
        let editor = try editor(window).editor
        let point = editor.convert(NSPoint(x: 30, y: editor.visibleRect.minY + 8), to: nil)
        clickNumber += 1
        // Still post if a disabled editor misses hit testing: click-input must be
        // checked even when automatic focus failed, without repairing either.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            post(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: -clickNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
    func checkDelivery() throws {
        let bad = posted.keys.filter { received[$0] != 1 }.count
        guard bad == 0, foreign == 0, misrouted == 0 else {
            throw CheckFailure(description: "Event delivery: missing/duplicate=\(bad), foreign=\(foreign), misrouted=\(misrouted) (text redacted)")
        }
    }
    var delivered: Int { received.values.reduce(0, +) }
}

@MainActor @Observable private final class ComposerSceneController {
    var fixture: SidebarCreationFixture?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var phase = "setup"
    @ObservationIgnored private var completed = 0
    @ObservationIgnored private var options: ProbeOptions?
    @ObservationIgnored private let input = SceneInput()
    var initiallyShowsSidebar: Bool { options?.sidebar ?? false }

    func prepare() {
        guard !started else { return }; started = true
        // Separate process/watchdog: never enlarge the ordinary native suite's.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            FileHandle.standardError.write(Data("FAIL REAL-SWIFTUI-SCENE: 60-second timeout\n".utf8)); exit(1)
        }
        Task { @MainActor in
            do {
                options = try ProbeOptions()
                fixture = try await SidebarCreationFixture(messages: (0..<24).map { i in .object([
                    "id": .string(UUID().uuidString), "role": .string(i.isMultiple(of: 2) ? "user" : "assistant"),
                    "text": .string("Synthetic turn \(i)\n" + String(repeating: "Scene fork fixture. ", count: 12)),
                    "status": .string("completed")]) })
            } catch { finish(error) }
        }
    }
    func attached(_ window: NSWindow?) {
        guard let window, fixture != nil, !running else { return }; running = true
        Task { @MainActor in
            do { try await run(window); finish(nil) }
            catch { finish(error) }
        }
    }
    private func settle(_ milliseconds: Int = 100) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
    private func place(_ window: NSWindow, on index: Int) async throws {
        let screen = NSScreen.screens[index]
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                      y: screen.visibleFrame.midY - window.frame.height / 2))
        try await settle(300)
        try expect(window.screen === screen && window.backingScaleFactor == screen.backingScaleFactor)
        print("DISPLAY index=\(index) frame=\(screen.frame) scale=\(window.backingScaleFactor) scene=\(type(of: window))")
    }
    private func run(_ window: NSWindow) async throws {
        guard let fixture, let options else { throw CheckFailure(description: "Missing fixture/options") }
        let library = fixture.library, windows = fixture.windows
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true) // Setup only. No post-fork activation/first-responder assignment.
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await settle(20)
        }
        try await place(window, on: options.screen)
        try expect(NSApp.isActive && window.isKeyWindow && window.identifier?.rawValue == "chat")
        try expect(window.contentView.flatMap { ForkComposerEventWindow.sidebar(in: $0)?.isCollapsed } == !options.sidebar)
        input.start()
        try input.click(window); try await settle()
        let messages = fixture.roots[0]["messages"].array
        for iteration in 1...options.forks {
            phase = "fork \(iteration)/source"
            let source = library.current
            let sourceState = windows.presentation(for: source).composerEditingState
            try expect(source.draft.isEmpty && source.messages.count == 24)
            for (text, code) in [("/", UInt16(44)), ("f", 3), ("o", 31), ("r", 15), ("k", 40)] { input.key(window, text, code) }
            try await settle()
            try expect(source.draft == "/fork")
            input.key(window, "\r", 36)
            try await fixture.waitForCreation()
            phase = "fork \(iteration)/pending"
            if options.slow { try await settle(350) }
            try expect(library.navigating)
            try await fixture.transport.finishCreation(SidebarCreationFixture.snapshot(workspace: fixture.workspace, messages: messages))
            await library.waitForNavigation()
            try await settle()
            phase = "fork \(iteration)/input"
            let fork = try input.editor(window)
            try expect(library.current !== source && library.current.messages.count == 24 && !library.navigating && library.error == nil)
            try expect(windows.presentation(for: library.current).composerEditingState !== sourceState)
            let caret = window.firstResponder === fork.editor && fork.editor.shouldDrawInsertionPoint
            let editable = fork.editor.isEditable, selectable = fork.editor.isSelectable
            input.key(window, "a", 0); try await settle()
            let automatic = library.current.draft == "a" && fork.editor.string == "a"
            try input.click(window); try await settle()
            input.key(window, "b", 11); try await settle()
            let clicked = library.current.draft == "ab" && fork.editor.string == "ab"
            print("INPUT fork=\(iteration) caret=\(caret) editable=\(editable) selectable=\(selectable) automatic=\(automatic) clicked=\(clicked)")
            try input.checkDelivery()
            try expect(caret && editable && selectable && automatic && clicked && NSApp.isActive && window.isKeyWindow)
            input.key(window, "\u{f702}", 123, flags: .shift)
            input.key(window, "\u{f702}", 123, flags: .shift)
            try await settle()
            try expect(fork.editor.selectedRange() == NSRange(location: 0, length: 2))
            input.key(window, "r", 15); try await settle()
            try expect(library.current.draft == "r" && fork.editor.string == "r" && fork.editor.selectedRange() == NSRange(location: 1, length: 0))
            input.key(window, "\u{f702}", 123, flags: .shift)
            input.key(window, "\u{7f}", 51); try await settle()
            try expect(library.current.draft.isEmpty && source.draft.isEmpty && fork.editor.string.isEmpty)
            try expect(windows.sidebarRevealRequest == 1 && windows.composerFocusRequest == iteration)
            try expect(window.contentView.flatMap { ForkComposerEventWindow.sidebar(in: $0)?.isCollapsed } == false)
            try input.checkDelivery()
            completed += 1
            print("PASS REAL-SWIFTUI-SCENE fork=\(iteration) speed=\(options.slow ? "slow" : "fast") initialSidebar=\(options.sidebar ? "visible" : "hidden") selection/replacement/deletion=true")
            if iteration == 1, let screen = options.moveTo { try await place(window, on: screen) }
        }
        let requests = await fixture.transport.creationRequests
        try expect(requests == completed)
    }
    private func finish(_ error: Error?) {
        input.stop()
        fixture?.close()
        if let error { FileHandle.standardError.write(Data("FAIL REAL-SWIFTUI-SCENE \(phase): \(error)\n".utf8)) }
        print("\(error == nil ? "PASS" : "FAIL") REAL-SWIFTUI-SCENE completedForks=\(completed)/\(options?.forks ?? 0) deliveredEvents=\(input.delivered)")
        exit(error == nil ? 0 : 1)
    }
}

@main struct ComposerSceneProbe: App {
    @State private var controller = ComposerSceneController()
    @State private var hasPresentedMainWindow = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("", id: "chat") {
            ChatWindowLayout(initiallyShowsSidebar: controller.initiallyShowsSidebar,
                             sidebarRevealRequest: controller.fixture?.windows.sidebarRevealRequest ?? 0) {
                if let fixture = controller.fixture {
                    SessionSidebar(store: fixture.library, open: fixture.windows.openSession,
                                   delete: { fixture.windows.requestSessionDeletion($0.id) })
                }
            } detail: {
                if let fixture = controller.fixture { ChatView(store: fixture.library, windows: fixture.windows) }
            }
            .tint(AppColors.blue).accentColor(AppColors.blue)
            .background(WindowReference { controller.attached($0) })
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            SessionCommands(store: controller.fixture?.library, windows: controller.fixture?.windows)
            TranscriptCommands()
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(hasPresentedMainWindow ? .automatic : .suppressed)
        .onChange(of: scenePhase, initial: true) { _, _ in controller.prepare() }
        .onChange(of: controller.fixture != nil, initial: true) { _, ready in
            guard ready, !hasPresentedMainWindow else { return }
            hasPresentedMainWindow = true; openWindow(id: "chat")
        }
    }
}
