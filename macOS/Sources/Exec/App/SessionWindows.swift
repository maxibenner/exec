import AppKit
import SwiftUI
import Observation

/// Window controllers own presentation only. ChatLibrary retains every detached
/// conversation, including during a drag, window close, or background response.
@MainActor @Observable final class SessionWindows {
    let library: ChatLibrary
    weak var mainWindow: NSWindow?
    @ObservationIgnored var reopenMainWindow: (() -> Void)?
    private(set) var activeDetachedID: UUID?
    @ObservationIgnored private var controllers: [UUID: DetachedSessionController] = [:]
    @ObservationIgnored private var presentations: [ObjectIdentifier: TranscriptState] = [:]

    private(set) var composerFocusRequest = 0

    init(library: ChatLibrary) { self.library = library }

    func openSession(_ id: UUID) {
        library.openSession(id) { [weak self] in
            self?.composerFocusRequest += 1
        }
    }

    func presentation(for conversation: ChatStore) -> TranscriptState {
        let residents = Set(library.openConversations.map(ObjectIdentifier.init))
        presentations = presentations.filter { residents.contains($0.key) }
        let key = ObjectIdentifier(conversation)
        if let state = presentations[key] { return state }
        let state = TranscriptState()
        presentations[key] = state
        return state
    }

    func detach(_ id: UUID, at point: NSPoint? = nil) {
        if let controller = controllers[id] {
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        library.detachSession(id) { [weak self] conversation in
            guard let self else { return }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 500, height: 480)
            window.tabbingMode = .disallowed
            window.title = self.title(for: id)
            window.contentView = NSHostingView(rootView: DetachedConversationView(
                windows: self, conversation: conversation, presentation: self.presentation(for: conversation)))
            let controller = DetachedSessionController(window: window)
            controller.didClose = { [weak self] in
                guard let self else { return }
                self.library.attachSession(id)
                self.controllers[id] = nil
                if self.activeDetachedID == id { self.activeDetachedID = nil }
            }
            controller.becameKey = { [weak self] in self?.activeDetachedID = id }
            controller.resignedKey = { [weak self] in
                if self?.activeDetachedID == id { self?.activeDetachedID = nil }
            }
            self.controllers[id] = controller
            window.center()
            if let point {
                let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
                var origin = NSPoint(x: point.x - window.frame.width / 2, y: point.y - window.frame.height + 24)
                if let screen {
                    origin.x = max(screen.minX, min(origin.x, screen.maxX - window.frame.width))
                    origin.y = max(screen.minY, min(origin.y, screen.maxY - window.frame.height))
                }
                window.setFrameOrigin(origin)
            }
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func attach(_ id: UUID, before nextID: UUID? = nil, reorder: Bool = false) {
        controllers[id]?.close()
        library.attachSession(id)
        if reorder { library.moveSession(id, before: nextID) }
        showMainWindow()
    }

    func showMainWindow() {
        if let mainWindow, mainWindow.isVisible { mainWindow.makeKeyAndOrderFront(nil) }
        else if let reopenMainWindow { reopenMainWindow() }
        else { mainWindow?.makeKeyAndOrderFront(nil) }
    }

    func closeInvalidWindows() {
        for (id, controller) in Array(controllers) where !library.detachedSessionIDs.contains(id) {
            controller.close()
        }
    }

    func title(for id: UUID) -> String {
        library.sessionList.first { $0.id == id }?.title ?? "Conversation"
    }

}

@MainActor private final class DetachedSessionController: NSWindowController, NSWindowDelegate {
    var didClose: (() -> Void)?
    var becameKey: (() -> Void)?
    var resignedKey: (() -> Void)?

    override init(window: NSWindow?) {
        super.init(window: window)
        window?.delegate = self
        ChatWindowAppearance.configure(window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { didClose?() }
    func windowDidBecomeKey(_ notification: Notification) { becameKey?() }
    func windowDidResignKey(_ notification: Notification) { resignedKey?() }
}

private struct DetachedConversationView: View {
    let windows: SessionWindows
    let conversation: ChatStore
    let presentation: TranscriptState
    @FocusState private var composerFocused: Bool

    var body: some View {
        ConversationView(library: windows.library, conversation: conversation, presentation: presentation,
                         focused: $composerFocused)
            .modifier(SessionCommandScope(windows: windows, conversation: conversation))
            .onAppear { composerFocused = true }
            .onChange(of: windows.library.detachedSessionIDs) { _, _ in windows.closeInvalidWindows() }
    }
}

struct WindowReference: NSViewRepresentable {
    let resolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ReferenceView { ReferenceView(resolve: resolve) }
    func updateNSView(_ view: ReferenceView, context: Context) {}

    final class ReferenceView: NSView {
        let resolve: (NSWindow?) -> Void
        init(resolve: @escaping (NSWindow?) -> Void) { self.resolve = resolve; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolve(window) }
    }
}
