import Foundation

@MainActor struct ToolAvailabilityTests {
    private let path = "/v1/tools/availability"

    private func json<T: Encodable>(_ value: T) throws -> AgentJSON {
        try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(value))
    }
    private func response(_ available: Bool, reason: String? = nil,
                          names: [String] = ["web_search"]) -> AgentJSON {
        .object(Dictionary(uniqueKeysWithValues: names.map {
            ($0, .object(["available": .bool(available), "reason": reason.map(AgentJSON.string) ?? .null]))
        }))
    }
    private func notice(_ catalog: String) -> RemoteChangeNotification {
        .init(epoch: "availability-test", catalog: catalog, conversations: [:])
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        throw CheckFailure(description: "Tool availability did not reach its barrier")
    }
    private func settle() async { for _ in 0..<200 { await Task.yield() } }

    /// Always release captured reads and close subscriptions, including on assertion failure.
    private func observing(_ query: ToolAvailabilityQuery, transport: NotificationTestTransport,
                           check: @MainActor (ToolAvailabilityObserver, AgentAPI) async throws -> Void) async throws {
        let observer = ToolAvailabilityObserver(), api = AgentAPI(transport: transport)
        var finished = false
        let task = Task { await observer.observe(query: query, api: api); finished = true }
        var failure: (any Error)?
        do { try await check(observer, api) } catch { failure = error }
        task.cancel()
        await transport.release()
        await api.changes.close()
        try await wait {
            let connections = await transport.connectionCount
            return finished && connections == 0
        }
        try expect(observer.statuses.isEmpty && observer.status(for: "web_search", query: query) == nil)
        if let failure { throw failure }
    }

    func queriesSerializeExactSessionAndDefaultPreviews() async throws {
        let transport = FakeAgentTransport(), api = AgentAPI(transport: transport)
        let store = ChatStore(provider: AgentAccounts(api: api))
        defer { store.closePresentation() }
        store.selectedModel = "openai/chat"
        store.searchModel = "openai/not-in-catalog"
        let preview = store.toolAvailabilityQuery
        try expect(preview.names == SessionTool.names && preview.conversationID == nil)
        try expect(preview.model == "openai/chat" && preview.searchModel == "openai/not-in-catalog")
        try await transport.reply(path, response(false, reason: "Synthetic backend reason"))
        let statuses = try await api.toolAvailability(preview)
        try expect(statuses["web_search"] == .init(available: false, reason: "Synthetic backend reason"))
        var requests = await transport.requests
        try expect(requests.count == 1 && requests[0].method == "POST" && requests[0].path == path)
        guard let body = requests[0].body else { throw CheckFailure(description: "Missing availability query") }
        try expect(try JSONDecoder().decode(AgentJSON.self, from: body) == .object([
            "names": .array(SessionTool.names.map(AgentJSON.string)),
            "model": .string("openai/chat"), "searchModel": .string("openai/not-in-catalog")
        ])) // No conversationID key (not null), and no model-picker substitution.

        try store.apply(AgentIntegrationTests.fixture(state: "completed", result: true).decoded(AgentSnapshot.self))
        store.selectedModel = "openai/chat"
        store.searchModel = "openai/not-in-catalog"
        try expect(store.toolAvailabilityQuery.conversationID == AgentIntegrationTests.conversationID)
        let sessionBody = try json(store.toolAvailabilityQuery)
        try expect(sessionBody["conversationID"].string == AgentIntegrationTests.conversationID.uuidString.lowercased())
        let mixedID = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")!
        let mixedBody = try json(ToolAvailabilityQuery(names: SessionTool.names, conversationID: mixedID, model: "openai/chat"))
        try expect(mixedBody["conversationID"].string == "abcdefab-cdef-4abc-8def-abcdefabcdef")
        try expect(sessionBody["model"].string == "openai/chat" && sessionBody["searchModel"].string == "openai/not-in-catalog")
        for search in ["", "deepseek/search"] {
            store.searchModel = search
            try expect(store.toolAvailabilityQuery.searchModel == nil)
            guard case .object(let fields) = try json(store.toolAvailabilityQuery) else {
                throw CheckFailure(description: "Expected an availability object")
            }
            try expect(fields["searchModel"] == nil)
        }

        // An absent saved model falls back exactly as makeConversation does. The raw
        // same-provider search choice survives even when absent from searchModels.
        let suite = "exec-availability-query-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let models = [ChatModel(id: "openai/chat", name: "Chat")]
        preferences.set(try JSONEncoder().encode(models), forKey: "chat.modelCatalog")
        var config = AgentLibraryConfiguration()
        config.defaultModel = "openai/missing-chat"
        config.settings.searchModel = "openai/not-in-catalog"
        try await transport.reply("/v1/library", json(config))
        try await transport.reply("/v1/providers", .array([.object([
            "id": .string("openai"), "name": .string("OpenAI"), "connected": .bool(true)
        ])]))
        try await transport.reply("/v1/models", json(models))
        try await transport.reply("/v1/conversations", .array([]))
        let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences)
        defer { library.closePresentations() }
        try await library.restore()
        let defaults = library.defaultToolAvailabilityQuery
        try expect(defaults == preview && library.effectiveSearchModel == "openai/chat")
        library.newConversation()
        guard let next = library.pendingNewConversation else { throw CheckFailure(description: "Missing new conversation preview") }
        try expect(next.toolAvailabilityQuery == defaults && next.searchModel == "openai/not-in-catalog")
        requests = await transport.requests
        try expect(requests.allSatisfy { $0.method == "GET" || ($0.method == "POST" && $0.path == path) })
    }

    func unavailableStatusDoesNotChangeSessionSelection() async throws {
        let transport = NotificationTestTransport(status: 404)
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)), disabledTools: ["shell"])
        defer { store.closePresentation() }
        store.selectedModel = "deepseek/test"
        let query = store.toolAvailabilityQuery
        try await transport.responses.reply(path, response(false, reason: "Synthetic workspace restriction", names: ["shell", "web_search"]))
        try await observing(query, transport: transport) { observer, _ in
            try await wait { observer.status(for: "web_search", query: query)?.available == false }
            try expect(store.disabledTools == ["shell"] && store.canSelectTools)
            try expect(observer.status(for: "shell", query: query)?.available == false)
            try expect(observer.status(for: "read_file", query: query) == nil) // Unknown is not unavailable.
            // Both checked and unchecked unavailable tools remain editable, without
            // creating a conversation merely to inspect or change a local selection.
            store.setToolEnabled("web_search", false)
            store.setToolEnabled("shell", true)
            await store.waitForPendingSave()
            try expect(store.disabledTools == ["web_search"] && store.canSelectTools)
            try expect(observer.status(for: "web_search", query: query)?.available == false)
            store.setToolEnabled("web_search", true)
            await store.waitForPendingSave()
            try expect(store.disabledTools.isEmpty)
            let requests = await transport.responses.requests
            try expect(requests.count == 1 && requests[0].method == "POST" && requests[0].path == path)
        }
    }

    func newerQueryAndDisappearanceRejectLateResponses() async throws {
        // Legacy notifications avoid an unrelated initial catalog catch-up during
        // this deliberately held, cancellation-insensitive transport read.
        let transport = NotificationTestTransport(status: 404), api = AgentAPI(transport: transport)
        let observer = ToolAvailabilityObserver()
        let old = ToolAvailabilityQuery(names: ["web_search"], model: "openai/old", searchModel: "openai/search-old")
        let new = ToolAvailabilityQuery(names: ["web_search"], model: "openai/new", searchModel: "openai/search-new")
        try await transport.responses.reply(path, response(false, reason: "Old query only"))
        await transport.hold(path)
        var oldFinished = false, newFinished = false
        let older = Task { await observer.observe(query: old, api: api); oldFinished = true }
        var newer: Task<Void, Never>?
        var failure: (any Error)?
        do {
            try await wait { await transport.isHolding }
            try await transport.responses.reply(path, response(true))
            newer = Task { await observer.observe(query: new, api: api); newFinished = true }
            try await wait { observer.status(for: "web_search", query: new)?.available == true }
            try expect(observer.status(for: "web_search", query: old) == nil)
            for mismatch in [
                ToolAvailabilityQuery(names: ["shell"], model: new.model, searchModel: new.searchModel),
                ToolAvailabilityQuery(names: new.names, conversationID: AgentIntegrationTests.conversationID, model: new.model, searchModel: new.searchModel),
                ToolAvailabilityQuery(names: new.names, model: new.model, searchModel: "openai/different-search")
            ] {
                try expect(observer.status(for: "web_search", query: mismatch) == nil)
            }
            await transport.release() // Still subscribed and not cancelled: exercise the query-generation guard.
            await settle()
            try expect(observer.statuses["web_search"] == .init(available: true, reason: nil))
            older.cancel()
            try await wait { oldFinished }
            try expect(observer.status(for: "web_search", query: new)?.available == true) // Old teardown cannot clear new state.
            newer?.cancel() // The view's disappearance must clear already-published metadata.
            try await wait { newFinished }
            try expect(observer.statuses.isEmpty && observer.status(for: "web_search", query: new) == nil)
        } catch { failure = error }
        older.cancel(); newer?.cancel()
        await transport.release()
        await api.changes.close()
        try await wait {
            let connections = await transport.connectionCount
            return oldFinished && (newer == nil || newFinished) && connections == 0
        }
        await settle()
        try expect(observer.statuses.isEmpty)
        if let failure { throw failure }
    }

    func catalogRefreshClearsFailedStatusWithoutSettingsWrites() async throws {
        let transport = NotificationTestTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)), disabledTools: ["shell"])
        defer { store.closePresentation() }
        store.selectedModel = "openai/chat"
        let query = store.toolAvailabilityQuery
        try await transport.responses.reply(path, response(false, reason: "Old backend reason"))
        try await observing(query, transport: transport) { observer, _ in
            try await wait { observer.status(for: "web_search", query: query)?.reason == "Old backend reason" }
            try await wait { await transport.connectionCount == 1 }
            try await transport.emit(notice("1"))
            try await wait { await transport.responses.requests.count == 2 }
            try await wait { observer.status(for: "web_search", query: query)?.reason == "Old backend reason" }
            // A failed catalog-triggered read must remove the old reason, not keep
            // claiming a tool is unavailable based on a previous account/model state.
            await transport.responses.failNext(path)
            try await transport.emit(notice("2"))
            try await wait {
                let reads = await transport.responses.requests.count
                return reads == 3 && observer.statuses.isEmpty
            }
            await settle()
            try expect(observer.status(for: "web_search", query: query) == nil && store.disabledTools == ["shell"])
            try await transport.responses.reply(path, response(true))
            try await transport.emit(notice("3"))
            try await wait { observer.status(for: "web_search", query: query)?.available == true }
            await settle()
            let requests = await transport.responses.requests
            try expect(requests.count == 4 && requests.allSatisfy { $0.method == "POST" && $0.path == path })
            try expect(store.disabledTools == ["shell"] && store.error == nil)
            let subscriptions = await transport.subscriptions
            try expect(subscriptions == 1)
        }
    }

    func defaultSelectionsStayEditableWithoutChangingExistingSessions() async throws {
        let suite = "exec-availability-defaults-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = NotificationTestTransport(status: 404), api = AgentAPI(transport: transport)
        let library = ChatLibrary(provider: AgentAccounts(api: api), preferences: preferences)
        defer { library.closePresentations() }
        let query = library.defaultToolAvailabilityQuery
        try await transport.responses.reply(path, response(false, reason: "Synthetic backend reason", names: ["shell", "read_file"]))
        var config = AgentLibraryConfiguration()
        config.defaultDisabledTools = ["shell", "read_file"]
        try await transport.responses.reply("/v1/library", json(config))
        try await observing(query, transport: transport) { observer, _ in
            try await wait { observer.status(for: "read_file", query: query)?.available == false }
            try expect(library.defaultDisabledTools == ["shell"])
            let before = await transport.responses.requests
            try expect(before.count == 1 && before[0].path == path)
            library.setDefaultToolEnabled("read_file", false)
            try await wait { !library.accountBusy }
            try expect(library.defaultDisabledTools == ["shell", "read_file"])
            try expect(library.current.disabledTools == ["shell"])
            try expect(observer.status(for: "read_file", query: query)?.available == false)
            let writes = await transport.responses.requests.filter { $0.path != path }
            try expect(writes.count == 1 && writes[0].method == "PATCH" && writes[0].path == "/v1/library")
            library.newConversation()
            try expect(library.pendingNewConversation?.disabledTools == ["shell", "read_file"])
            try expect(library.error == nil)
        }
    }
}
