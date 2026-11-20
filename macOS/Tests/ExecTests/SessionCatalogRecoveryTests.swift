import Foundation

private actor CatalogRecoveryTransport: AgentTransport {
    enum Failure { case validation, ambiguous, unsettled }
    nonisolated let notifications = NotificationTestTransport(notice: .init(epoch: "catalog-recovery", catalog: "1", conversations: [:]))
    private var configuration = AgentLibraryConfiguration()
    private var pendingConfiguration: AgentLibraryConfiguration?
    private var failure: Failure?
    private var holdWrite = false
    private var release: CheckedContinuation<Void, Never>?
    private var holdRead = false
    private var releaseRead: CheckedContinuation<Void, Never>?
    private var failRead = false
    private(set) var patches: [AgentJSON] = []
    private(set) var reads = 0
    var waiting: Bool { release != nil }
    var readWaiting: Bool { releaseRead != nil }
    func failNextWrite(_ failure: Failure, held: Bool = false) { self.failure = failure; holdWrite = held }
    func holdNextWrite() { holdWrite = true }
    func finish() { release?.resume(); release = nil }
    func holdNextRead() { holdRead = true }
    func finishRead() { releaseRead?.resume(); releaseRead = nil }
    func finishPendingWrite() {
        if let pendingConfiguration { configuration = pendingConfiguration }
        pendingConfiguration = nil
    }
    func setReadFailure(_ value: Bool) { failRead = value }
    func setRemotePrompt(_ prompt: String) { configuration.settings.systemPrompt = prompt }

    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        guard path == "/v1/library" else { return try await notifications.request(method, path, body: body) }
        if method == "GET" {
            reads += 1
            if failRead { throw ExecError("Synthetic catalog read failure") }
            if pendingConfiguration != nil { throw AgentHTTPError(status: 409, message: "Library write is still pending") }
            let data = try JSONEncoder().encode(configuration)
            if holdRead {
                holdRead = false
                await withCheckedContinuation { releaseRead = $0 }
            }
            return data
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
        let value = try AgentJSON.object(fields).decoded(AgentLibraryConfiguration.self)
        if failure == .unsettled {
            pendingConfiguration = value
            throw ExecError("Library acknowledgement lost before settlement")
        }
        configuration = value
        if failure == .ambiguous { throw ExecError("Library acknowledgement lost after commit") }
        return try JSONEncoder().encode(configuration)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        notifications.events(method, path, body: body)
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
        let applied = try await catalog.restore()
        try expect(applied)
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

@MainActor struct ChatLibraryCatalogRecoveryTests {
    func rejectionSavesOnlyNewerExplicitCorrection() async throws {
        for corrected in [false, true] {
            let suite = "exec-library-rejection-\(UUID())", preferences = UserDefaults(suiteName: suite)!
            let transport = CatalogRecoveryTransport(), api = AgentAPI(transport: transport)
            let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences)
            defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
            try await transport.notifications.responses.reply("/v1/conversations", .array([]))
            await transport.failNextWrite(.validation, held: true)
            library.defaultModel = "invalid"
            try await SessionLifecycleTests.wait("held library defaults rejection") { await transport.waiting }
            if corrected {
                library.defaultModel = "deepseek/test"
                library.automaticTitles = false
            }
            await transport.finish()
            try await SessionLifecycleTests.wait("library defaults settlement") { !library.hasRunningOperations }
            let patches = await transport.patches, reads = await transport.reads
            try expect(patches.count == (corrected ? 2 : 1) && reads == 0)
            try expect(patches[0] == .object(["defaultModel": .string("invalid")]))
            if corrected {
                try expect(patches[1] == .object(["defaultModel": .string("deepseek/test"), "automaticTitles": .bool(false)]))
                try expect(library.defaultModel == "deepseek/test" && !library.automaticTitles)
            }
            try await library.refreshSharedState()
            try expect(library.defaultModel == (corrected ? "deepseek/test" : ""))
            try expect(library.automaticTitles == !corrected)
            let final = await transport.patches
            try expect(final.count == patches.count) // A rejected revision is never replayed by recovery.
            await api.changes.close()
        }
    }

    func skippedRestoreKeepsCatchupPending() async throws {
        for supersededRead in [false, true] {
            let suite = "exec-library-skipped-\(UUID())", preferences = UserDefaults(suiteName: suite)!
            let transport = CatalogRecoveryTransport(), clock = NotificationTestClock()
            let api = AgentAPI(transport: transport)
            let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences,
                                      synchronizationSleep: { try await clock.sleep($0) })
            defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
            let snapshot = try AgentIntegrationTests.fixture(state: "completed", result: true)
            try library.current.apply(snapshot.decoded(AgentSnapshot.self))
            try await transport.notifications.responses.reply("/v1/conversations", .array([snapshot]))
            if supersededRead {
                await transport.holdNextRead()
                library.startSynchronization()
                try await SessionLifecycleTests.wait("library read before registration") { await transport.readWaiting }
            }
            // Registration writes catalog ordering without a defaults task or navigation
            // guard, exercising SessionCatalog's own held-write/superseded-read result.
            await transport.holdNextWrite()
            let registration = Task { try await library.current.didCheckpoint?() }
            try await SessionLifecycleTests.wait("held catalog registration") { await transport.waiting }
            if supersededRead { await transport.finishRead() }
            else { library.startSynchronization() }
            try await SessionLifecycleTests.wait("pending skipped catchup") { await clock.delays.count == 1 }
            let delays = await clock.delays, reads = await transport.reads
            let requests = await transport.notifications.responses.requests
            try expect(delays == [.milliseconds(100)] && reads == (supersededRead ? 1 : 0))
            try expect(requests.isEmpty && library.systemPrompt.isEmpty)
            await transport.finish()
            _ = try await registration.value
            await transport.setRemotePrompt("Settled shared prompt")
            await clock.advance() // No new notification: the skipped invalidation must survive.
            try await SessionLifecycleTests.wait("catchup after catalog registration") { library.systemPrompt == "Settled shared prompt" }
            let finalReads = await transport.reads, patches = await transport.patches
            try expect(finalReads == (supersededRead ? 2 : 1) && patches.count == 1)
            try expect(library.connectionError == nil)
            library.closePresentations()
            await api.changes.close()
        }
    }

    func unsettledWriteRequiresSettledReadWithoutReplay() async throws {
        let suite = "exec-library-unsettled-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let transport = CatalogRecoveryTransport(), clock = NotificationTestClock()
        let api = AgentAPI(transport: transport)
        let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences,
                                  synchronizationSleep: { try await clock.sleep($0) })
        defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
        try await transport.notifications.responses.reply("/v1/conversations", .array([]))
        await transport.failNextWrite(.unsettled, held: true)
        library.defaultModel = "deepseek/test"
        try await SessionLifecycleTests.wait("held uncertain library save") { await transport.waiting }
        library.defaultModel = "explicit-correction"
        library.automaticTitles = false
        await transport.finish()
        try await SessionLifecycleTests.wait("uncertain library save failure") { !library.hasRunningOperations }
        let uncertain = await transport.patches
        try expect(uncertain.count == 1)
        library.startSynchronization()
        try await SessionLifecycleTests.wait("Busy library read") { await clock.delays.count == 1 }
        try expect(library.defaultModel == "explicit-correction" && !library.automaticTitles)
        try expect(library.connectionError == nil)
        // Busy is not an authoritative read and cannot unblock even a new explicit save.
        library.defaultAutoApproveTools = false
        try await SessionLifecycleTests.wait("blocked library edit after Busy") { !library.hasRunningOperations }
        let blocked = await transport.patches
        try expect(blocked.count == 1)
        await clock.advance()
        try await SessionLifecycleTests.wait("second Busy library read") { await clock.delays.count == 2 }
        let busyReads = await transport.reads, delays = await clock.delays
        let beforeSettlement = await transport.notifications.responses.requests
        try expect(busyReads == 2 && delays == [.milliseconds(100), .milliseconds(100)])
        try expect(beforeSettlement.isEmpty)
        await transport.finishPendingWrite()
        await transport.setRemotePrompt("Another device's settled prompt")
        await clock.advance()
        try await SessionLifecycleTests.wait("settled library recovery") { library.systemPrompt == "Another device's settled prompt" }
        for _ in 0..<200 { await Task.yield() }
        try expect(library.defaultModel == "deepseek/test" && library.automaticTitles && library.defaultAutoApproveTools)
        let recovered = await transport.patches, reads = await transport.reads
        try expect(recovered.count == 1 && reads == 3) // Never replay the uncertain or intervening edits.
        try expect(library.connectionError == nil)
        library.automaticTitles = false // Only a fresh edit after settled recovery can write again.
        try await SessionLifecycleTests.wait("explicit library edit after recovery") { !library.hasRunningOperations }
        let final = await transport.patches
        try expect(final.count == 2 && final[1] == .object(["automaticTitles": .bool(false)]))
        try await library.refreshSharedState()
        try expect(library.systemPrompt == "Another device's settled prompt" && library.defaultModel == "deepseek/test")
        try expect(!library.automaticTitles && library.defaultAutoApproveTools)
        library.closePresentations()
        await api.changes.close()
    }
}
