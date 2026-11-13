import AppKit

@MainActor struct QuitConfirmationTests {
    func nativeConfirmationSheetCancelsCleanly() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
            window.close()
        }
        let delegate = AppDelegate()
        for _ in 0..<2 {
            let alert = NSAlert()
            alert.messageText = "Quit confirmation test"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            var response: NSApplication.ModalResponse?
            let presentation = Task { response = await delegate.confirmQuit(alert, window) }
            try await wait { window.attachedSheet === alert.window }
            alert.buttons[1].performClick(nil)
            try await wait { response != nil && window.attachedSheet == nil }
            await presentation.value
            try expect(response == .alertSecondButtonReturn)
        }
    }

    func draftsDoNotPrompt() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let library = fixture.library
        let first = library.current
        first.draft = "Unsent in the background"
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        library.current.draft = "Unsent in the active composer"
        try expect(library.current !== first && library.hasUnsentDrafts && !library.hasUnsavedChanges)

        let delegate = AppDelegate()
        delegate.store = library
        var prompts = 0
        var replies: [Bool] = []
        delegate.confirmQuit = { _, _ in prompts += 1; return .alertSecondButtonReturn }
        delegate.replyToTermination = { _, reply in replies.append(reply) }
        try expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        await Task.yield()
        try expect(prompts == 0 && replies.isEmpty)
        try expect(first.draft == "Unsent in the background" && library.current.draft == "Unsent in the active composer")
    }

    func cancelCoalescesRequestsAndConfirmedQuitWaitsForTasks() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let library = fixture.library
        let first = library.current
        fixture.provider.children.last!.holdOpen = true
        first.draft = "First task"
        library.send()
        try await wait { fixture.provider.children.last?.pending != nil }
        library.newConversation()
        try await wait { !library.navigating }
        let second = library.current
        fixture.provider.children.last!.holdOpen = true
        second.draft = "Second task"
        library.send()
        try await wait { fixture.provider.children.last?.pending != nil }
        try expect(first.busy && second.busy)

        let delegate = AppDelegate()
        delegate.store = library
        var decision: CheckedContinuation<NSApplication.ModalResponse, Never>?
        var prompts = 0
        var replies: [Bool] = []
        var replyReentry: NSApplication.TerminateReply?
        var stillRunningAtQuit = true
        var alertText = ""
        delegate.confirmQuit = { alert, _ in
            prompts += 1
            alertText = alert.informativeText
            return await withCheckedContinuation { decision = $0 }
        }
        delegate.replyToTermination = { [weak delegate] application, reply in
            replies.append(reply)
            if reply { stillRunningAtQuit = library.hasRunningOperations }
            else { replyReentry = delegate?.applicationShouldTerminate(application) }
        }
        defer { decision?.resume(returning: .alertSecondButtonReturn) }
        let app = NSApplication.shared
        try expect(delegate.applicationShouldTerminate(app) == .terminateLater)
        try expect(delegate.applicationShouldTerminate(app) == .terminateLater)
        try await wait { decision != nil }
        try expect(prompts == 1 && alertText.contains("Active operations") && !alertText.contains("Unsent"))
        try expect(delegate.applicationShouldTerminate(app) == .terminateLater)
        decision?.resume(returning: .alertSecondButtonReturn); decision = nil
        try await wait { replies == [false] }
        try await Task.sleep(for: .milliseconds(30))
        try expect(replyReentry == .terminateLater && prompts == 1)
        try expect(first.busy && second.busy)

        // A genuinely new user request may show one new confirmation after Cancel.
        try expect(delegate.applicationShouldTerminate(app) == .terminateLater)
        try await wait { decision != nil }
        try expect(prompts == 2)
        decision?.resume(returning: .alertFirstButtonReturn); decision = nil
        try expect(delegate.applicationShouldTerminate(app) == .terminateLater)
        try await wait { replies == [false, true] }
        try expect(prompts == 2 && !stillRunningAtQuit)
        try expect(first.messages.last?.status == .interrupted && second.messages.last?.status == .interrupted)
        for conversation in [first, second] {
            let saved = try await fixture.sessions.load(id: conversation.currentSessionID!)
            try expect(saved?.activeTurn == false && saved?.messages.last?.status == .interrupted)
        }
    }

    func failedSavesStillPromptWithoutClaimingTasksAreRunning() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let directory = fixture.root.appendingPathComponent("sessions")
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        do {
            try await fixture.library.current.saveIfIdle(force: true)
            throw CheckFailure(description: "Expected isolated save failure")
        } catch is ExecError {}
        try expect(fixture.library.hasUnsavedChanges && !fixture.library.hasRunningOperations)
        let delegate = AppDelegate()
        delegate.store = fixture.library
        var message = ""
        var replies: [Bool] = []
        delegate.confirmQuit = { alert, _ in
            message = alert.informativeText
            return .alertSecondButtonReturn
        }
        delegate.replyToTermination = { _, reply in replies.append(reply) }
        try expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await wait { replies == [false] }
        try expect(message.contains("could not be saved") && !message.contains("Active operations"))
    }

    @MainActor private struct Fixture {
        let root: URL
        let suite: String
        let preferences: UserDefaults
        let provider: FakeProvider
        let sessions: SessionStore
        let library: ChatLibrary

        static func make() async throws -> Fixture {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let suite = "ExecQuitTests.\(UUID())"
            let preferences = UserDefaults(suiteName: suite)!
            let provider = FakeProvider()
            let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
            let library = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
            library.generatedTitlesEnabled = false
            library.restore()
            try await QuitConfirmationTests.wait { !library.hasRunningOperations }
            library.selectWorkspace(root)
            try await QuitConfirmationTests.wait { !library.hasRunningOperations }
            return Fixture(root: root, suite: suite, preferences: preferences, provider: provider,
                           sessions: sessions, library: library)
        }

        func cleanup() {
            library.stopAll()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Quit confirmation did not settle")
    }

    private func wait(_ condition: () -> Bool) async throws { try await Self.wait(condition) }
}
