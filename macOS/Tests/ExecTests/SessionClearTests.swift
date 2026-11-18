import Foundation

/// Reads reflect only mutations that actually arrived, never a preinstalled future snapshot.
private actor ClearSnapshotTransport: AgentTransport {
    private let sessionPath: String
    private var snapshot: AgentJSON
    private var mutations: [String: AgentJSON] = [:]
    private var failingMutation: String?
    private var commitBeforeFailure = false
    private var holdClear = false
    private var pendingTurn: CheckedContinuation<Void, Never>?
    private var holdTurn = false
    var turnIsWaiting: Bool { pendingTurn != nil }
    private var pendingClear: CheckedContinuation<Void, Never>?
    private(set) var requests: [FakeAgentTransport.Request] = []
    var clearIsWaiting: Bool { pendingClear != nil }

    init(path: String, snapshot: AgentJSON) {
        sessionPath = path; self.snapshot = snapshot
    }
    func replyTo(_ method: String, _ path: String, with snapshot: AgentJSON) {
        mutations[method + " " + path] = snapshot
    }
    func failNext(_ method: String, _ path: String, afterCommit: Bool = false) {
        failingMutation = method + " " + path; commitBeforeFailure = afterCommit
    }
    func holdNextTurn() { holdTurn = true }
    func releaseTurn() { pendingTurn?.resume(); pendingTurn = nil }
    func holdNextClear() { holdClear = true }
    func releaseClear() { pendingClear?.resume(); pendingClear = nil }

    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        requests.append(.init(method: method, path: path, body: body))
        if method == "GET" {
            if let reply = mutations[method + " " + path] { return try JSONEncoder().encode(reply) }
            let route = String(path.split(separator: "?", maxSplits: 1)[0])
            if route == sessionPath + "/sync" {
                return try JSONEncoder().encode(AgentSyncFixture.page(snapshot, path: path))
            }
            guard route == sessionPath else { throw CheckFailure(description: "Unexpected clear-test read: \(path)") }
            return try JSONEncoder().encode(snapshot)
        }
        if method == "POST", path == sessionPath + "/clear", holdClear {
            holdClear = false
            await withCheckedContinuation { pendingClear = $0 }
        }
        if method == "POST", path == sessionPath + "/turns", holdTurn {
            holdTurn = false
            await withCheckedContinuation { pendingTurn = $0 }
        }
        let key = method + " " + path
        let fails = failingMutation == key
        if fails { failingMutation = nil }
        if !fails || commitBeforeFailure {
            guard let updated = mutations.removeValue(forKey: key) else {
                throw CheckFailure(description: "Unexpected clear-test mutation: \(key)")
            }
            snapshot = updated
        }
        if fails { throw ExecError("Mutation acknowledgement lost. Not retried.") }
        return try JSONEncoder().encode(snapshot)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { _ in }
    }
}

@MainActor struct SessionClearTests {
    private let id = AgentIntegrationTests.conversationID
    private var path: String { AgentAPI.path(id) }
    private let savedSettings = AgentSettings(systemPrompt: "Keep the session prompt", autoApprove: false,
                                               effort: "low", searchModel: "openai/session-search")
    private let image = ImageAttachment(name: "draft.png", mediaType: "image/png", data: Data([1, 2, 3]))
    private let file = FileAttachment(name: "draft.txt", data: Data("Unsent file bytes".utf8))

