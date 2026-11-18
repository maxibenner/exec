import Foundation
import CryptoKit

/// Isolated equivalent of the host's cursor/page contract, including prefix resets.
enum AgentSyncFixture {
    static func page(_ snapshot: AgentJSON, path: String) throws -> AgentJSON {
        guard case .object(var value) = snapshot else { throw CheckFailure(description: "Missing sync fixture snapshot") }
        let messages = snapshot["messages"].array, total = messages.count
        let query = URLComponents(string: "http://fixture\(path)")?.queryItems ?? []
        let before = query.first { $0.name == "before" }?.value
        let after = query.first { $0.name == "after" }?.value
        let proof = query.first { $0.name == "prefix" }?.value
        var offset = max(0, total - 64), end = total, reset = true
        if let before, let index = messages.firstIndex(where: { $0["id"].string == before }) {
            offset = max(0, index - 64); end = index; reset = false
        } else if let after, let index = messages.firstIndex(where: { $0["id"].string == after }),
                  total - index <= 64, try prefix(Array(messages[..<index])) == proof {
            offset = index; reset = false
        }
        value["messages"] = .array(Array(messages[offset..<end]))
        return .object(["snapshot": .object(value), "offset": .number(Double(offset)), "total": .number(Double(total)),
                        "reset": .bool(reset), "prefix": try total == 0 ? .null : .string(prefix(Array(messages.dropLast())))])
    }
    private static func prefix(_ messages: [AgentJSON]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(messages)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor struct AgentTranscriptSyncTests {
    private func fixture(count: Int, textSize: Int = 1) throws -> AgentJSON {
        guard case .object(var snapshot) = try AgentIntegrationTests.fixture(state: "completed", result: true) else {
            throw CheckFailure(description: "Invalid test fixture")
        }
        snapshot["messages"] = .array((0..<count).map { index in
            .object(["id": .string(String(format: "00000000-0000-4000-8000-%012d", index)),
                     "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                     "text": .string(String(repeating: "x", count: textSize)), "status": .string("completed")])
        })
        return .object(snapshot)
    }

    func typedStatePreservesProofAndRejectsInvalidPages() throws {
        let path = AgentAPI.path(AgentIntegrationTests.conversationID, "/sync")
        let original = try fixture(count: 130)
        func page(_ snapshot: AgentJSON, _ request: String) throws -> AgentSyncPage {
            try JSONDecoder().decode(AgentSyncPage.self, from: JSONEncoder().encode(AgentSyncFixture.page(snapshot, path: request)))
        }
        let tail = try page(original, path)
        var state = try AgentTranscriptState.initial(tail)
        let proof = state.prefix
        guard case .object(var changed) = original, case .object(var last) = original["messages"].array.last! else {
            throw CheckFailure(description: "Invalid typed fixture")
        }
        last["text"] = .string("changed while backfilling")
        changed["messages"] = .array(Array(original["messages"].array.dropLast()) + [.object(last), .object([
            "id": .string(UUID().uuidString.lowercased()), "role": .string("user"), "text": .string("new tail")])])
        let newer = AgentJSON.object(changed)
        while let earlier = state.earlierPath(path) {
            let older = try page(newer, earlier)
            try expect(older.total == 131 && older.prefix != proof)
            state = try state.prepending(older)
        }
        try expect(state.snapshot.messages.count == 130 && state.total == 130 && state.prefix == proof)
        try expect(state.refreshPath(path).hasSuffix("prefix=\(proof!)"))
        let update = try state.refreshed(page(newer, state.refreshPath(path)))
        try expect(update.changed && update.0.snapshot.messages.count == 131)
        let unchanged = try update.0.refreshed(page(newer, update.0.refreshPath(path)))
        try expect(!unchanged.changed)
        let wrongOffset = AgentSyncPage(snapshot: tail.snapshot, offset: -1, total: tail.total, reset: true, prefix: proof)
        try expectFailure { _ = try AgentTranscriptState.initial(wrongOffset) }
        try expectFailure { _ = try state.prepending(tail) } // A reset cannot be an older page.
        let wrongOverlap = AgentSyncPage(snapshot: tail.snapshot, offset: 0, total: 64, reset: false, prefix: proof)
        try expectFailure { _ = try state.refreshed(wrongOverlap) }
        // Structural regression guard: the reader's only wire decoding is a typed
        // bounded page. In particular no historical snapshot can be re-encoded.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Exec/Backend/AgentTranscriptReader.swift"), encoding: .utf8)
        try expect(!source.contains("JSONEncoder(") && !source.contains("decode(AgentJSON.self") && !source.contains(".decoded(AgentSnapshot.self)"))
    }

    func pagesHistoryAndMergesOnlyTheChangedSuffix() async throws {
        let transport = FakeAgentTransport(), id = AgentIntegrationTests.conversationID
        let path = AgentAPI.path(id)
        let original = try fixture(count: 130, textSize: 10_000)
        try await transport.reply(path, original)
        let reader = AgentTranscriptReader(transport: transport, id: id, path: path + "/sync")
        let first = try await reader.read()
        try expect(first.messages.count == 130)
        let initial = await transport.requests
        try expect(initial.count == 3 && initial[0].path == path + "/sync")
        try expect(initial.dropFirst().allSatisfy { $0.path.contains("?before=") })
        guard case .object(var changed) = original, case .object(var last) = original["messages"].array.last! else {
            throw CheckFailure(description: "Invalid history fixture")
        }
        last["text"] = .string("Updated 世界 👋")
        var messages = original["messages"].array
        messages[messages.count - 1] = .object(last)
        messages.append(.object(["id": .string(UUID().uuidString.lowercased()), "role": .string("user"), "text": .string("Next")]))
        changed["messages"] = .array(messages)
        try await transport.reply(path, .object(changed))
        let second = try await reader.read()
        try expect(second.messages.count == 131 && second.messages[129].text == "Updated 世界 👋")
        try expect(second.messages.first?.id == first.messages.first?.id)
        let requests = await transport.requests
        try expect(requests.count == 4 && requests.last!.path.contains("?after="))
        let delta = try AgentSyncFixture.page(.object(changed), path: requests.last!.path)
        try expect(delta["snapshot"]["messages"].array.count == 2)
        try expect(requests.allSatisfy { $0.method == "GET" && $0.path.contains("/sync") })
    }

    func backfillsToolCallsBeforePublishingResults() async throws {
        let transport = FakeAgentTransport(), id = AgentIntegrationTests.conversationID
        guard case .object(var snapshot) = try fixture(count: 2),
              case .object(var assistant) = snapshot["messages"]!.array[1] else {
            throw CheckFailure(description: "Invalid tool fixture")
        }
        let calls: [AgentJSON] = (0..<64).map { index in
            .object(["id": .string("call-\(index)"), "name": .string("read_file"), "arguments": .object(["path": .string("test.txt")])])
        }
        assistant["calls"] = .array(calls)
        let results: [AgentJSON] = (0..<64).map { index in
            .object(["id": .string(UUID().uuidString.lowercased()), "role": .string("tool"), "callID": .string("call-\(index)"),
                     "text": .string("result"), "outcome": .string("completed")])
        }
        snapshot["messages"] = .array([snapshot["messages"]!.array[0], .object(assistant)] + results)
        try await transport.reply(AgentAPI.path(id), .object(snapshot))
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try await store.loadSession(id)
        try expect(store.messages.count == 66 && store.messages.filter { $0.toolResult != nil }.count == 64)
        let requests = await transport.requests
        try expect(requests.count == 2 && requests.last!.path.contains("?before="))
    }

    func resetsChangedHistoryAndRejectsWrongConversations() async throws {
        let transport = FakeAgentTransport(), id = AgentIntegrationTests.conversationID
        let path = AgentAPI.path(id)
        try await transport.reply(path, fixture(count: 70))
        let reader = AgentTranscriptReader(transport: transport, id: id, path: path + "/sync")
        _ = try await reader.read()
        // Compaction or an earlier edit invalidates the prefix and replaces history.
        try await transport.reply(path, fixture(count: 4))
        let reset = try await reader.read()
        try expect(reset.messages.count == 4)
        guard case .object(var wrong) = try fixture(count: 4) else {
            throw CheckFailure(description: "Invalid conversation fixture")
        }
        wrong["id"] = .string(UUID().uuidString.lowercased())
        try await transport.reply(path, .object(wrong))
        var rejected = false
        do { _ = try await reader.read() }
        catch { rejected = true }
        try expect(rejected)
        try await transport.reply(path, fixture(count: 4))
        let recovered = try await reader.read()
        try expect(recovered.id == id && recovered.messages.count == 4)
    }
}
