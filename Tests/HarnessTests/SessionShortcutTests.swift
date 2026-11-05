import Foundation

@MainActor struct SessionShortcutTests {
    func shortcutsFollowSidebarOrderAndPreserveNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        defer { library.stopAll() }
        try expect(library.sessionShortcuts.isEmpty)
        for index in 1...11 {
            let messages = [Message(role: .user, text: "Session \(index)")]
            try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity,
                selectedModel: "test", messages: messages, history: messages, activeTurn: false), id: UUID())
        }
        library.restore()
        try await settle(library)
        try expect(library.sessionList.count == 11)
        try expect(library.sessionShortcuts.map(\.number) == Array(1...9))
        let order = library.sessionList.map(\.id)
        try expect(library.sessionShortcuts.map { $0.session.id } == Array(order.prefix(9)))
        let first = library.current
        library.draft = "Keep this draft while switching"
        let ninth = library.sessionShortcuts[8].session.id
        library.openSession(ninth)
        try await settle(library)
        try expect(library.currentSessionID == ninth && first.draft == "Keep this draft while switching")
        try expect(library.sessionList.map(\.id) == order)

        // Rows beyond nine remain normally navigable, but never receive a shortcut.
        try expect(!library.sessionShortcuts.contains { $0.session.id == order[9] })
        library.openSession(order[9])
        try await settle(library)
        try expect(library.currentSessionID == order[9])
        library.openSession(first.currentSessionID!)
        try await settle(library)
        try expect(library.draft == "Keep this draft while switching")

        // Removing rows updates both destinations and hints, without stale entries.
        for id in order.suffix(3) {
            library.deleteSession(id)
            try await settle(library)
        }
        try expect(library.sessionList.count == 8)
        try expect(library.sessionShortcuts.map(\.number) == Array(1...8))
        try expect(library.sessionShortcuts.map { $0.session.id } == library.sessionList.map(\.id))

        // Keyboard/menu navigation uses the same authentication guard as a click.
        let selected = library.currentSessionID
        library.restore()
        try expect(!library.canNavigate)
        library.openSession(ninth)
        try expect(library.currentSessionID == selected)
        try await settle(library)
    }

    private func settle(_ library: ChatLibrary) async throws {
        for _ in 0..<400 {
            if !library.hasRunningOperations && !library.authenticating { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Session shortcut navigation did not settle")
    }
}
