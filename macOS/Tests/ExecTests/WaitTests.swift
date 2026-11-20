import AppKit

@MainActor struct WaitTests {
    private let arguments = #"{"duration_seconds":60,"description":"Waiting for CI checks","wake_prompt":"Check the existing run.\nWait again only if it is still pending."}"#

    private func snapshot(_ base: AgentJSON, state: String = "running", active: Bool = true, outcome: String? = nil) throws -> AgentJSON {
        guard case .object(var fields) = base else { throw CheckFailure(description: "Invalid wait fixture") }
        var messages = Array(base["messages"].array.prefix(1))
        messages.append(.object([
            "id": .string(AgentIntegrationTests.assistantID.uuidString), "role": .string("assistant"),
            "text": .string(""), "status": .string("completed"),
            "calls": .array([.object(["id": .string("wait-call"), "name": .string("wait"),
                "arguments": try JSONDecoder().decode(AgentJSON.self, from: Data(arguments.utf8))])])]))
        if let outcome {
            messages.append(.object(["id": .string(AgentIntegrationTests.toolID.uuidString), "role": .string("tool"),
                "callID": .string("wait-call"), "text": .string("Wait result"), "outcome": .string(outcome)]))
        }
        fields["messages"] = .array(messages)
        fields["operation"] = .object(["id": base["operation"]["id"], "state": .string(state)])
        fields["approval"] = .null
        fields["activeToolCallID"] = active ? .string("wait-call") : .null
        fields["activeToolName"] = active ? .string("wait") : .null
        return .object(fields)
    }

    func presentationPreservesInputsAndOutcomes() throws {
        let call = ToolCall(id: "wait-call", name: "wait", arguments: arguments)
        let pending = ToolPresentation(call: call)
        try expect(pending.title == "Wait" && pending.icon == "stopwatch")
        try expect(pending.summary == "Waiting for CI checks")
        try expect(!pending.showsOutput)
        try expect(pending.inputs == [
            .init(title: "Duration", text: "60s"),
            .init(title: "Wake prompt", text: "Check the existing run.\nWait again only if it is still pending.")])
        for (outcome, detail) in [("completed", nil), ("interrupted", "Interrupted"), ("failed", "Error"), ("not_executed", "Not run")] as [(String, String?)] {
            var result = ToolResult(call: call, text: "Exact result\n")
            result.outcome = outcome
            let presentation = ToolPresentation(call: call, result: result)
            try expect(presentation.inputs == pending.inputs && presentation.detail == detail)
            try expect(!presentation.showsOutput)
            try expect(presentation.summary == pending.summary)
            try expect(presentation.output == result.text) // Model context remains intact.
        }
        let malformed = ToolPresentation(name: "wait", arguments: "{broken")
        try expect(!malformed.showsOutput)
        try expect(malformed.inputs == [.init(title: "Arguments", text: "{broken")])
    }

    func activityOnlySyncPreservesPendingRowAndClearsWaiting() async throws {
        let base = try AgentIntegrationTests.fixture()
        let legacy = try base.decoded(AgentSnapshot.self)
        try expect(legacy.activeToolName == nil && !SessionSummary(snapshot: legacy).isWaiting)
        let transport = FakeAgentTransport(), id = AgentIntegrationTests.conversationID
        let path = AgentAPI.path(id)
        let reader = AgentTranscriptReader(transport: transport, id: id, path: path + "/sync")
        var starts = 0, ends = 0
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)), sleepPrevention: .init(
            begin: { starts += 1; return NSObject() }, end: { _ in ends += 1 }))
        defer { store.closePresentation() }
        try await transport.reply(path, snapshot(base, active: false))
        try store.apply(await reader.read())
        try expect(store.busy && !store.isWaiting && store.messages.count == 2)
        try await transport.reply(path, snapshot(base))
        try store.apply(await reader.read())
        try expect(store.isWaiting && store.summary?.isWaiting == true && store.busy)
        try expect(store.messages.count == 3 && store.messages[2].pendingTool?.call.name == "wait")
        try expect(store.messages[2].status == .streaming && store.tools.pendingApproval == nil)
        let rowID = store.messages[2].id
        try store.apply(await reader.read())
        try expect(store.messages[2].id == rowID && starts == 1 && ends == 0)
        // Cleanup remains active, but is not presented as a sleeping timer.
        try await transport.reply(path, snapshot(base, state: "cancelling"))
        try store.apply(await reader.read())
        try expect(store.busy && !store.isWaiting && ends == 0)
        for outcome in ["completed", "interrupted"] {
            try await transport.reply(path, snapshot(base, state: outcome, active: false, outcome: outcome))
            try store.apply(await reader.read())
            try expect(!store.busy && !store.isWaiting && store.summary?.isWaiting == false)
            try expect(store.messages[2].id == rowID && store.messages[2].pendingTool == nil)
            try expect(store.messages[2].toolResult?.outcome == outcome)
        }
        try expect(ends == 1)
        let requests = await transport.requests
        try expect(requests.allSatisfy { $0.method == "GET" && $0.path.contains("/sync") })
        try expect(requests.dropFirst().allSatisfy { $0.path.contains("?after=") })
    }

    func residentAndCatalogWaitsRequireExistingConfirmation() async throws {
        let fixture = try LifecycleFixture()
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let waiting = try snapshot(fixture.child)
        guard case .object(var catalog) = waiting else { throw CheckFailure(description: "Invalid wait catalog") }
        catalog["messages"] = .array([]) // Catalog summaries do not carry tool calls.
        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, .object(catalog), fixture.other]))
        try await library.refreshSharedState()
        try expect(!library.openConversations.contains { $0.currentSessionID == fixture.childID })
        try expect(library.isSessionWaiting(fixture.childID) && library.isSessionRunning(fixture.childID))
        try expect(library.hasRunningOperations)
        try expect(SessionDeletionConfirmation(for: fixture.parentID, in: library).isRequired)
        let windows = SessionWindows(library: library)
        var prompts: [String] = []
        windows.confirmSessionDeletion = { alert, _ in
            prompts.append(alert.messageText)
            return .alertSecondButtonReturn
        }
        windows.requestSessionDeletion(fixture.childID)
        try await SessionLifecycleTests.wait("wait deletion confirmation") { !windows.isConfirmingDeletion }
        try expect(prompts == ["Delete running session?"] && library.isSessionWaiting(fixture.childID))
        let requests = await fixture.transport.responses.requests
        try expect(!requests.contains { $0.method == "DELETE" || $0.path.hasSuffix("/cancel") })

        try await fixture.transport.responses.reply(AgentAPI.path(fixture.childID), waiting)
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        try expect(library.current.isWaiting && library.current.busy && library.hasRunningOperations)
        try expect(SessionDeletionConfirmation(for: fixture.childID, in: library).isRequired)
        let completed = try snapshot(fixture.child, state: "completed", active: false, outcome: "completed")
        try await fixture.transport.responses.reply(AgentAPI.path(fixture.childID), completed)
        try library.current.apply(completed.decoded(AgentSnapshot.self))
        // The newer resident snapshot wins over a stale waiting catalog entry.
        try expect(!library.isSessionWaiting(fixture.childID) && !library.isSessionRunning(fixture.childID))
        try expect(!library.hasRunningOperations)
        try expect(!SessionDeletionConfirmation(for: fixture.parentID, in: library).isRequired)
    }
}
