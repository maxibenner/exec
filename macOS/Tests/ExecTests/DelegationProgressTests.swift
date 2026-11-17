import Foundation

private extension Optional {
    func unwrap(_ description: String) throws -> Wrapped {
        guard let value = self else { throw CheckFailure(description: description) }
        return value
    }
}

@MainActor struct DelegationProgressTests {
    private let callID = "delegate-progress"

    private func child(_ index: Int) -> AgentJSON {
        let sessionID = String(format: "00000000-0000-4000-8000-%012d", index + 1)
        let outcomes = ["failed", "completed", "interrupted"]
        let answers = ["Parser check failed.", "Tests cover cancellation. 世界", "Cancelled by user."]
        return .object([
            "taskIndex": .number(Double(index)), "sessionId": .string(sessionID),
            "outcome": .string(outcomes[index]),
            "text": .string("Task \(index + 1)\nChild session: \(sessionID)\n\n\(answers[index])")
        ])
    }

    private func fixture(_ indices: [Int]? = nil, outcome: String = "running", active: Bool = true,
                         state: String = "running", storageError: String? = nil) throws -> AgentJSON {
        guard case .object(var snapshot) = try AgentIntegrationTests.fixture(state: state, result: true) else {
            throw CheckFailure(description: "Invalid delegation fixture")
        }
        let call: AgentJSON = .object([
            "id": .string(callID), "name": .string("delegate"),
            "arguments": .object(["tasks": .array(["Parser", "Tests", "Docs"].map {
                .object(["task": .string("Review \($0)"), "title": .string($0)])
            })])
        ])
        var messages = [snapshot["messages"]!.array[0], AgentJSON.object([
            "id": .string(AgentIntegrationTests.assistantID.uuidString), "role": .string("assistant"),
            "text": .string(""), "status": .string("completed"),
            "calls": .array([call, .object(["id": .string("future"), "name": .string("read_file"),
                                            "arguments": .object(["path": .string("README.md")])])])
        ])]
        if let indices {
            let results = indices.map(child)
            messages.append(.object([
                "id": .string(AgentIntegrationTests.toolID.uuidString), "role": .string("tool"),
                "callID": .string(callID), "outcome": .string(outcome),
                "text": .string(results.compactMap { $0["text"].string }.joined(separator: "\n\n")),
                "details": .object(["type": .string("delegation"), "total": .number(3), "results": .array(results)])
            ]))
        }
        snapshot["messages"] = .array(messages)
        snapshot["activeToolCallID"] = active ? .string(callID) : .null
        snapshot["storageError"] = storageError.map(AgentJSON.string) ?? .null
        return .object(snapshot)
    }

    private func card(_ row: Message, state: TranscriptState) throws -> ToolMessageView {
        guard let call = row.toolResult?.call ?? row.pendingTool?.call else {
            throw CheckFailure(description: "Missing delegate card")
        }
        return ToolMessageView(call: call, result: row.toolResult,
                               isAwaitingApproval: row.pendingTool?.isAwaitingApproval == true,
                               isActive: row.status == .streaming, state: state, messageID: row.id)
    }

    func projectsIncrementalResultsInOneActiveCard() throws {
        var pendingIDs: [String: UUID] = [:]
        let state = TranscriptState()
        let entered = try fixture().decoded(AgentSnapshot.self).transcript(images: [:], pendingIDs: &pendingIDs)
        let rowID = try entered.last.unwrap("Missing entered delegate").id
        try expect(entered.count == 3 && entered.last?.pendingTool?.call.id == callID)
        try expect(try card(entered.last!, state: state).isRunning)
        try expect(try !card(entered.last!, state: state).isExpanded)

        // Task 2 finishes first. Later snapshots add earlier/later task indices;
        // even all results present is nonterminal while executor cleanup remains.
        for indices in [[1], [0, 1], [0, 1, 2]] {
            let source = try fixture(indices)
            let snapshot = try source.decoded(AgentSnapshot.self)
            let message = try snapshot.messages.last.unwrap("Missing partial tool message")
            let details = try message.details.unwrap("Missing delegation details")
            try expect(message.id == AgentIntegrationTests.toolID && message.callID == callID)
            try expect(details["type"].string == "delegation" && details["total"].number == 3)
            try expect(details["results"].array == indices.map(child))
            let rows = try snapshot.transcript(images: [:], pendingIDs: &pendingIDs)
            let row = try rows.last.unwrap("Missing partial delegate row")
            try expect(rows.count == 3 && rows.filter { $0.role == .tool }.count == 1)
            try expect(row.id == rowID && row.status == .streaming && row.pendingTool == nil)
            try expect(row.toolResult?.outcome == "running" && row.toolResult?.text == message.text)
            let presentation = ToolPresentation(call: row.toolResult!.call, result: row.toolResult)
            try expect(presentation.inputs.map(\.text) == ["Review Parser", "Review Tests", "Review Docs"])
            try expect(presentation.output == indices.map { child($0)["text"].string! }.joined(separator: "\n\n"))
            try expect(presentation.detail == nil && presentation.isRunning)
            // Partial answers must not open the card without a user choice.
            try expect(try card(row, state: state).isRunning && !card(row, state: state).isExpanded)
        }
        let final = try fixture([0, 1, 2], outcome: "completed", active: false).decoded(AgentSnapshot.self)
        let rows = try final.transcript(images: [:], pendingIDs: &pendingIDs)
        let row = try rows.last.unwrap("Missing final delegate row")
        // The parent model can still be running after the delegate has settled.
        try expect(final.operation?.active == true && rows.count == 3 && row.id == rowID)
        try expect(row.status == .complete && row.toolResult?.outcome == "completed")
        try expect(try !card(row, state: state).isRunning && !card(row, state: state).isExpanded)

        // A user's choice survives incremental results, completion and row remounts.
        for expanded in [true, false] {
            state.expanded[rowID] = expanded
            for source in [try fixture([1]), try fixture([0, 1, 2], outcome: "completed", active: false)] {
                let updated = try source.decoded(AgentSnapshot.self).transcript(images: [:], pendingIDs: &pendingIDs)
                try expect(try card(updated.last!, state: state).isExpanded == expanded)
            }
        }

        // Reopening mid-delegation needs no locally synthesized pending ID.
        var reopenedIDs: [String: UUID] = [:]
        let reopened = try fixture([1]).decoded(AgentSnapshot.self).transcript(images: [:], pendingIDs: &reopenedIDs)
        let reopenedFinal = try final.transcript(images: [:], pendingIDs: &reopenedIDs)
        try expect(reopened.last?.id == AgentIntegrationTests.toolID && reopenedFinal.last?.id == reopened.last?.id)
        let reopenedState = TranscriptState()
        try expect(try !card(reopened.last!, state: reopenedState).isExpanded)
        try expect(try !card(reopenedFinal.last!, state: reopenedState).isExpanded)
    }

