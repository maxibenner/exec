import Foundation
#if canImport(ExecRemote)
import ExecRemote
#endif

/// No network, wall-clock sleeps, credentials, or mutation retries. A frozen
/// clock makes any accidental idle polling observable without waiting two seconds.
actor NotificationTestClock {
    private(set) var delays: [Duration] = []
    private var pending: [(UUID, CheckedContinuation<Void, Error>)] = []
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        delays.append(duration)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { pending.append((id, $0)) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        pending.remove(at: index).1.resume(throwing: CancellationError())
    }
    func advance() { if !pending.isEmpty { pending.removeFirst().1.resume() } }
}

actor NotificationTestTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private var connections: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private(set) var subscriptions = 0
    private(set) var terminations = 0
    private var notice: RemoteChangeNotification?
    private var failure: AgentHTTPError?
    private var heldPath: String?
    private var heldRead: CheckedContinuation<Void, Never>?
    private var readFailures: [String: Int] = [:]
    var isHolding: Bool { heldRead != nil }
    var connectionCount: Int { connections.count }
    init(notice: RemoteChangeNotification? = nil, status: Int? = nil) {
        self.notice = notice
        failure = status.map { AgentHTTPError(status: $0, message: "Synthetic HTTP failure") }
    }
    func hold(_ path: String) { heldPath = path }
    func release() { heldRead?.resume(); heldRead = nil }
    func failReads(_ path: String, count: Int) { readFailures[path] = count }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let data = try await responses.request(method, path, body: body)
        let route = String(path.split(separator: "?", maxSplits: 1)[0])
        if readFailures[route, default: 0] > 0 {
            readFailures[route, default: 0] -= 1
            throw ExecError("Synthetic read failure")
        }
        if let heldPath, path.hasPrefix(heldPath) {
            self.heldPath = nil
            await withCheckedContinuation { heldRead = $0 }
        }
        return data
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let registration = Task { await self.connect(id, method, path, continuation) }
        continuation.onTermination = { _ in
            Task { await registration.value; await self.remove(id) }
        }
        return stream
    }
    private func connect(_ id: UUID, _ method: String, _ path: String,
                         _ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        guard method == "GET", path == "/v1/changes" else {
            continuation.finish(throwing: ExecError("Unexpected notification mutation")); return
        }
        subscriptions += 1
        connections[id] = continuation
        if let failure { continuation.finish(throwing: failure) }
        else if let notice { continuation.yield(try! JSONEncoder().encode(notice)) }
    }
    private func remove(_ id: UUID) {
        if connections.removeValue(forKey: id) != nil { terminations += 1 }
    }
    func emit(_ notice: RemoteChangeNotification) throws {
        self.notice = notice
        let data = try JSONEncoder().encode(notice)
        for continuation in connections.values { continuation.yield(data) }
    }
    func heartbeat() { for continuation in connections.values { continuation.yield(Data("\n".utf8)) } }
    func disconnect() {
        for continuation in connections.values { continuation.finish(throwing: ExecError("Synthetic disconnect")) }
    }
}

