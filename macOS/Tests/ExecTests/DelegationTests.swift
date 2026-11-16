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
        try expect(library.sidebarSessions.contains { $0.id == childID })
        try expect(library.current.summary?.parent?.sessionId == parentID)
        library.openSession(parentID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == parentID)
        try expect(library.sidebarSessions.map(\.id) == [parentID])
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.isEmpty)
    }

    func delegationPresentationPreservesTaskAndFailure() throws {
        let call = ToolCall(id: "delegate-one", name: "delegate", arguments: #"{"task":"Inspect the parser\nReport edge cases"}"#)
        var result = ToolResult(call: call, text: "Sub-agent was interrupted. Do not retry without a new user request.")
        result.outcome = "failed"
        let presentation = ToolPresentation(call: call, result: result)
        try expect(presentation.title == "Sub-agent")
        try expect(presentation.inputs == [.init(title: "Task", text: "Inspect the parser\nReport edge cases")])
        try expect(presentation.output == result.text && presentation.detail == "Error")
    }
}
