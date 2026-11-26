import Foundation

/// Publish changed snapshots only when the corresponding write arrives, so
/// background reads cannot make a missing pre-fork save appear successful.
private actor ForkSnapshotTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private let sourcePath: String
    private let forkPath: String
    private var source: AgentJSON
    private let fork: AgentJSON
    private var updates: [String: AgentJSON] = [:]

    init(sourcePath: String, forkPath: String, source: AgentJSON, fork: AgentJSON) {
        self.sourcePath = sourcePath; self.forkPath = forkPath
        self.source = source; self.fork = fork
    }
    func save(_ snapshot: AgentJSON, at path: String) { updates[path] = snapshot }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "PUT" || method == "PATCH", let updated = updates.removeValue(forKey: path) {
            source = updated
            try await responses.reply(path, updated)
            try await responses.reply(sourcePath, updated)
            try await responses.reply("/v1/conversations", .array([source]))
        }
        if method == "POST", path == sourcePath + "/fork" {
            try await responses.reply(path, fork)
            try await responses.reply(forkPath, fork)
            try await responses.reply("/v1/conversations", .array([source, fork]))
        }
        return try await responses.request(method, path, body: body)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
}

@MainActor struct SessionForkTests {
    private let sourceID = AgentIntegrationTests.conversationID
    private let forkID = UUID(uuidString: "ffffffff-1111-4111-8111-111111111111")!
    private let sourceSettings = AgentSettings(systemPrompt: "Session prompt", autoApprove: false,
                                               effort: "low", searchModel: "openai/session-search")

