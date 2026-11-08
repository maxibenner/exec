import AppKit
import SwiftUI

@MainActor struct OptimisticStartupTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Startup did not settle")
    }

    private struct WindowContent: View {
        let library: ChatLibrary
        let windows: SessionWindows
        @FocusState private var focused: Bool

        var body: some View {
            ChatWindowLayout(initiallyShowsSidebar: true) {
                SessionSidebar(store: library, open: { _ in }, delete: { _ in })
            } detail: {
                ConversationView(library: library, conversation: library.current,
                                 presentation: windows.presentation(for: library.current), focused: $focused)
            }
        }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private struct Fixture {
        let sessions: SessionStore
        let cache: AccountMetadataCache
        let account: AccountPresentation
        let usage: AccountUsage
        let id: UUID
        let file: URL
    }

    private func fixture(_ root: URL, providerState: Data? = nil) async throws -> Fixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let cache = AccountMetadataCache(directory: root.appendingPathComponent("cache"))
        let account = AccountPresentation(providerName: "Test", connectionTitle: "Connect to Test",
                                          accountName: "test@example.com", conversationIdentity: "test@example.com")
        let usage = AccountUsage(windows: [
            .init(durationSeconds: 18000, usedPercent: 20, resetsAt: Date().addingTimeInterval(3600)),
            .init(durationSeconds: 604800, usedPercent: 40, resetsAt: Date().addingTimeInterval(7200))])
        await cache.saveStartupAccount(account)
        await cache.saveModels([.init(id: "test", name: "Test", efforts: [.init(id: "high", name: "High")])],
                               fetchedAt: .now, key: account.metadataKey)
        await cache.saveUsage(.init(usage: usage, fetchedAt: .now), key: account.metadataKey)
        let messages = [Message(role: .user, text: "Saved conversation"), Message(role: .assistant, text: "Saved reply")]
        let id = try await sessions.save(SessionSnapshot(identity: account.conversationIdentity,
            workspace: Workspace.load(root), selectedModel: "test", messages: messages, history: messages,
            providerState: providerState, activeTurn: false, effort: "high", autoApproveTools: true), id: UUID())
        return Fixture(sessions: sessions, cache: cache, account: account, usage: usage, id: id,
                       file: root.appendingPathComponent("sessions/\(id).json"))
    }

    func rendersBeforeCredentialsAndReconcilesInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await fixture(root)
        let original = try Data(contentsOf: saved.file)
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let startup = ChatStartup()
        let live = FakeProvider()
        live.availableModels = [.init(id: "test", name: "Test", efforts: [.init(id: "high", name: "High")])]
        live.usageAction = { saved.usage }
        var pending: CheckedContinuation<Void, Never>?
        var credentialReads = 0
        startup.start(makeSessions: { saved.sessions }, cache: saved.cache, preferences: preferences) {
            credentialReads += 1
            // A usable cached presentation is published before the credential loader even starts.
            try expect(startup.store?.account == saved.account.accountName)
            try expect(startup.store?.accountUsage == saved.usage)
            try expect(startup.store?.currentSessionID == saved.id)
            await withCheckedContinuation { pending = $0 }
            return live
        }
        defer { pending?.resume(); startup.cancel() }
        try await wait { pending != nil }
        let library = startup.store!
        let current = library.current
        let windows = startup.windows!
        let transcript = windows.presentation(for: current)
        try expect(library.isPresentingStartup && library.authenticating && !library.hasRunningOperations)
        try expect(library.sidebarSessions.map(\.id) == [saved.id] && library.messages.last?.text == "Saved reply")
        try expect(library.current.selectedModel == "test" && library.current.selectedEffort == "high")
        try expect(library.current.autoApproveTools && library.tools.autoApprovedDirectory == nil)
        try expect(!library.canNavigate && !current.canEditDraft)
        library.send(); library.newConversation(); library.disconnect()
        current.send(); current.compact()
        try await current.saveIfIdle(force: true)
        try expect(library.current === current && live.children.isEmpty)
        try expect(try Data(contentsOf: saved.file) == original)
        _ = NSApplication.shared
        let window = NSWindow(contentViewController: NSHostingController(rootView: WindowContent(library: library, windows: windows)))
        window.setContentSize(NSSize(width: 980, height: 700))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await settle(window)
        let frame = window.frame
        let contentRect = window.contentLayoutRect
        let toolbar = window.toolbar
        try expect(toolbar != nil)
        pending?.resume(); pending = nil
        try await wait { !startup.starting && !library.hasRunningOperations }
        try await settle(window)
        try expect(window.frame == frame && window.contentLayoutRect == contentRect && window.toolbar === toolbar)
        try expect(startup.error == nil && !library.isPresentingStartup && library.canNavigate)
        try expect(startup.store === library && library.current === current && startup.windows === windows)
        try expect(windows.presentation(for: current) === transcript)
        try expect(library.accountUsage == saved.usage && library.currentSessionID == saved.id)
        try expect(credentialReads == 1 && live.children[0].inputs.isEmpty)
        let remembered = await saved.cache.startupAccount()
        try expect(remembered == saved.account)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("cache/startup.json").path)
        try expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    func rejectsMismatchesAndClearsSignout() async throws {
        for account in [String?.none, "other@example.com"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let saved = try await fixture(root)
            let original = try Data(contentsOf: saved.file)
            let startup = ChatStartup()
            let live = FakeProvider()
            live.account = account
            startup.start(makeSessions: { saved.sessions }, cache: saved.cache,
                          preferences: UserDefaults(suiteName: UUID().uuidString)!) { live }
            defer { startup.cancel() }
            try await wait { startup.store != nil && !startup.starting && startup.store?.hasRunningOperations == false }
            let library = startup.store!
            try expect(library.account == account && library.messages.isEmpty && library.workspace == nil)
            try expect(library.sidebarSessions.isEmpty && library.accountUsage == nil)
            let evicted = await saved.cache.load(key: saved.account.metadataKey)
            try expect(evicted.models.isEmpty && evicted.usage == nil)
            let pointer = await saved.cache.startupAccount()
            try expect(pointer?.accountName == account)
            try expect(try Data(contentsOf: saved.file) == original)
            if account != nil {
                library.disconnect()
                try await wait { !library.hasRunningOperations }
                let signedOut = await saved.cache.startupAccount()
                try expect(signedOut == nil)
            }
        }
    }

    func credentialFailureRetryAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await fixture(root)
        let startup = ChatStartup()
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        var reads = 0
        startup.start(makeSessions: { saved.sessions }, cache: saved.cache, preferences: preferences) {
            reads += 1
            throw ExecError("Credential store unavailable")
        }
        try await wait { !startup.starting }
        let preview = startup.store!
        try expect(startup.error != nil && preview.isPresentingStartup && !preview.canNavigate)
        try expect(preview.accountUsage == saved.usage && !preview.hasRunningOperations && reads == 1)
        var pending: CheckedContinuation<Void, Never>?
        let live = FakeProvider()
        startup.start(makeSessions: { saved.sessions }, cache: saved.cache, preferences: preferences) {
            reads += 1
            await withCheckedContinuation { pending = $0 }
            return live
        }
        defer { pending?.resume(); startup.cancel() }
        try await wait { pending != nil }
        startup.cancel()
        pending?.resume(); pending = nil
        try await wait { !startup.starting }
        try expect(preview.isPresentingStartup && !preview.canNavigate && live.children.isEmpty && reads == 2)
        // Only an explicit retry may enable the existing presentation.
        startup.start(makeSessions: { saved.sessions }, cache: saved.cache, preferences: preferences) {
            reads += 1
            return live
        }
        try await wait { !startup.starting && !preview.hasRunningOperations }
        try expect(startup.store === preview && !preview.isPresentingStartup && startup.error == nil && reads == 3)
    }

    func corruptionAndProviderStateRemainSafe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await fixture(root, providerState: Data("unreadable provider state".utf8))
        let original = try Data(contentsOf: saved.file)
        let preview = try await ChatLibrary.startupPresentation(sessions: saved.sessions, cache: saved.cache)!
        try expect(preview.messages.last?.text == "Saved reply") // Opaque state was not interpreted for display.
        let live = FakeProvider()
        try await preview.reconcileStartup(with: live)
        try await wait { !preview.hasRunningOperations }
        preview.draft = "Do not send from invalid context"
        preview.send()
        try await wait { !preview.hasRunningOperations }
        try expect(preview.error != nil && live.children[0].inputs.isEmpty)
        try expect(try Data(contentsOf: saved.file) == original)
        preview.stopAll()
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("cache/startup.json"))
        let corrupt = try await ChatLibrary.startupPresentation(sessions: saved.sessions, cache: saved.cache)
        try expect(corrupt == nil)
        let startup = ChatStartup()
        let signedOut = FakeProvider(); signedOut.account = nil
        startup.start(makeSessions: { saved.sessions }, cache: saved.cache) { signedOut }
        defer { startup.cancel() }
        try await wait { startup.store != nil && !startup.starting && startup.store?.hasRunningOperations == false }
        try expect(startup.error == nil && startup.store?.account == nil)
    }

    func expiredUsageKeepsItsGeometry() throws {
        _ = NSApplication.shared
        let usage = AccountUsage(windows: [
            .init(durationSeconds: 18000, usedPercent: 20, resetsAt: Date().addingTimeInterval(3600)),
            .init(durationSeconds: 604800, usedPercent: 40, resetsAt: Date().addingTimeInterval(7200))])
        let recent = NSHostingView(rootView: AccountUsageLabel(usage: usage, fetchedAt: .now).frame(width: 240))
        let expired = NSHostingView(rootView: AccountUsageLabel(usage: usage,
            fetchedAt: Date().addingTimeInterval(-301)).frame(width: 240))
        try expect(recent.fittingSize == expired.fittingSize)
        try expect(CachedAccountUsage(usage: usage, fetchedAt: Date().addingTimeInterval(-301)).current() == nil)
    }
}