    func preservesResultsThroughCleanupFailureAndDisclosureChanges() throws {
        var pendingIDs: [String: UUID] = [:]
        let state = TranscriptState()
        for (operation, outcome, active, storageError) in [
            ("cancelling", "running", true, String?.none),
            ("running", "running", true, "Unable to save child result."),
            ("failed", "failed", false, "Unable to save child result."),
            ("interrupted", "interrupted", false, String?.none)
        ] {
            let snapshot = try fixture([1], outcome: outcome, active: active, state: operation,
                                       storageError: storageError).decoded(AgentSnapshot.self)
            let row = try snapshot.transcript(images: [:], pendingIDs: &pendingIDs).last.unwrap("Missing saved result")
            try expect(row.toolResult?.text == child(1)["text"].string && row.text == row.toolResult?.text)
            try expect((row.status == .streaming) == active && snapshot.storageError == storageError)
            try expect(try card(row, state: state).isRunning == active)
            try expect(try !card(row, state: TranscriptState()).isExpanded)
            for expanded in [false, true] {
                state.expanded[row.id] = expanded
                try expect(try card(row, state: state).isExpanded == expanded)
            }
            // Keep an explicit collapse across the next partial/terminal snapshot.
            state.expanded[row.id] = false
        }
        // Ownership, not result presence, also controls a published result while
        // its executor is still cleaning up.
        let cleanup = try fixture([1], outcome: "failed", active: true, state: "cancelling").decoded(AgentSnapshot.self)
        let row = try cleanup.transcript(images: [:], pendingIDs: &pendingIDs).last.unwrap("Missing cleanup result")
        try expect(try card(row, state: state).isRunning && !card(row, state: state).isExpanded)
    }

    func syncReplacesPartialAndFinalResultsWithoutReplayingWork() async throws {
        let transport = FakeAgentTransport()
        let id = AgentIntegrationTests.conversationID, path = AgentAPI.path(AgentIntegrationTests.conversationID)
        let reader = AgentTranscriptReader(transport: transport, id: id, path: path + "/sync")
        var pendingIDs: [String: UUID] = [:]
        var toolRowID: UUID?
        for source in [try fixture(), try fixture([1]), try fixture([0, 1]),
                       try fixture([0, 1, 2]), try fixture([0, 1, 2], outcome: "completed", active: false)] {
            try await transport.reply(path, source)
            let snapshot = try await reader.read()
            let rows = try snapshot.transcript(images: [:], pendingIDs: &pendingIDs)
            let row = try rows.last.unwrap("Missing synced delegate")
            if toolRowID == nil { toolRowID = row.id }
            try expect(rows.count == 3 && row.id == toolRowID)
            if let outcome = source["messages"].array.last?["outcome"].string {
                try expect(row.toolResult?.outcome == outcome)
                try expect(row.toolResult?.text == source["messages"].array.last?["text"].string)
                try expect(snapshot.messages.last?.details == source["messages"].array.last?["details"])
            }
        }
        let requests = await transport.requests
        try expect(requests.count == 5 && requests.allSatisfy { $0.method == "GET" && $0.path.contains("/sync") })
        try expect(requests.dropFirst().allSatisfy { $0.path.contains("?after=") })
    }
}
