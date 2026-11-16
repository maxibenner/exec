import Foundation

@MainActor struct DelegationTests {
    func childNavigationPreservesApprovalAndDoesNotReplayWork() async throws {
        let root = try AgentIntegrationTests.fixture(state: "completed", result: true)
        guard case .object(var fields) = try AgentIntegrationTests.fixture(),
              case .object(var metadata) = fields["metadata"] else {
            throw CheckFailure(description: "Invalid fixture")
        }
        let parentID = AgentIntegrationTests.conversationID
        let childID = UUID()
        fields["id"] = .string(childID.uuidString)
        metadata["title"] = .string("Inspect the parser")
        metadata["parent"] = .object([
            "sessionId": .string(parentID.uuidString),
            "operationId": .string(AgentIntegrationTests.operationID.uuidString),
            "toolCallId": .string("delegation-call")
        ])
        fields["metadata"] = .object(metadata)
        let child = AgentJSON.object(fields)
        let snapshot = try child.decoded(AgentSnapshot.self)
        let summary = try SessionSummary(child)
        try expect(summary == SessionSummary(snapshot: snapshot))
        try expect(summary.parent?.sessionId == parentID && summary.awaitingApproval)
        try expect(try SessionSummary(root).parent == nil)

        let suite = "exec-delegation-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = FakeAgentTransport()
        let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
        try await transport.reply("/v1/library", config)
        try await transport.reply("/v1/conversations", .array([root, child]))
        try await transport.reply(AgentAPI.path(parentID), root)
        try await transport.reply(AgentAPI.path(childID), child)
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        try library.current.apply(root.decoded(AgentSnapshot.self))
        try await library.refreshSharedState()
        try expect(library.sidebarSessions.map(\.id) == [parentID])
        try expect(library.childSessions(of: parentID) == [summary])
        // A nonresident child's approval must be visible without loading its transcript.
        try expect(library.needsApproval(childID) && library.isSessionRunning(childID))
        library.openSession(childID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == childID)
        try expect(library.current.tools.pendingApproval != nil)
        try expect(library.sidebarSessions.map(\.id) == [parentID])
        try expect(library.sessionShortcuts.map { $0.session.id } == [parentID])
        try expect(library.current.summary?.parent?.sessionId == parentID)
        library.openSession(parentID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == parentID)
        try expect(library.sidebarSessions.map(\.id) == [parentID])
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.isEmpty)
        library.openSession(childID)
        await library.waitForNavigation()
        try await transport.reply("/v1/conversations", .array([root]))
        try await library.refreshSharedState()
        try expect(library.childSessions(of: parentID).isEmpty)
        try expect(library.currentSessionID == parentID)
    }

    func parentDeletionRemovesResidentChildrenWithoutWaitingForSync() async throws {
        for (deleteChild, partialFailure) in [(false, false), (false, true), (true, false)] {
            let root = try AgentIntegrationTests.fixture(state: "completed", result: true)
            guard case .object(var fields) = root,
                  case .object(var metadata) = fields["metadata"] else { throw CheckFailure(description: "Invalid fixture") }
            let parentID = AgentIntegrationTests.conversationID
            let childID = UUID()
            fields["id"] = .string(childID.uuidString)
            metadata["parent"] = .object([
                "sessionId": .string(parentID.uuidString),
                "operationId": .string(AgentIntegrationTests.operationID.uuidString),
                "toolCallId": .string("delegate")])
            fields["metadata"] = .object(metadata)
            if deleteChild {
                fields["operation"] = .object(["id": .string(AgentIntegrationTests.operationID.uuidString), "state": .string("running")])
            }
            let child = AgentJSON.object(fields)
            let transport = FakeAgentTransport()
            let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
            try await transport.reply("/v1/library", config)
            try await transport.reply("/v1/conversations", .array([root, child]))
            try await transport.reply(AgentAPI.path(childID), child)
            try await transport.reply(AgentAPI.path(parentID), root)
            let suite = "exec-cascade-\(UUID())"
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
            defer { library.closePresentations() }
            try library.current.apply(root.decoded(AgentSnapshot.self))
            try await library.refreshSharedState()
            library.openSession(childID)
            await library.waitForNavigation()
            try expect(library.currentSessionID == childID)
            let retainsParent = deleteChild || partialFailure
            let deletingID = deleteChild ? childID : parentID
            try await transport.reply("/v1/conversations", .array(retainsParent ? [root] : []))
            if partialFailure { await transport.fail(AgentAPI.path(parentID)) }
            library.deleteSession(deletingID)
            await library.waitForNavigation()
            try expect(library.currentSessionID != childID)
            try expect(library.childSessions(of: parentID).isEmpty)
            try expect(!library.openConversations.contains { $0.currentSessionID == childID })
            try expect(library.sidebarSessions.map(\.id) == (retainsParent ? [parentID] : []))
            if retainsParent { try expect(library.currentSessionID == parentID) }
            let deletions = await transport.requests.filter { $0.method == "DELETE" }
            try expect(deletions.count == 1 && deletions[0].path == AgentAPI.path(deletingID))
            try expect((library.error != nil) == partialFailure)
        }
    }

    func childSteeringUsesExistingOperation() async throws {
        for initiallyIdle in [false, true] {
            let transport = FakeAgentTransport()
            try await transport.reply("/v1/providers", .array([.object([
                "id": .string("deepseek"), "name": .string("Test"), "connected": .bool(true)])]))
            guard case .object(var fields) = try AgentIntegrationTests.fixture(state: "running"),
                  case .object(var metadata) = fields["metadata"] else { throw CheckFailure(description: "Invalid fixture") }
            metadata["parent"] = .object([
                "sessionId": .string(UUID().uuidString),
                "operationId": .string(UUID().uuidString),
                "toolCallId": .string("delegate")])
            fields["metadata"] = .object(metadata)
            let running = AgentJSON.object(fields)
            let id = AgentIntegrationTests.conversationID
            try await transport.reply(AgentAPI.path(id), running)
            let provider = AgentAccounts(api: AgentAPI(transport: transport))
            try await provider.refreshConnections()
            let store = ChatStore(provider: provider)
            defer { store.closePresentation() }
            store.installModels([ChatModel(id: "deepseek/test", name: "Test")])
            if initiallyIdle { fields["operation"] = .null }
            try store.apply(AgentJSON.object(fields).decoded(AgentSnapshot.self))
            store.draft = "Focus on cancellation"
            store.send()
            await store.waitUntilIdle()
            let writes = await transport.requests.filter { $0.method != "GET" }
            try expect(writes.count == 1 && writes[0].path == AgentAPI.path(id, "/steer"))
            let body = try JSONDecoder().decode(AgentJSON.self, from: writes[0].body!)
            try expect(body["operationID"].string == AgentIntegrationTests.operationID.uuidString.lowercased())
            try expect(body["text"].string == "Focus on cancellation")
            try expect(store.draft.isEmpty && store.error == nil)
        }
    }

    func delegationPresentationPreservesTaskAndFailure() throws {
        let call = ToolCall(id: "delegate-one", name: "delegate", arguments: #"{"task":"Inspect the parser\nReport edge cases"}"#)
        var result = ToolResult(call: call, text: "Sub-agent was interrupted. Do not retry without a new user request.")
        result.outcome = "failed"
        let presentation = ToolPresentation(call: call, result: result)
        try expect(presentation.title == "Sub-agent")
        try expect(presentation.inputs == [.init(title: "Task", text: "Inspect the parser\nReport edge cases")])
        try expect(presentation.output == result.text && presentation.detail == "Error")
        let batch = ToolCall(id: "batch", name: "delegate", arguments: #"{"tasks":["Inspect parser","Inspect tests"]}"#)
        let batchPresentation = ToolPresentation(call: batch, result: nil)
        try expect(batchPresentation.title == "Sub-agents")
        try expect(batchPresentation.inputs == [.init(title: "Task 1", text: "Inspect parser"), .init(title: "Task 2", text: "Inspect tests")])
    }
}
