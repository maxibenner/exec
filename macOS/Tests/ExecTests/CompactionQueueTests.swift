import Foundation

private actor CompactionQueueTransport: AgentTransport {
    let requests = FakeAgentTransport()
    private let heldSuffix: String
    private(set) var waiting = false
    private var release: CheckedContinuation<Void, Never>?
    private var compactionSnapshot: AgentJSON?

    init(holding suffix: String = "/compact") { heldSuffix = suffix }
    func setCompactionSnapshot(_ value: AgentJSON) { compactionSnapshot = value }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if path.hasSuffix("/compact"), let compactionSnapshot {
            try await requests.reply(String(path.dropLast("/compact".count)), compactionSnapshot)
        }
        if path.hasSuffix(heldSuffix) {
            waiting = true
            await withCheckedContinuation { release = $0 }
        }
        return try await requests.request(method, path, body: body)
    }
    func finish() { release?.resume(); release = nil }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        requests.events(method, path, body: body)
    }
}

@MainActor struct CompactionQueueTests {
    private static let operationID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private static let queuedID = UUID(uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")!
    private var path: String { AgentAPI.path(AgentIntegrationTests.conversationID) }

    private func snapshot(_ state: String, queued: Bool = false, systemPrompt: String? = nil,
                          operationID: UUID = CompactionQueueTests.operationID) throws -> AgentJSON {
        guard case .object(var fields) = try AgentIntegrationTests.fixture(state: state, result: true),
              case .object(var configuration) = fields["configuration"],
              case .object(var settings) = configuration["settings"] else {
            throw CheckFailure(description: "Expected snapshot fixture")
        }
        fields["model"] = .string("openai/test")
        fields["supportsCompaction"] = .bool(true)
        fields["operation"] = .object(["id": .string(operationID.uuidString), "state": .string(state)])
        fields["pendingInput"] = .array(queued ? [.object([
            "id": .string(Self.queuedID.uuidString), "role": .string("user"), "text": .string("Queued message")
        ])] : [])
        if let systemPrompt { settings["systemPrompt"] = .string(systemPrompt) }
        configuration["settings"] = .object(settings)
        fields["configuration"] = .object(configuration)
        return .object(fields)
    }
    private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out awaiting compaction queue state")
    }
    private func withPanel(_ transport: CompactionQueueTransport,
                           check: @MainActor (ChatPanel) async throws -> Void) async throws {
        let requests = transport.requests
        try await requests.reply("/v1/providers", .array([.object([
            "id": .string("openai"), "name": .string("Test"), "connected": .bool(true)])]))
        try await requests.reply(path + "/compact", .object(["operationID": .string(Self.operationID.uuidString)]))
        try await requests.reply(path, snapshot("completed"))
        try await transport.setCompactionSnapshot(snapshot("running"))
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        try await provider.refreshConnections()
        let suite = "exec-compaction-queue-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(try JSONEncoder().encode([ChatModel(id: "openai/test", name: "Test")]), forKey: "chat.modelCatalog")
        let library = ChatLibrary(provider: provider, preferences: preferences)
        defer { library.closePresentations() }
        try await requests.reply("/v1/library", JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration())))
        try await requests.reply("/v1/conversations", .array([snapshot("completed")]))
        try await library.refreshSharedState()
        try library.current.apply(snapshot("completed", operationID: AgentIntegrationTests.operationID).decoded(AgentSnapshot.self))
        try await check(ChatPanel(library: library, conversation: library.current))
    }

    func pendingAndRunningCompactionQueueOnceWithoutConsumingNewDrafts() async throws {
        for pending in [true, false] {
            let transport = CompactionQueueTransport()
            try await withPanel(transport) { panel in
                let store = panel.current
                panel.compact()
                try await wait { await transport.waiting }
                if !pending {
                    await transport.finish()
                    await store.waitUntilIdle()
                }
                try await transport.requests.reply(path, snapshot("running", queued: true))
                panel.draft = "Queued message"
                try expect(panel.canSend && panel.canEditDraft)
                panel.send(); panel.send()
                panel.draft = "Keep this newer draft"
                panel.send()
                if pending {
                    for _ in 0..<5 { await Task.yield() }
                    let beforeReceipt = await transport.requests.requests
                    try expect(!beforeReceipt.contains { $0.path.hasSuffix("/steer") || $0.path.hasSuffix("/turns") })
                    await transport.finish()
                }
                await store.waitUntilIdle()
                try expect(store.draft == "Keep this newer draft" && store.error == nil)
                try expect(store.queuedMessages.map(\.id) == [Self.queuedID])
                try expect(!store.messages.contains { $0.id == Self.queuedID })
                for state in ["completed", "interrupted", "failed"] {
                    try store.apply(snapshot(state, queued: true).decoded(AgentSnapshot.self))
                    try store.apply(snapshot(state, queued: true).decoded(AgentSnapshot.self))
                    try expect(store.queuedMessages.map(\.id) == [Self.queuedID])
                }
                for _ in 0..<5 { await Task.yield() }
                let writes = await transport.requests.requests.filter { $0.method != "GET" }
                try expect(writes.map(\.path) == [path + "/compact", path + "/steer"])
                let body = try JSONDecoder().decode(AgentJSON.self, from: writes[1].body!)
                try expect(body["operationID"].string == Self.operationID.uuidString.lowercased())
                try expect(body["text"].string == "Queued message" && store.hasUnsentDraft)
            }
        }
    }

    func uncertainCompactionOrQueueNeverFallsBackToANewTurn() async throws {
        for failure in ["compact", "steer", "settled"] {
            let transport = CompactionQueueTransport()
            try await withPanel(transport) { panel in
                let store = panel.current
                panel.compact()
                try await wait { await transport.waiting }
                panel.draft = "Keep this unsent message"
                panel.send(); panel.send()
                if failure == "settled" {
                    try await transport.requests.reply(path, snapshot("completed"))
                }
                await transport.requests.fail(path + (failure == "compact" ? "/compact" : "/steer"))
                await transport.finish()
                await store.waitUntilIdle()
                try expect(store.draft == "Keep this unsent message" && store.error != nil)
                try store.apply(snapshot("completed").decoded(AgentSnapshot.self))
                try store.apply(snapshot("completed").decoded(AgentSnapshot.self))
                for _ in 0..<5 { await Task.yield() }
                let writes = await transport.requests.requests.filter { $0.method != "GET" }
                try expect(writes.filter { $0.path == path + "/compact" }.count == 1)
                try expect(writes.filter { $0.path == path + "/steer" }.count == (failure == "compact" ? 0 : 1))
                try expect(!writes.contains { $0.path.hasSuffix("/turns") })
            }
        }
    }

    func stopBeforeCompactionReceiptRetainsDraftAndTargetsAcceptedOperation() async throws {
        let transport = CompactionQueueTransport()
        try await withPanel(transport) { panel in
            let store = panel.current
            panel.compact()
            try await wait { await transport.waiting }
            panel.draft = "Do not send after stop"
            panel.send(); panel.send()
            panel.stop()
            await transport.finish()
            try await wait { await transport.requests.requests.contains { $0.path == path + "/cancel" } }
            try await transport.requests.reply(path, snapshot("interrupted"))
            try await wait { !store.isStopping }
            await store.waitUntilIdle()
            try expect(store.draft == "Do not send after stop" && store.error == nil)
            let writes = await transport.requests.requests.filter { $0.method != "GET" }
            try expect(writes.map(\.path) == [path + "/compact", path + "/cancel"])
            let cancel = try JSONDecoder().decode(AgentJSON.self, from: writes[1].body!)
            try expect(cancel["operationID"].string == Self.operationID.uuidString.lowercased())
        }
    }

    func compactionDoesNotBypassConfigurationSavesOrUncertainWrites() async throws {
        for fail in [false, true] {
            let transport = CompactionQueueTransport(holding: "/settings")
            try await withPanel(transport) { panel in
                let store = panel.current
                let prompt = "Updated prompt before compaction"
                try await transport.requests.reply(path + "/settings", snapshot("completed", systemPrompt: prompt))
                try await transport.requests.reply(path, snapshot("completed", systemPrompt: prompt))
                try await transport.setCompactionSnapshot(snapshot("running", systemPrompt: prompt))
                if fail { await transport.requests.fail(path + "/settings") }
                store.systemPrompt = prompt
                store.scheduleSave()
                panel.compact()
                try await wait { await transport.waiting }
                panel.draft = "Send only after a confirmed save"
                panel.send(); panel.send()
                await transport.finish()
                if fail {
                    try await wait { store.hasUnsavedChanges && !store.busy }
                    panel.send()
                    try store.apply(snapshot("completed").decoded(AgentSnapshot.self))
                    try expect(store.hasUnsavedChanges && !store.canRequestCommands)
                } else {
                    try await wait { store.isCompacting }
                    await store.waitUntilIdle()
                    panel.send(); panel.send()
                    await store.waitUntilIdle()
                }
                let writes = await transport.requests.requests.filter { $0.method != "GET" }
                try expect(writes.map(\.path) == (fail ? [path + "/settings"] : [path + "/settings", path + "/compact", path + "/steer"]))
                try expect(store.draft == (fail ? "Send only after a confirmed save" : ""))
            }
        }
    }
}