    private func snapshot(model: String = "openai/session", settings: AgentSettings? = nil,
                          disabled: [String] = ["shell"], state: String = "completed", cleared: Bool = false) throws -> AgentJSON {
        guard case .object(var fields) = try AgentIntegrationTests.fixture(state: state, result: state != "awaiting_approval"),
              case .object(var configuration) = fields["configuration"],
              case .object(var metadata) = fields["metadata"] else {
            throw CheckFailure(description: "Invalid clear fixture")
        }
        fields["model"] = .string(model)
        configuration["settings"] = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(settings ?? savedSettings))
        if cleared {
            fields["messages"] = .array([])
            fields["pendingInput"] = .array([])
            fields["operation"] = .null
            fields["approval"] = .null
            fields["activeToolCallID"] = .null
            fields["contextUsage"] = .null
        }
        fields["configuration"] = .object(configuration)
        metadata["disabledTools"] = .array(disabled.map { .string($0) })
        fields["metadata"] = .object(metadata)
        return .object(fields)
    }
    private func expectSnapshot(_ store: ChatStore, _ value: AgentJSON) throws {
        let expected = try value.decoded(AgentSnapshot.self)
        var pendingIDs: [String: UUID] = [:]
        try expect(store.currentSessionID == expected.id && store.workspace?.root.path == expected.workspace)
        try expect(store.selectedModel == expected.model && store.selectedEffort == expected.configuration.settings.effort)
        try expect(store.systemPrompt == expected.configuration.settings.systemPrompt)
        try expect(store.searchModel == expected.configuration.settings.searchModel)
        try expect(store.autoApproveTools == expected.configuration.settings.autoApprove)
        try expect(store.disabledTools == Set(expected.metadata.disabledTools ?? []))
        try expect(store.messages == expected.transcript(images: [:], pendingIDs: &pendingIDs))
        try expect(store.contextUsage == expected.contextUsage)
    }
    private func expectClear(_ request: FakeAgentTransport.Request) throws {
        try expect(request.method == "POST" && request.path == path + "/clear")
        guard let body = request.body else { throw CheckFailure(description: "Missing clear body") }
        try expect(try JSONDecoder().decode(AgentJSON.self, from: body) == .object([:]))
    }
    private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        // Idle transcript observers poll every two seconds.
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Timed out awaiting clear-test state")
    }

    func clearPreservesConfigurationAndLocalDraftAcrossObservers() async throws {
        let initial = try snapshot(), cleared = try snapshot(cleared: true)
        let transport = ClearSnapshotTransport(path: path, snapshot: initial)
        await transport.replyTo("POST", path + "/clear", with: cleared)
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        let store = ChatStore(provider: provider), observer = ChatStore(provider: provider)
        defer { store.closePresentation(); observer.closePresentation() }
        try store.apply(initial.decoded(AgentSnapshot.self))
        try await observer.loadSession(id)
        try expectSnapshot(observer, initial)
        try expect(!store.messages.isEmpty && store.contextUsage != nil && store.canClear)
        store.draft = "Keep this unsent prose"
        store.draftImages = [image]; store.draftFiles = [file]
        observer.draft = "Another window's draft"
        store.error = "An earlier error"
        store.clear(); store.clear()
        await store.waitUntilIdle()
        try expectSnapshot(store, cleared)
        try expect(store.messages.isEmpty && store.contextUsage == nil && store.tools.pendingApproval == nil)
        try expect(store.canClear && !store.busy && !store.hasUnsavedChanges && store.error == nil)
        try expect(store.draft == "Keep this unsent prose" && store.draftImages == [image] && store.draftFiles == [file])
        try await wait { observer.messages.isEmpty }
        try expectSnapshot(observer, cleared)
        try expect(observer.draft == "Another window's draft" && !observer.hasUnsavedChanges && observer.error == nil)
        let requests = await transport.requests
        let writes = requests.filter { $0.method != "GET" }
        try expect(writes.count == 1)
        try expectClear(writes[0])
        // The existing reader must reset its old transcript cursor without submitting work.
        try expect(requests.contains { $0.method == "GET" && $0.path.hasPrefix(path + "/sync?after=") })
    }

    func clearPersistsPendingConfigurationBeforeReset() async throws {
        for scheduled in [false, true] {
            let initial = try snapshot()
            var settings = savedSettings
            settings.effort = "high"; settings.systemPrompt = "Pending prompt"
            settings.searchModel = "openai/pending-search"; settings.autoApprove = scheduled
            let disabled = scheduled ? ["shell", "delegate"] : ["shell"]
            let cleared = try snapshot(model: "openai/updated", settings: settings, disabled: disabled, cleared: true)
            let transport = ClearSnapshotTransport(path: path, snapshot: initial)
            await transport.replyTo("PUT", path + "/model", with: try snapshot(model: "openai/updated"))
            await transport.replyTo("PUT", path + "/settings", with: try snapshot(model: "openai/updated", settings: settings))
            if scheduled {
                await transport.replyTo("PATCH", path, with: try snapshot(model: "openai/updated", settings: settings, disabled: disabled))
            }
            await transport.replyTo("POST", path + "/clear", with: cleared)
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            try store.apply(initial.decoded(AgentSnapshot.self))
            store.draft = "/clear"
            store.selectedModel = "openai/updated"; store.selectedEffort = settings.effort
            store.systemPrompt = settings.systemPrompt; store.searchModel = settings.searchModel!
            if scheduled {
                store.setToolEnabled("delegate", false)
                store.setAutoApproveTools(true)
            }
            store.clear()
            await store.waitUntilIdle()
            try expectSnapshot(store, cleared)
            try expect(store.draft.isEmpty && store.canClear && !store.hasUnsavedChanges && store.error == nil)
            let writes = await transport.requests.filter { $0.method != "GET" }
            let expected = ["PUT " + path + "/model", "PUT " + path + "/settings"]
                + (scheduled ? ["PATCH " + path] : []) + ["POST " + path + "/clear"]
            try expect(writes.map { $0.method + " " + $0.path } == expected)
            let model = try JSONDecoder().decode(AgentJSON.self, from: writes[0].body!)
            try expect(model["model"].string == "openai/updated")
            try expect(try JSONDecoder().decode(AgentSettings.self, from: writes[1].body!) == settings)
            if scheduled {
                let tools = try JSONDecoder().decode(AgentJSON.self, from: writes[2].body!)
                try expect(Set(tools["disabledTools"].array.compactMap(\.string)) == Set(disabled))
            }
            try expectClear(writes.last!)
        }
    }

    func clearConsumesOnlyUnchangedCommandDraftAfterConfirmation() async throws {
        let cases: [(draft: String, replacement: String?, expected: String)] = [
            ("/clear", nil, ""), ("/cl", nil, ""), ("/CLEAR", nil, ""),
            ("/clear", "Keep typing while clearing", "Keep typing while clearing"), ("/model", nil, "/model")
        ]
        for item in cases {
            let initial = try snapshot(), cleared = try snapshot(cleared: true)
            let transport = ClearSnapshotTransport(path: path, snapshot: initial)
            await transport.replyTo("POST", path + "/clear", with: cleared)
            await transport.holdNextClear()
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer {
                store.closePresentation()
                Task { await transport.releaseClear() }
            }
            try store.apply(initial.decoded(AgentSnapshot.self))
            store.draft = item.draft; store.draftImages = [image]; store.draftFiles = [file]
            store.clear()
            try await wait { await transport.clearIsWaiting }
            try expectSnapshot(store, initial)
            try expect(store.draft == item.draft && store.busy && !store.canClear)
            if let replacement = item.replacement { store.draft = replacement }
            store.clear() // An in-flight clear is not queued or submitted again.
            await transport.releaseClear()
            await store.waitUntilIdle()
            try expectSnapshot(store, cleared)
            try expect(store.draft == item.expected && store.draftImages == [image] && store.draftFiles == [file])
            try expect(store.canClear && store.error == nil)
            let writes = await transport.requests.filter { $0.method != "GET" }
            try expect(writes.count == 1)
            try expectClear(writes[0])
        }
    }

    func failedClearRequiresReadonlyRecoveryWithoutRetry() async throws {
        for committed in [false, true] {
            let initial = try snapshot(), cleared = try snapshot(cleared: true)
            let transport = ClearSnapshotTransport(path: path, snapshot: initial)
            await transport.replyTo("POST", path + "/clear", with: cleared)
            await transport.failNext("POST", path + "/clear", afterCommit: committed)
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            try store.apply(initial.decoded(AgentSnapshot.self))
            store.draft = "/clear"; store.draftImages = [image]; store.draftFiles = [file]
            store.clear()
            await store.waitUntilIdle()
            try expect(store.hasUnsavedChanges && !store.canClear && !store.busy && store.error != nil)
            // A committed clear can already be visible through a read-only observer after a lost acknowledgement.
            if !committed { try expectSnapshot(store, initial) }
            try expect(store.draft == "/clear" && store.draftImages == [image] && store.draftFiles == [file])
            store.clear()
            await store.waitUntilIdle()
            if committed {
                store.reconnectIfNeeded()
                await store.waitUntilIdle()
                try expect(store.error == nil)
            } else {
                try await store.loadSession(id)
            }
            try expectSnapshot(store, committed ? cleared : initial)
            try expect(store.canClear && !store.hasUnsavedChanges)
            try expect(store.draft == "/clear" && store.draftImages == [image] && store.draftFiles == [file])
            let requests = await transport.requests
            let writes = requests.filter { $0.method != "GET" }
            try expect(writes.count == 1)
            try expectClear(writes[0])
            try expect(requests.contains { $0.method == "GET" && $0.path.hasPrefix(path + "/sync") })
        }
    }

    func failedConfigurationSavePreventsClearWithoutRetry() async throws {
        let initial = try snapshot()
        let transport = ClearSnapshotTransport(path: path, snapshot: initial)
        await transport.failNext("PUT", path + "/settings")
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try store.apply(initial.decoded(AgentSnapshot.self))
        let messages = store.messages, usage = store.contextUsage
        store.draft = "/clear"; store.draftImages = [image]; store.draftFiles = [file]
        store.selectedEffort = "high"
        store.clear()
        await store.waitUntilIdle()
        try expect(store.hasUnsavedChanges && !store.canClear && store.error != nil)
        try expect(store.messages == messages && store.contextUsage == usage)
        try expect(store.draft == "/clear" && store.draftImages == [image] && store.draftFiles == [file])
        store.clear()
        await store.waitUntilIdle()
        try await store.loadSession(id)
        try expectSnapshot(store, initial)
        try expect(store.canClear && !store.hasUnsavedChanges)
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.count == 1 && writes[0].method == "PUT" && writes[0].path == path + "/settings")
    }

    func clearWaitsForSingleSubmissionThenResetsWithoutReplay() async throws {
        let initial = try snapshot(), running = try snapshot(state: "running"), cleared = try snapshot(cleared: true)
        let transport = ClearSnapshotTransport(path: path, snapshot: initial)
        await transport.replyTo("GET", "/v1/providers", with: .array([
            .object(["id": .string("openai"), "name": .string("OpenAI"), "connected": .bool(true)])
        ]))
        await transport.replyTo("POST", path + "/turns", with: running)
        await transport.replyTo("POST", path + "/clear", with: cleared)
        await transport.holdNextTurn()
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        try await provider.refreshConnections()
        let store = ChatStore(provider: provider,
                              sleepPrevention: .init(begin: { NSObject() }, end: { _ in }))
        defer { store.closePresentation() }
        try store.apply(initial.decoded(AgentSnapshot.self))
        store.installModels([ChatModel(id: "openai/session", name: "Test")])
        store.draft = "Start a turn"
        store.send()
        try await wait { await transport.turnIsWaiting }
        store.draft = "/clear"
        try expect(store.canClear)
        store.clear()
        await Task.yield()
        try expect(!store.canClear)
        await transport.releaseTurn()
        await store.waitUntilIdle()
        try expectSnapshot(store, cleared)
        try expect(store.draft.isEmpty && store.error == nil && !store.busy)
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.map(\.path) == [path + "/turns", path + "/clear"])
    }

    func activeClearSavesPendingSettingsOnlyAfterCancellation() async throws {
        let initial = try snapshot(state: "running"), cleared = try snapshot(cleared: true)
        var settings = savedSettings
        settings.effort = "high"
        let updated = try snapshot(settings: settings, cleared: true)
        let transport = ClearSnapshotTransport(path: path, snapshot: initial)
        await transport.replyTo("POST", path + "/clear", with: cleared)
        await transport.replyTo("PUT", path + "/settings", with: updated)
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)),
                              sleepPrevention: .init(begin: { NSObject() }, end: { _ in }))
        defer { store.closePresentation() }
        try store.apply(initial.decoded(AgentSnapshot.self))
        store.selectedEffort = "high"
        store.clear()
        await store.waitUntilIdle()
        try expectSnapshot(store, updated)
        try expect(store.error == nil && !store.busy)
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.map(\.path) == [path + "/clear", path + "/settings"])
    }

    func unsavedSessionsCannotClear() async throws {
        let transport = FakeAgentTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        store.draft = "/clear"
        try expect(store.currentSessionID == nil && !store.canClear)
        store.clear()
        await store.waitUntilIdle()
        let requests = await transport.requests
        try expect(requests.isEmpty)
    }

    func activeSessionsClearImmediatelyWithoutWaitingForIdle() async throws {
        for state in ["running", "awaiting_approval", "cancelling"] {
            let initial = try snapshot(state: state), cleared = try snapshot(cleared: true)
            let transport = ClearSnapshotTransport(path: path, snapshot: initial)
            await transport.replyTo("POST", path + "/clear", with: cleared)
            await transport.holdNextClear()
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)),
                                  sleepPrevention: .init(begin: { NSObject() }, end: { _ in }))
            defer { store.closePresentation() }
            try store.apply(initial.decoded(AgentSnapshot.self))
            store.draft = "/clear"
            try expect(store.busy && store.canClear && store.canEditDraft)
            store.clear()
            try await wait { await transport.clearIsWaiting }
            try expect(store.busy && !store.canClear)
            store.clear() // Never queue a second reset.
            await transport.releaseClear()
            await store.waitUntilIdle()
            try expectSnapshot(store, cleared)
            try expect(!store.busy && store.canClear && store.error == nil && store.draft.isEmpty)
            try expect(store.messages.isEmpty && store.contextUsage == nil && store.tools.pendingApproval == nil)
            let writes = await transport.requests.filter { $0.method != "GET" }
            try expect(writes.count == 1)
            try expectClear(writes[0])
        }
    }
}
