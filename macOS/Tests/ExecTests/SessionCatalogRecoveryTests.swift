import Foundation

private actor CatalogRecoveryTransport: AgentTransport {
    enum Failure { case validation, ambiguous }
    private var configuration = AgentLibraryConfiguration()
    private var failure: Failure?
    private var holdWrite = false
    private var release: CheckedContinuation<Void, Never>?
    private var failRead = false
    private(set) var patches: [AgentJSON] = []
    private(set) var reads = 0
    var waiting: Bool { release != nil }
    func failNextWrite(_ failure: Failure, held: Bool = false) { self.failure = failure; holdWrite = held }
    func finish() { release?.resume(); release = nil }
    func setReadFailure(_ value: Bool) { failRead = value }
    func setRemotePrompt(_ prompt: String) { configuration.settings.systemPrompt = prompt }

    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        guard path == "/v1/library" else { throw CheckFailure(description: "Unexpected catalog route") }
        if method == "GET" {
            reads += 1
            if failRead { throw ExecError("Synthetic catalog read failure") }
            return try JSONEncoder().encode(configuration)
        }
        guard method == "PATCH", let body else { throw CheckFailure(description: "Expected a library patch") }
        let patch = try JSONDecoder().decode(AgentJSON.self, from: body)
        patches.append(patch)
        let failure = self.failure
        self.failure = nil
        if holdWrite {
            holdWrite = false
            await withCheckedContinuation { release = $0 }
        }
        if failure == .validation { throw AgentHTTPError(status: 400, message: "Invalid default model") }
        guard case .object(var fields) = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(configuration)),
              case .object(let replacements) = patch else { throw CheckFailure(description: "Invalid library fixture") }
        for (key, replacement) in replacements {
            if key == "settings", case .object(var settings) = fields[key], case .object(let changes) = replacement {
                for (name, value) in changes { settings[name] = value }
                fields[key] = .object(settings)
            } else { fields[key] = replacement }
        }
        configuration = try AgentJSON.object(fields).decoded(AgentLibraryConfiguration.self)
        if failure == .ambiguous { throw ExecError("Library acknowledgement lost after commit") }
        return try JSONEncoder().encode(configuration)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor struct SessionCatalogRecoveryTests {
    func rejectedWritesDoNotPoisonQueuedOrFutureExplicitChanges() async throws {
        let suite = "exec-catalog-rejection-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = CatalogRecoveryTransport()
        let catalog = SessionCatalog(api: AgentAPI(transport: transport), preferences: preferences)
        await transport.failNextWrite(.validation, held: true)
        let invalid = Task { try await catalog.update { $0.defaultModel = "invalid" } }
        try await SessionLifecycleTests.wait("rejected catalog write") { await transport.waiting }
        let corrected = Task { try await catalog.update { $0.defaultModel = "deepseek/test" } }
        await Task.yield()
        await transport.finish()
        var rejected = false
        do { try await invalid.value }
        catch { rejected = true; try expect((error as? AgentHTTPError)?.status == 400) }
        try expect(rejected)
        try await corrected.value
        try expect(catalog.configuration.defaultModel == "deepseek/test")
        try await catalog.update { $0.automaticTitles = false }
        let patches = await transport.patches
        let reads = await transport.reads
        try expect(patches.count == 3 && reads == 0)
        try expect(patches[0]["defaultModel"].string == "invalid")
        try expect(patches[1]["defaultModel"].string == "deepseek/test")
        try expect(patches[2] == .object(["automaticTitles": .bool(false)]))
        try expect(!catalog.configuration.automaticTitles)
    }

    func ambiguousWritesRequireAuthoritativeReadWithoutReplayingChanges() async throws {
        let suite = "exec-catalog-uncertain-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = CatalogRecoveryTransport()
        let catalog = SessionCatalog(api: AgentAPI(transport: transport), preferences: preferences)
        await transport.failNextWrite(.ambiguous, held: true)
        let uncertain = Task { try await catalog.update { $0.defaultModel = "deepseek/test" } }
        try await SessionLifecycleTests.wait("ambiguous catalog write") { await transport.waiting }
        let queued = Task { try await catalog.update { $0.automaticTitles = false } }
        await Task.yield()
        await transport.finish()
        for request in [uncertain, queued] {
            var failed = false
            do { try await request.value } catch { failed = true }
            try expect(failed)
        }
        try expect(catalog.configuration.defaultModel == nil && catalog.configuration.automaticTitles)
        await transport.setReadFailure(true)
        var readFailed = false
        do { try await catalog.restore() } catch { readFailed = true }
        try expect(readFailed)
        var stillBlocked = false
        do { try await catalog.update { $0.defaultModel = "corrected" } } catch { stillBlocked = true }
        try expect(stillBlocked)
        let beforeRecovery = await transport.patches
        try expect(beforeRecovery.count == 1)
        await transport.setReadFailure(false)
        await transport.setRemotePrompt("Another device's prompt")
        try await catalog.restore()
        try expect(catalog.configuration.defaultModel == "deepseek/test" && catalog.configuration.automaticTitles)
        try expect(catalog.configuration.settings.systemPrompt == "Another device's prompt")
        let recovered = await transport.patches
        try expect(recovered.count == 1) // Recovery never replays the uncertain or queued change.
        try await catalog.update { $0.automaticTitles = false }
        let final = await transport.patches
        try expect(final.count == 2 && final[1] == .object(["automaticTitles": .bool(false)]))
        try expect(catalog.configuration.defaultModel == "deepseek/test" && !catalog.configuration.automaticTitles)
        try expect(catalog.configuration.settings.systemPrompt == "Another device's prompt")
    }
}