    private func snapshot(id: UUID, model: String = "openai/source", settings: AgentSettings,
                          disabled: [String] = ["shell"]) throws -> AgentJSON {
        guard case .object(var fields) = try AgentIntegrationTests.fixture(state: "completed", result: true),
              case .object(var configuration) = fields["configuration"],
              case .object(var metadata) = fields["metadata"] else {
            throw CheckFailure(description: "Expected fork fixture")
        }
        fields["id"] = .string(id.uuidString.lowercased())
        fields["model"] = .string(model)
        configuration["settings"] = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(settings))
        fields["configuration"] = .object(configuration)
        metadata["disabledTools"] = .array(disabled.map { .string($0) })
        fields["metadata"] = .object(metadata)
        return .object(fields)
    }
    private func makeLibrary(_ transport: ForkSnapshotTransport, source: AgentJSON,
                             preferences: UserDefaults) async throws -> ChatLibrary {
        let efforts = [ChatEffort(id: "low", name: "Low"), ChatEffort(id: "high", name: "High")]
        let models = ["openai/default", "openai/source", "openai/updated"].map {
            ChatModel(id: $0, name: $0, efforts: efforts)
        }
        preferences.set(try JSONEncoder().encode(models), forKey: "chat.modelCatalog")
        var config = AgentLibraryConfiguration()
        config.defaultModel = "openai/default"
        config.settings = AgentSettings(systemPrompt: "Settings prompt", autoApprove: true,
                                        effort: "high", searchModel: "openai/default-search")
        try await transport.responses.reply("/v1/library", try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(config)))
        try await transport.responses.reply("/v1/conversations", .array([source]))
        try await transport.responses.reply(AgentAPI.path(sourceID), source)
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        try await library.refreshSharedState()
        try library.current.apply(source.decoded(AgentSnapshot.self))
        return library
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
        try expect(store.contextUsage == expected.contextUsage && !store.needsInitialWorkspaceSelection)
        try expect(store.error == nil && !store.hasUnsavedChanges)
    }

    func forkPreservesReturnedSnapshotInsteadOfDefaults() async throws {
        let sourceSnapshot = try snapshot(id: sourceID, settings: sourceSettings, disabled: ["shell", "delegate"])
        let forkSnapshot = try snapshot(id: forkID, settings: sourceSettings, disabled: ["shell", "delegate"])
        let sourcePath = AgentAPI.path(sourceID), forkPath = AgentAPI.path(forkID)
        let transport = ForkSnapshotTransport(sourcePath: sourcePath, forkPath: forkPath, source: sourceSnapshot, fork: forkSnapshot)
        let suite = "exec-fork-snapshot-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = try await makeLibrary(transport, source: sourceSnapshot, preferences: preferences)
        defer { library.closePresentations() }
        let source = library.current
        source.draft = "Leave this unsent input in the source"
        library.forkConversation(source)
        await library.waitForNavigation()
        let fork = library.current
        try expect(fork !== source && library.error == nil)
        try expectSnapshot(fork, forkSnapshot)
        try expectSnapshot(source, sourceSnapshot)
        try expect(!fork.hasUnsentDraft && source.draft == "Leave this unsent input in the source")
        try expect(library.openConversations.contains { $0 === source })
        // A later normal save must not replace copied settings with Settings defaults.
        try await fork.saveIfIdle()
        let writes = await transport.responses.requests.filter { $0.method != "GET" && $0.path != "/v1/library" }
        try expect(writes.count == 1 && writes[0].method == "POST" && writes[0].path == sourcePath + "/fork")
    }

    func forkSavesPendingSourceConfigurationBeforeCopying() async throws {
        for scheduled in [false, true] {
            let initial = try snapshot(id: sourceID, settings: sourceSettings)
            var settings = sourceSettings
            settings.effort = "high"
            settings.systemPrompt = "Pending session prompt"
            settings.searchModel = "openai/pending-search"
            let disabled = scheduled ? ["shell", "delegate"] : ["shell"]
            let saved = try snapshot(id: sourceID, model: "openai/updated", settings: settings, disabled: disabled)
            let copied = try snapshot(id: forkID, model: "openai/updated", settings: settings, disabled: disabled)
            let sourcePath = AgentAPI.path(sourceID), forkPath = AgentAPI.path(forkID)
            let transport = ForkSnapshotTransport(sourcePath: sourcePath, forkPath: forkPath, source: initial, fork: copied)
            await transport.save(try snapshot(id: sourceID, model: "openai/updated", settings: sourceSettings), at: sourcePath + "/model")
            await transport.save(try snapshot(id: sourceID, model: "openai/updated", settings: settings), at: sourcePath + "/settings")
            if scheduled { await transport.save(saved, at: sourcePath) }
            let suite = "exec-fork-pending-\(UUID())"
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let library = try await makeLibrary(transport, source: initial, preferences: preferences)
            defer { library.closePresentations() }
            let source = library.current
            source.draft = "Keep the pending draft"
            source.selectedModel = "openai/updated"
            source.selectedEffort = settings.effort
            source.systemPrompt = settings.systemPrompt
            source.searchModel = settings.searchModel!
            if scheduled { source.setToolEnabled("delegate", false) }
            // Also cover direct model/effort edits with no scheduled save task to await.
            library.forkConversation(source)
            await library.waitForNavigation()
            try expect(library.current !== source && library.error == nil)
            try expectSnapshot(source, saved)
            try expectSnapshot(library.current, copied)
            try expect(source.draft == "Keep the pending draft" && !library.current.hasUnsentDraft)
            let writes = await transport.responses.requests.filter { $0.method != "GET" && $0.path != "/v1/library" }
            let expected = ["PUT " + sourcePath + "/model", "PUT " + sourcePath + "/settings"]
                + (scheduled ? ["PATCH " + sourcePath] : []) + ["POST " + sourcePath + "/fork"]
            try expect(writes.map { $0.method + " " + $0.path } == expected)
            let model = try JSONDecoder().decode(AgentJSON.self, from: writes[0].body!)
            try expect(model["model"].string == "openai/updated")
            try expect(try JSONDecoder().decode(AgentSettings.self, from: writes[1].body!) == settings)
            if scheduled {
                let tools = try JSONDecoder().decode(AgentJSON.self, from: writes[2].body!)
                try expect(Set(tools["disabledTools"].array.compactMap(\.string)) == Set(disabled))
            }
        }
    }

    func failedSourceSavePreventsForkWithoutRetrying() async throws {
        let initial = try snapshot(id: sourceID, settings: sourceSettings)
        let copied = try snapshot(id: forkID, settings: sourceSettings)
        let sourcePath = AgentAPI.path(sourceID)
        let transport = ForkSnapshotTransport(sourcePath: sourcePath, forkPath: AgentAPI.path(forkID), source: initial, fork: copied)
        let suite = "exec-fork-save-failure-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = try await makeLibrary(transport, source: initial, preferences: preferences)
        defer { library.closePresentations() }
        let source = library.current
        source.draft = "Do not discard this draft on failure"
        let messages = source.messages
        source.selectedEffort = "high"
        await transport.responses.failNext(sourcePath + "/settings")
        library.forkConversation(source)
        await library.waitForNavigation()
        try expect(library.current === source && source.hasUnsavedChanges && library.error != nil)
        try expect(source.messages == messages && source.draft == "Do not discard this draft on failure")
        library.forkConversation(source)
        await library.waitForNavigation()
        let writes = await transport.responses.requests.filter { $0.method != "GET" && $0.path != "/v1/library" }
        try expect(writes.count == 1 && writes[0].method == "PUT" && writes[0].path == sourcePath + "/settings")
    }
}
