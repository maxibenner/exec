import Foundation

@MainActor struct AccountUsageTests {
    func requestParsingAndFailure() async throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":23.4,"limit_window_seconds":18000,"reset_at":2000000000},"secondary_window":{"used_percent":80,"limit_window_seconds":604800,"reset_at":2000100000}}}"#.utf8)
        let credentials = MemoryCredentials()
        credentials.data = try JSONEncoder().encode(OpenAIAuthentication.Session(
            subject: "test-user", email: "test@example.com", accountID: "workspace",
            access: "test-access", refresh: "test-refresh", expires: Date().addingTimeInterval(3600)
        ))
        let http = HTTPStub.makeSession([.init(chunks: [data]), .init(status: 503)])
        defer { http.invalidateAndCancel() }
        let provider = try OpenAIProvider(authentication: OpenAIAuthentication(keychain: credentials, http: http), http: http)
        let usage = try await provider.accountUsage()
        try expect(usage?.windows.map(\.remainingPercent) == [76, 20])
        try expect(usage?.windows.map(\.durationSeconds) == [18000, 604800])
        let request = HTTPStub.state.requests[0]
        try expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        try expect(request.httpMethod == "GET")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
        try expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "workspace")
        do {
            _ = try await provider.accountUsage()
            throw CheckFailure(description: "Expected usage HTTP failure")
        } catch is OpenAIHTTPError {}
        try expect(HTTPStub.state.requests.count == 2) // No automatic retry.
        try expect(try CodexUsage.decode(Data("{}".utf8)) == nil)
        let invalid = Data(#"{"rate_limit":{"primary_window":{"used_percent":-10,"limit_window_seconds":18000,"reset_at":2000000000}}}"#.utf8)
        try expect(try CodexUsage.decode(invalid) == nil)
    }

    func accountIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let expected = AccountUsage(windows: [.init(durationSeconds: 18000, usedPercent: 25, resetsAt: Date().addingTimeInterval(3600))])
        provider.usageAction = { expected }
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root))
        library.restore()
        try await wait { !library.hasRunningOperations && library.accountUsage == expected }
        try expect(library.providerName == provider.displayName)
        provider.usageAction = { throw ExecError("Usage unavailable") }
        let failedRead = await library.current.readAccountUsage?()
        try expect(failedRead == nil && library.accountUsage == expected && library.account != nil)
        var pending: CheckedContinuation<AccountUsage?, Never>?
        var returned = false
        provider.usageAction = {
            let result = await withCheckedContinuation { pending = $0 }
            returned = true
            return result
        }
        library.restore()
        try await wait { !library.hasRunningOperations && pending != nil }
        library.disconnect()
        try expect(library.accountUsage == nil)
        try await wait { !library.hasRunningOperations && library.account == nil }
        pending?.resume(returning: expected)
        try await wait { returned }
        await Task.yield()
        try expect(library.accountUsage == nil)
        library.stopAll()
    }

    func runObservationsPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true)
        store.selectedModel = "test"
        var reads = 0
        let expected = AccountUsage(windows: [.init(durationSeconds: 604800, usedPercent: 30, resetsAt: Date().addingTimeInterval(1000))])
        store.readAccountUsage = {
            reads += 1
            return reads == 1 ? expected : nil
        }
        var sentBeforeUsageRead = false
        provider.onSend = { sentBeforeUsageRead = reads == 0 }
        var capturedAllowance: [Bool] = []
        store.didFinish = { capturedAllowance.append($0) }
        store.draft = "Measure this run"
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil && reads == 1 && sentBeforeUsageRead)
        let saved = try await sessions.load(id: store.currentSessionID)!
        let observations = saved.allowanceObservations ?? []
        try expect(observations.count == 1 && observations.map(\.phase) == [.after])
        try expect(observations[0].usage == expected)
        try expect(saved.history.last?.role == .assistant && !saved.activeTurn)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        old.removeValue(forKey: "allowanceObservations")
        let legacy = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        try expect(legacy.allowanceObservations == nil)
        provider.holdOpen = true
        store.draft = "Stop this run"
        store.send()
        try await wait { provider.pending != nil }
        store.stop()
        await store.waitUntilIdle()
        let stopped = try await sessions.load(id: store.currentSessionID)!
        let stoppedObservations = stopped.allowanceObservations ?? []
        try expect(reads == 2 && stoppedObservations.count == 2)
        try expect(stoppedObservations.map(\.phase) == [.after, .after])
        try expect(stoppedObservations[1].runID != observations[0].runID)
        // Failed metadata must not fail the run or invent a zero-usage observation.
        try expect(stoppedObservations[1].usage == nil && !stopped.activeTurn && store.error == nil)
        try expect(capturedAllowance == [true, true]) // No fallback refresh after the existing after-check.

        var compactedBeforeUsageRead = false
        provider.manualCompactionAction = { _ in compactedBeforeUsageRead = reads == 2 }
        var pendingUsage: CheckedContinuation<AccountUsage?, Never>?
        store.readAccountUsage = {
            reads += 1
            return await withCheckedContinuation { pendingUsage = $0 }
        }
        store.compact()
        try await wait { pendingUsage != nil }
        // A slow usage request cannot delay compaction or its transcript component.
        let completedBeforeUsage = store.messages.last?.compaction == .manual && store.messages.last?.status == .complete
        pendingUsage?.resume(returning: expected)
        await store.waitUntilIdle()
        try expect(compactedBeforeUsageRead && completedBeforeUsage && reads == 3)
        let compacted = try await sessions.load(id: store.currentSessionID)!
        try expect(compacted.allowanceObservations?.count == 3 && compacted.allowanceObservations?.last?.phase == .after)

        provider.manualCompactionAction = { _ in throw ExecError("Compaction unavailable") }
        store.readAccountUsage = { reads += 1; return nil }
        store.compact()
        await store.waitUntilIdle()
        let failed = try await sessions.load(id: store.currentSessionID)!
        try expect(reads == 4 && failed.allowanceObservations?.count == 4)
        try expect(failed.allowanceObservations?.last?.phase == .after && failed.allowanceObservations?.last?.usage == nil)
        try expect(store.error == "Compaction unavailable" && capturedAllowance == [true, true, true, true])
    }

    func responseUsageValidation() throws {
        let missing = CodexResponseUsage(response: [:])
        try expect(missing.contextTokens == nil && missing.cachedInputTokens == nil)
        let malformed = CodexResponseUsage(response: ["usage": [
            "input_tokens": true, "output_tokens": -1,
            "input_tokens_details": ["cached_tokens": 1.5]]])
        try expect(malformed.inputTokens == nil && malformed.outputTokens == nil && malformed.cachedInputTokens == nil)
        let invalidSubset = CodexResponseUsage(response: ["usage": [
            "input_tokens": 10, "output_tokens": 5,
            "input_tokens_details": ["cached_tokens": 20], "output_tokens_details": ["reasoning_tokens": 8]]])
        try expect(invalidSubset.contextTokens == 15 && invalidSubset.cachedInputTokens == nil && invalidSubset.reasoningTokens == nil)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Usage operation did not settle")
    }
}