@MainActor struct ChangeNotificationTests {
    private let id = AgentIntegrationTests.conversationID
    private let other = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private func notice(_ revision: String = "1", catalog: String = "1", epoch: String = "epoch",
                        other: String = "1") -> RemoteChangeNotification {
        .init(epoch: epoch, catalog: catalog, conversations: [id.uuidString.lowercased(): revision,
                                                           self.other.uuidString.lowercased(): other])
    }
    private func snapshot(_ id: UUID, text: String = "initial", active: Bool = false) throws -> AgentJSON {
        guard case .object(var value) = try AgentIntegrationTests.fixture(state: active ? "running" : "completed", result: true) else {
            throw CheckFailure(description: "Missing fixture")
        }
        value["id"] = .string(id.uuidString.lowercased())
        value["messages"] = .array([.object(["id": .string(AgentIntegrationTests.userID.uuidString.lowercased()),
                                             "role": .string("user"), "text": .string(text)])])
        return .object(value)
    }
    private func prepare(_ transport: NotificationTestTransport) async throws {
        try await transport.responses.reply(AgentAPI.path(id), snapshot(id))
        try await transport.responses.reply(AgentAPI.path(other), snapshot(other))
        try await transport.responses.reply("/v1/library", JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration())))
        try await transport.responses.reply("/v1/conversations", .array([]))
    }
    private func settle() async { for _ in 0..<200 { await Task.yield() } }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<10_000 { if await condition() { return }; await Task.yield() }
        throw CheckFailure(description: "Notification test did not reach its barrier")
    }
    private func count(_ transport: NotificationTestTransport, _ path: String) async -> Int {
        await transport.responses.requests.filter { $0.path.hasPrefix(path) }.count
    }

    func sharedIdleAndRevisionSpecificCatchup() async throws {
        let transport = NotificationTestTransport(notice: notice()), clock = NotificationTestClock()
        try await prepare(transport)
        let api = AgentAPI(transport: transport)
        let first = AgentTranscriptReader(transport: transport, id: id, path: AgentAPI.path(id, "/sync"), changes: api.changes,
                                          sleep: { try await clock.sleep($0) })
        let second = AgentTranscriptReader(transport: transport, id: other, path: AgentAPI.path(other, "/sync"), changes: api.changes,
                                           sleep: { try await clock.sleep($0) })
        _ = try await first.read(); _ = try await second.read()
        let suite = "notification-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences,
                                  synchronizationSleep: { try await clock.sleep($0) })
        defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
        library.startSynchronization()
        var firstResults = 0, secondResults = 0
        let a = Task { while !Task.isCancelled { _ = try await first.next(); firstResults += 1 } }
        let b = Task { while !Task.isCancelled { _ = try await second.next(); secondResults += 1 } }
        defer { a.cancel(); b.cancel() }
        try await wait { await count(transport, "/v1/conversations") == 3 }
        await settle()
        let initial = await transport.responses.requests.count
        try await transport.emit(notice()); await transport.heartbeat(); await settle()
        let idle = await transport.responses.requests.count, sleeps = await clock.delays
        try expect(initial == idle && sleeps.isEmpty)
        let subscriptions = await transport.subscriptions
        try expect(subscriptions == 1)

        try await transport.responses.reply(AgentAPI.path(id), snapshot(id, text: "changed"))
        try await transport.emit(notice("18446744073709551615"))
        try await wait { firstResults == 1 }
        try expect(secondResults == 0)
        let secondReads = await count(transport, AgentAPI.path(other))
        let catalogReads = await count(transport, "/v1/library")
        try expect(secondReads == 1 && catalogReads == 1)
        // An invalidation whose canonical snapshot is unchanged must not publish.
        try await transport.emit(notice("9007199254740993"))
        try await wait { await count(transport, AgentAPI.path(id)) == 3 }
        await settle(); try expect(firstResults == 1)
        try await transport.emit(notice("9007199254740993", catalog: "2"))
        try await wait { await count(transport, "/v1/library") == 2 }
        await settle()
        let firstReads = await count(transport, AgentAPI.path(id))
        try expect(firstReads == 3)
        library.closePresentations()
        try await transport.responses.reply(AgentAPI.path(other), snapshot(other, text: "reader survives library close"))
        try await transport.emit(notice("9007199254740993", catalog: "2", other: "2"))
        try await wait { secondResults == 1 }
        a.cancel(); b.cancel(); _ = await a.result; _ = await b.result
        await first.close(); await second.close()
        try await wait { await transport.connectionCount == 0 }
        let requests = await transport.responses.requests
        try expect(requests.allSatisfy { $0.method == "GET" })
    }

    func subscribeBeforeReadAndChangesDuringRead() async throws {
        let transport = NotificationTestTransport()
        try await prepare(transport)
        let broker = AgentChangeBroker(transport: transport)
        let reader = AgentTranscriptReader(transport: transport, id: id, path: AgentAPI.path(id, "/sync"), changes: broker)
        let read = Task { try await reader.read() }
        try await wait { await transport.subscriptions == 1 }
        let before = await transport.responses.requests.count
        try expect(before == 0)
        await transport.hold(AgentAPI.path(id, "/sync"))
        try await transport.emit(notice())
        try await wait { await transport.isHolding }
        try await transport.responses.reply(AgentAPI.path(id), snapshot(id, text: "arrived during read"))
        try await transport.emit(notice("2"))
        await settle(); await transport.release()
        let initial = try await read.value
        try expect(initial.messages[0].text == "initial")
        let changed = try await reader.next()
        try expect(changed.messages[0].text == "arrived during read")
        let reads = await count(transport, AgentAPI.path(id))
        try expect(reads == 2)
        await reader.close(); await broker.close()
    }

    func reconnectCatchupAndBoundedBackoff() async throws {
        let transport = NotificationTestTransport(notice: notice()), clock = NotificationTestClock()
        try await prepare(transport)
        let broker = AgentChangeBroker(transport: transport, sleep: { try await clock.sleep($0) })
        let reader = AgentTranscriptReader(transport: transport, id: id, path: AgentAPI.path(id, "/sync"), changes: broker)
        _ = try await reader.read()
        var texts: [String] = []
        let observing = Task { while !Task.isCancelled { texts.append(try await reader.next().messages[0].text) } }
        defer { observing.cancel() }
        await transport.disconnect()
        try await wait { await clock.delays.count == 1 }
        try await wait { await count(transport, AgentAPI.path(id)) == 2 }
        // No revision change: reconnect initial is still an authoritative catchup.
        try await transport.responses.reply(AgentAPI.path(id), snapshot(id, text: "offline update"))
        await clock.advance()
        try await wait { texts == ["offline update"] }
        for attempt in 2...8 {
            await transport.disconnect()
            try await wait { await clock.delays.count == attempt }
            await clock.advance()
            try await wait { await transport.subscriptions == attempt + 1 }
        }
        let delays = await clock.delays
        try expect(delays == [250, 500, 1000, 2000, 4000, 8000, 8000, 8000].map { .milliseconds($0) })
        observing.cancel(); _ = await observing.result
        await reader.close(); await broker.close()
        let requests = await transport.responses.requests
        try expect(requests.allSatisfy { $0.method == "GET" })
    }

    func explicitUnsupportedOnlyAndLegacyCadence() async throws {
        for status in [404, 405] {
            for active in [false, true] {
                let transport = NotificationTestTransport(status: status), clock = NotificationTestClock()
                try await prepare(transport)
                try await transport.responses.reply(AgentAPI.path(id), snapshot(id, active: active))
                let broker = AgentChangeBroker(transport: transport)
                let reader = AgentTranscriptReader(transport: transport, id: id, path: AgentAPI.path(id, "/sync"), changes: broker,
                                                   sleep: { try await clock.sleep($0) })
                _ = try await reader.read()
                let next = Task { try await reader.next() }
                try await wait { await clock.delays.count == 1 }
                let delays = await clock.delays
                try expect(delays == [active ? .milliseconds(200) : .seconds(2)])
                try await transport.responses.reply(AgentAPI.path(id), snapshot(id, text: "legacy update", active: active))
                await clock.advance()
                let updated = try await next.value
                try expect(updated.messages[0].text == "legacy update")
                await reader.close(); await broker.close()
            }
        }
        for status in [401, 500] {
            let transport = NotificationTestTransport(status: status), clock = NotificationTestClock()
            let broker = AgentChangeBroker(transport: transport, sleep: { try await clock.sleep($0) })
            let subscription = await broker.subscribe(.catalog)
            var iterator = subscription.stream.makeAsyncIterator()
            guard case .catchUp = await iterator.next() else { throw CheckFailure(description: "Generic errors enabled polling") }
            try await wait { await clock.delays.count == 1 }
            await clock.advance()
            try await wait { await transport.subscriptions == 2 }
            guard case .catchUp = await iterator.next() else { throw CheckFailure(description: "Reconnect enabled polling") }
            subscription.close(); await broker.close()
        }
    }

    func catalogFallbackAndReadRace() async throws {
        for status in [nil, 404] as [Int?] {
            let transport = NotificationTestTransport(notice: notice(), status: status), clock = NotificationTestClock()
            try await prepare(transport)
            let suite = "notification-catalog-\(UUID())", preferences = UserDefaults(suiteName: suite)!
            let api = AgentAPI(transport: transport)
            let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences,
                                      synchronizationSleep: { try await clock.sleep($0) })
            defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
            await transport.hold("/v1/conversations")
            library.startSynchronization()
            try await wait { await transport.isHolding }
            if status == nil { try await transport.emit(notice(catalog: "2")) }
            await settle(); await transport.release()
            if status != nil {
                try await wait { await clock.delays.count == 1 }
                let delays = await clock.delays
                try expect(delays == [.seconds(2)])
                await clock.advance()
            }
            try await wait { await count(transport, "/v1/library") == 2 }
            library.closePresentations(); await api.changes.close()
        }
    }

    func supersededCatalogReadRetainsInvalidation() async throws {
        let transport = NotificationTestTransport(notice: notice()), clock = NotificationTestClock()
        try await prepare(transport)
        try await transport.responses.reply("/v1/conversations", .array([snapshot(id)]))
        let suite = "notification-superseded-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let api = AgentAPI(transport: transport)
        let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences,
                                  synchronizationSleep: { try await clock.sleep($0) })
        defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
        await transport.hold("/v1/conversations")
        library.startSynchronization()
        try await wait { await transport.isHolding }
        // A newer read supersedes the held notification read, then fails itself.
        await transport.responses.failNext("/v1/conversations")
        do { try await library.refreshSharedState(); throw CheckFailure(description: "Expected read failure") }
        catch is CheckFailure { throw CheckFailure(description: "Expected read failure") }
        catch {}
        await transport.release()
        try await wait { await clock.delays.count == 1 }
        let sleeps = await clock.delays
        try expect(sleeps == [.milliseconds(100)])
        await clock.advance()
        try await wait { library.sessionList.contains { $0.id == id } }
        let reads = await count(transport, "/v1/conversations")
        try expect(reads == 3)
        library.closePresentations(); await api.changes.close()
    }

    func transientReadFailuresRecoverWithoutCatalogChanges() async throws {
        let transport = NotificationTestTransport(notice: notice()), clock = NotificationTestClock()
        try await prepare(transport)
        try await transport.responses.reply(AgentAPI.path(id), snapshot(id, active: true))
        let api = AgentAPI(transport: transport)
        let store = ChatStore(provider: AgentAccounts(api: api), observationSleep: { try await clock.sleep($0) })
        defer { store.closePresentation() }
        try await store.loadSession(id)
        await transport.failReads(AgentAPI.path(id, "/sync"), count: 2)
        try await transport.emit(notice("2"))
        try await wait { await clock.delays.count == 1 }
        try expect(store.busy && store.messages.first?.text == "initial" && store.error != nil)
        try await transport.responses.reply(AgentAPI.path(id), snapshot(id, text: "recovered", active: true))
        // Only the conversation changes; the catalog and changes connection stay healthy.
        try await transport.emit(notice("3"))
        await clock.advance()
        try await wait { store.messages.first?.text == "recovered" }
        try expect(store.busy && store.error == nil)
        try await transport.responses.reply(AgentAPI.path(id), snapshot(id, text: "still observing", active: true))
        try await transport.emit(notice("4"))
        try await wait { store.messages.first?.text == "still observing" }
        await settle()
        let reads = await transport.responses.requests.count
        try await transport.emit(notice("4")); await settle()
        let after = await transport.responses.requests
        try expect(after.count == reads && after.allSatisfy { $0.method == "GET" })
        store.closePresentation(); await api.changes.close()
    }

    func warmSwitchingKeepsHiddenResidentsCurrent() async throws {
        let transport = NotificationTestTransport(notice: notice())
        try await prepare(transport)
        let firstSnapshot = try snapshot(id), secondSnapshot = try snapshot(other)
        try await transport.responses.reply("/v1/conversations", .array([firstSnapshot, secondSnapshot]))
        let suite = "notification-switch-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let api = AgentAPI(transport: transport)
        let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences)
        defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
        try await library.current.loadSession(id)
        try await library.refreshSharedState()
        let first = library.current
        library.openSession(other); await library.waitForNavigation()
        try expect(library.currentSessionID == other)
        let second = library.current
        try await transport.responses.reply(AgentAPI.path(id), snapshot(id, text: "hidden update"))
        try await transport.emit(notice("2"))
        try await wait { first.messages.first?.text == "hidden update" }
        let before = await transport.responses.requests.count
        for _ in 0..<10 {
            library.openSession(id); await library.waitForNavigation()
            try expect(library.current === first && library.current.messages.first?.text == "hidden update")
            library.openSession(other); await library.waitForNavigation()
            try expect(library.current === second)
        }
        await settle()
        let after = await transport.responses.requests.count, subscriptions = await transport.subscriptions
        try expect(before == after && subscriptions == 1)
        library.closePresentations(); await api.changes.close()
    }

    func coalescesEpochRemovalAndShutdown() async throws {
        let transport = NotificationTestTransport(notice: notice())
        let broker = AgentChangeBroker(transport: transport)
        let conversation = await broker.subscribe(.conversation(id))
        let catalog = await broker.subscribe(.catalog)
        var a = conversation.stream.makeAsyncIterator(), b = catalog.stream.makeAsyncIterator()
        _ = await a.next(); _ = await b.next()
        // Use catalog as a processing barrier while the conversation is stalled.
        for index in 2...50 {
            try await transport.emit(notice(String(index), catalog: String(index)))
            _ = await b.next()
        }
        _ = await a.next()
        var extra = false
        let pending = Task { var iterator = a; if await iterator.next(isolation: MainActor.shared) != nil { extra = true } }
        await settle(); try expect(!extra)
        try await transport.emit(.init(epoch: "epoch", catalog: "50", conversations: [:]))
        try await wait { extra }
        _ = await pending.value
        try await transport.emit(.init(epoch: "restarted", catalog: "50", conversations: [:]))
        _ = await b.next()
        conversation.close()
        try await transport.emit(.init(epoch: "restarted", catalog: "51", conversations: [:]))
        _ = await b.next()
        let subscriptions = await transport.subscriptions
        try expect(subscriptions == 1)
        await broker.close()
        let end = await b.next()
        try expect(end == nil)
        try await wait { await transport.connectionCount == 0 }
    }
}
