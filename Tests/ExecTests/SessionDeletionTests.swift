import Foundation

@MainActor struct SessionDeletionTests {
    func selectsAdjacentRowsInSidebarOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, sessions, ids) = try await fixture(root, count: 4)
        defer { library.stopAll() }
        let order = [ids[2], ids[0], ids[3], ids[1]]
        library.moveSession(ids[2], before: ids[0])
        try await settle(library)
        library.moveSession(ids[3], before: ids[1])
        try await settle(library)
        try expect(library.sessionList.map(\.id) == order)
        library.openSession(order[0])
        try await settle(library)
        try expect(!library.openConversations.contains { $0.currentSessionID == order[1] })

        // The next row is not resident: load it and persist its selection.
        library.deleteSession(order[0])
        try await settle(library)
        try expect(library.error == nil && library.sidebarSelectionID == order[1])
        try expect(library.messages.first?.text == "Session 0")
        let selected = try await sessions.preferredID(identity: library.current.conversationIdentity)
        try expect(selected == order[1])

        library.openSession(order[3])
        try await settle(library)
        let resident = library.current
        library.draft = "Keep this draft"
        library.openSession(order[2])
        try await settle(library)
        // Selecting a resident neighbor keeps its draft and runner intact.
        library.deleteSession(order[2])
        try await settle(library)
        try expect(library.current === resident && library.draft == "Keep this draft")
        try expect(library.sidebarSelectionID == order[3])

        // No row below the last item: select the one above instead.
        library.deleteSession(order[3])
        try await settle(library)
        try expect(library.error == nil && library.sidebarSelectionID == order[1])
        try expect(library.sessionList.map(\.id) == [order[1]])
        library.deleteSession(order[1])
        try await settle(library)
        try expect(library.error == nil && library.sessionList.isEmpty && library.messages.isEmpty)
        try expect(!ids.contains(library.currentSessionID!))
        let finalSelection = try await sessions.preferredID(identity: library.current.conversationIdentity)
        try expect(finalSelection == nil)
    }

    func deletionAndNeighborLoadFailuresStayRecoverable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, sessions, ids) = try await fixture(root, count: 2)
        defer { library.stopAll() }
        let original = library.current
        let file = root.appendingPathComponent("\(ids[0]).json")
        let bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        library.deleteSession(ids[0])
        try await settle(library)
        try expect(library.error != nil && library.current === original)
        try expect(library.sidebarSelectionID == ids[0] && library.sessionList.map(\.id) == ids)

        try FileManager.default.removeItem(at: file)
        try bytes.write(to: file)
        try Data("not JSON".utf8).write(to: root.appendingPathComponent("\(ids[1]).json"))
        library.deleteSession(ids[0])
        try await settle(library)
        try expect(library.error != nil && library.current !== original && library.messages.isEmpty)
        try expect(!library.sessionList.contains { $0.id == ids[0] })
        try expect(!library.openConversations.contains { $0 === original })
        let deleted = try await sessions.load(id: ids[0])
        try expect(deleted == nil)
    }

    private func fixture(_ root: URL, count: Int) async throws -> (ChatLibrary, SessionStore, [UUID]) {
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let ids = (0..<count).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            let messages = [Message(role: .user, text: "Session \(index)")]
            try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity, selectedModel: "test",
                messages: messages, history: messages, activeTurn: false), id: id)
        }
        try await sessions.reorder(ids, identity: provider.conversationIdentity)
        try await sessions.select(ids[0])
        let library = try ChatLibrary(provider: provider, sessions: sessions, residentLimit: 1)
        library.restore()
        try await settle(library)
        return (library, sessions, ids)
    }

    private func settle(_ library: ChatLibrary) async throws {
        for _ in 0..<400 {
            if !library.hasRunningOperations { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Session deletion did not settle")
    }
}
