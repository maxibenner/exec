import AppKit

@MainActor struct QuitLifecycleTests {
    /// Exercise AppKit itself, not just direct delegate calls. This subprocess
    /// owns no helper, profile, credentials or user windows.
    func commandQuitAwaitsShutdown() async throws {
        for runLoopOrigin in [false, true] {
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--quit-appkit"] + (runLoopOrigin ? ["--run-loop"] : [])
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let status = await Task.detached {
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            try expect(status == 0)
        }
    }

    static func runAppKitProbe() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = QuitProbeDelegate()
        app.delegate = delegate
        let menu = NSMenu()
        let item = NSMenuItem()
        let applicationMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        applicationMenu.addItem(quit)
        item.submenu = applicationMenu
        menu.addItem(item)
        app.mainMenu = menu
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            FileHandle.standardError.write(Data("FAIL isolated Command-Q: async termination stalled\n".utf8))
            exit(1)
        }
        let requestQuit: @MainActor @Sendable () -> Void = {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12),
                  menu.performKeyEquivalent(with: event) else { exit(1) }
        }
        if CommandLine.arguments.contains("--run-loop") {
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { requestQuit() } }
        } else {
            // This caller must unwind before main-actor cleanup can run.
            DispatchQueue.main.async { requestQuit() }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private final class QuitProbeDelegate: NSObject, NSApplicationDelegate {
    let tested = AppDelegate()
    private var shutdowns = 0
    private var settled = false

    override init() {
        super.init()
        tested.shutdownBackend = { [self] in
            shutdowns += 1
            NSApplication.shared.terminate(nil) // A repeated request must not restart cleanup.
            try? await Task.sleep(for: .milliseconds(100))
            settled = true
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        tested.applicationShouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard settled, shutdowns == 1 else {
            FileHandle.standardError.write(Data("FAIL isolated Command-Q: quit before shutdown settled\n".utf8))
            exit(1)
        }
    }
}
