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
        var pending: CheckedContinuation<AccountUsage?, Never>?
        var returned = false
        provider.usageAction = {
            let result = await withCheckedContinuation { pending = $0 }
            returned = true
            return result
        }
        library.draft = "Refresh after this turn"
        library.send()
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

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Usage operation did not settle")
    }
}
