import Foundation

@MainActor struct SessionOrderingTests {
    func migratesAndPersistsOrderWithoutChangingSelectionOrOtherAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = SessionStore(directory: root)
        let a = [UUID(), UUID(), UUID()]
        let b = [UUID(), UUID()]
        func snapshot(_ identity: String, _ date: Double) -> SessionSnapshot {
            SessionSnapshot(identity: identity, selectedModel: "test", messages: [], history: [],
                            activeTurn: false, activityDate: Date(timeIntervalSince1970: date))
        }
        for (id, identity, date) in [(a[0], "a", 30.0), (b[0], "b", 40), (a[1], "a", 10), (b[1], "b", 20), (a[2], "a", 50)] {
            try await original.save(snapshot(identity, date), id: id)
        }
        try await original.select(a[0])
        // Old indexes stored checkpoint order but displayed activity order.
        let indexURL = root.appendingPathComponent("index.json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
        legacy.removeValue(forKey: "stableOrder")
        try JSONSerialization.data(withJSONObject: legacy).write(to: indexURL)
        let store = SessionStore(directory: root)
        let migrated = try await store.list(identity: "a")
        try expect(migrated.map(\.id) == [a[2], a[0], a[1]])
        let order = [a[1], a[2], a[0]]
        try await store.reorder(order, identity: "a")
        try await store.save(snapshot("a", 100), id: a[1], select: false)
        try await store.rename(id: a[2], title: "Renamed", identity: "a")
        let updated = try await store.list(identity: "a")
        try expect(updated.map(\.id) == order)
        let restarted = SessionStore(directory: root)
        let restored = try await restarted.list(identity: "a")
        let other = try await restarted.list(identity: "b")
        let selected = try await restarted.preferredID(identity: "a")
        let mostRecent = try await restarted.preferredID(identity: "a", mostRecent: true)
        try expect(restored.map(\.id) == order && other.map(\.id) == b)
        try expect(selected == a[0] && mostRecent == a[1])
        let extra = UUID()
        try await restarted.save(snapshot("a", 200), id: extra, select: false)
        try await restarted.delete(id: a[2])
        let afterDeletion = try await restarted.list(identity: "a")
        try expect(afterDeletion.map(\.id) == [extra, a[1], a[0]])

        // Reject foreign/duplicate IDs, and never publish a failed disk reorder.
        for invalid in [[b[0], a[1], a[0]], [extra, a[1], a[1]]] {
            do {
                try await restarted.reorder(invalid, identity: "a")
                throw CheckFailure(description: "Expected invalid order rejection")
            } catch is ExecError {}
        }
        let durable = try Data(contentsOf: indexURL)
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        do {
            try await restarted.reorder([a[0], a[1], extra], identity: "a")
            throw CheckFailure(description: "Expected reorder write failure")
        } catch is ExecError {}
        let afterFailure = try await restarted.list(identity: "a")
        try expect(afterFailure.map(\.id) == afterDeletion.map(\.id))
        try FileManager.default.removeItem(at: indexURL)
        try durable.write(to: indexURL)
    }

    func movesStayStableDuringActivityAndKeepDraftsAndShortcuts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        for index in 0..<3 {
            let messages = [Message(role: .user, text: "Session \(index)")]
            try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity, selectedModel: "test",
                messages: messages, history: messages, activeTurn: false), id: UUID())
        }
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        let order = library.sessionList.map(\.id)
        library.openSession(order[2])
        try await wait { !library.hasRunningOperations }
        let runner = provider.children.last!
        runner.holdOpen = true
        library.draft = "Continue the oldest session"
        library.send()
        try await wait { runner.pending != nil }
        try expect(library.sessionList.map(\.id) == order)
        library.draft = "Keep this unsent draft"
        library.moveSessions(from: IndexSet(integer: 2), to: 0)
        try await wait { !library.navigating }
        let moved = [order[2], order[0], order[1]]
        try expect(library.error == nil && library.sessionList.map(\.id) == moved)
        try expect(library.currentSessionID == order[2] && library.current.busy)
        try expect(library.draft == "Keep this unsent draft")
        runner.pending?.yield(.completed)
        runner.pending?.finish()
        try await wait { !library.hasRunningOperations }
        library.renameSession(order[0], title: "Renamed")
        try await wait { !library.hasRunningOperations }
        try expect(library.sessionList.map(\.id) == moved)
        library.moveSessions(from: IndexSet([0, 2]), to: 3)
        try await wait { !library.hasRunningOperations }
        let reordered = [order[0], order[2], order[1]]
        try expect(library.sessionList.map(\.id) == reordered)
        try expect(library.sessionShortcuts.map { $0.session.id } == reordered)

        // Unsaved visible drafts can be moved too; saving their position must not
        // clear their draft or change the selected conversation.
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        library.draft = "Unsent new session"
        let draftID = library.currentSessionID!
        try expect(library.sessionList.first?.id == draftID)
        library.moveSessions(from: IndexSet(integer: 0), to: 4)
        try await wait { !library.hasRunningOperations }
        try expect(library.error == nil && library.sessionList.map(\.id) == reordered + [draftID])
        try expect(library.currentSessionID == draftID && library.draft == "Unsent new session")
        library.moveSessions(from: IndexSet(integer: 99), to: 0)
        try expect(library.sessionList.map(\.id) == reordered + [draftID])
        let restarted = try ChatLibrary(provider: FakeProvider(), sessions: SessionStore(directory: root))
        defer { restarted.stopAll() }
        restarted.restore()
        try await wait { !restarted.hasRunningOperations }
        try expect(restarted.sessionList.map(\.id) == reordered + [draftID])
        try expect(restarted.sessionShortcuts.map { $0.session.id } == reordered + [draftID])
    }

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<400 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Session ordering did not settle")
    }
}
