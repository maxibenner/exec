import Foundation

@MainActor struct SidebarUnreadCompletionTests {
    private func snapshot(_ base: AgentJSON, id: UUID = UUID(), state: String = "completed",
                          kind: String? = "turn", error: String? = nil, storageError: String? = nil,
                          tool: String? = nil) throws -> AgentJSON {
        guard case .object(var fields) = base else { throw CheckFailure(description: "Invalid session fixture") }
        fields["operation"] = .object(["id": .string(id.uuidString), "state": .string(state),
                                       "kind": kind.map(AgentJSON.string) ?? .null,
                                       "error": error.map(AgentJSON.string) ?? .null])
        fields["storageError"] = storageError.map(AgentJSON.string) ?? .null
        fields["activeToolName"] = tool.map(AgentJSON.string) ?? .null
        return .object(fields)
    }

    private func catalog(_ fixture: LifecycleFixture, _ snapshots: [AgentJSON]) async throws {
        let summaries = try snapshots.map { snapshot -> AgentJSON in
            guard case .object(var fields) = snapshot else { throw CheckFailure(description: "Invalid catalog fixture") }
            fields.removeValue(forKey: "messages")
            return .object(fields)
        }
        try await fixture.transport.responses.reply("/v1/conversations", .array(summaries))
        try await fixture.library.refreshSharedState()
    }

    func residentCompletionsAndCatalogEchoes() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.close() }
        try await fixture.start()
        let library = fixture.library, parent = library.current
        let inView = try snapshot(fixture.root)
        // The catalog may deliver a completion before the resident catches up.
        try await catalog(fixture, [inView, fixture.child, fixture.other])
        try expect(!library.showsUnreadCompletion(fixture.parentID))
        library.openSession(fixture.otherID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == fixture.otherID)
        try parent.apply(inView.decoded(AgentSnapshot.self))
        try expect(!library.showsUnreadCompletion(fixture.parentID))

        let nextID = UUID()
        try parent.apply(snapshot(fixture.root, id: nextID, state: "running").decoded(AgentSnapshot.self))
        try expect(!library.showsUnreadCompletion(fixture.parentID))
        let completed = try snapshot(fixture.root, id: nextID)
        try parent.apply(completed.decoded(AgentSnapshot.self))
        try expect(library.showsUnreadCompletion(fixture.parentID))
        library.openSession(fixture.parentID)
        try expect(library.current === parent && !library.showsUnreadCompletion(fixture.parentID))
        library.openSession(fixture.otherID)
        try await catalog(fixture, [completed, fixture.child, fixture.other])
        try parent.apply(completed.decoded(AgentSnapshot.self))
        try expect(!library.showsUnreadCompletion(fixture.parentID))
    }

    func catalogCompletionsClearIndependentlyAfterSuccessfulVisit() async throws {
        let fixture = try LifecycleFixture(residentLimit: 1)
        defer { fixture.close() }
        let library = fixture.library
        let responses = fixture.transport.responses
        let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
        try await responses.reply("/v1/library", config)
        try await responses.reply(AgentAPI.path(fixture.otherID), snapshot(fixture.other))
        try await catalog(fixture, [snapshot(fixture.root), snapshot(fixture.child), fixture.other])
        try expect(!library.showsUnreadCompletion(fixture.parentID) && !library.showsUnreadCompletion(fixture.childID))
        library.openSession(fixture.otherID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == fixture.otherID)

        // Both IDs are nonresident; their terminals can arrive without a running read.
        let parentDone = try snapshot(fixture.root), childDone = try snapshot(fixture.child)
        try await catalog(fixture, [parentDone, childDone, fixture.other])
        try expect(library.showsUnreadCompletion(fixture.parentID) && library.showsUnreadCompletion(fixture.childID))
        let secondChildOperation = UUID()
        let waiting = try snapshot(fixture.child, id: secondChildOperation, state: "running", tool: "wait")
        try await catalog(fixture, [parentDone, waiting, fixture.other])
        try expect(library.isSessionWaiting(fixture.childID) && !library.showsUnreadCompletion(fixture.childID))
        let childDoneAgain = try snapshot(fixture.child, id: secondChildOperation)
        try await catalog(fixture, [parentDone, childDoneAgain, fixture.other])

        library.openSession(fixture.childID)
        try expect(library.openingSessionID == fixture.childID && library.showsUnreadCompletion(fixture.childID))
        library.openSession(fixture.otherID) // Supersede before the cold load starts.
        try expect(library.showsUnreadCompletion(fixture.childID))
        try await responses.reply(AgentAPI.path(fixture.childID), fixture.other) // Wrong-session response.
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == fixture.otherID && library.error != nil)
        try expect(library.showsUnreadCompletion(fixture.childID))

        try await responses.reply(AgentAPI.path(fixture.childID), childDoneAgain)
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == fixture.childID && !library.showsUnreadCompletion(fixture.childID))
        try expect(library.showsUnreadCompletion(fixture.parentID))
        library.openSession(fixture.otherID)
        await library.waitForNavigation()
        try await catalog(fixture, [parentDone, childDoneAgain, fixture.other])
        try expect(!library.showsUnreadCompletion(fixture.childID))

        try await catalog(fixture, [fixture.other]) // Confirmed cascade from another client.
        try expect(library.sessionList.map(\.id) == [fixture.otherID])
        try expect(!library.showsUnreadCompletion(fixture.parentID) && !library.showsUnreadCompletion(fixture.childID))
    }

    func nonreplyTerminalsDoNotSetBadges() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.close() }
        try await fixture.start()
        let library = fixture.library, parent = library.current
        library.openSession(fixture.otherID)
        await library.waitForNavigation()
        let cases: [(state: String, kind: String?, error: String?, storageError: String?)] = [
            ("failed", "turn", "Synthetic failure", nil),
            ("interrupted", "turn", nil, nil),
            ("completed", "compaction", nil, nil),
            ("completed", nil, nil, nil), // Legacy operations do not identify the kind.
            ("completed", "turn", nil, "Checkpoint failed")
        ]
        for item in cases {
            func result(_ base: AgentJSON) throws -> AgentJSON {
                try snapshot(base, state: item.state, kind: item.kind, error: item.error, storageError: item.storageError)
            }
            let parentResult = try result(fixture.root)
            try parent.apply(parentResult.decoded(AgentSnapshot.self))
            try await catalog(fixture, [parentResult, result(fixture.child), fixture.other])
            try expect(!library.showsUnreadCompletion(fixture.parentID) && !library.showsUnreadCompletion(fixture.childID))
        }
    }
}
