import Foundation

/// Publish the next saved snapshot only when its write arrives, not while an observer
/// is still reading the previous policy. All I/O remains in the existing fake transport.
private actor SessionToolTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private var nextSnapshot: AgentJSON?
    func saveNext(_ snapshot: AgentJSON) { nextSnapshot = snapshot }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "POST" || method == "PATCH", let snapshot = nextSnapshot {
            nextSnapshot = nil
            try await responses.reply(path, snapshot)
            let id = try snapshot.decoded(AgentSnapshot.self).id
            try await responses.reply(AgentAPI.path(id), snapshot)
        }
        return try await responses.request(method, path, body: body)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
}

@MainActor struct SessionToolSelectionTests {
    private let names = ["list_files", "read_file", "search_text", "edit_file", "shell",
                         "web_search", "fetch_content", "generate_image", "take_screenshot", "delegate"]

    private func snapshot(disabled: [String]? = nil, state: String = "completed", child: Bool = false) throws -> AgentJSON {
        guard case .object(var fields) = try AgentIntegrationTests.fixture(state: state, result: state != "awaiting_approval"),
              case .object(var metadata) = fields["metadata"] else {
            throw CheckFailure(description: "Invalid session tool fixture")
        }
        if let disabled { metadata["disabledTools"] = .array(disabled.map { .string($0) }) }
        if child {
            metadata["parent"] = .object([
                "sessionId": .string(UUID().uuidString),
                "operationId": .string(AgentIntegrationTests.operationID.uuidString),
                "toolCallId": .string("delegate-call")])
        }
        fields["metadata"] = .object(metadata)
        return .object(fields)
    }

    private func disabledNames(in request: FakeAgentTransport.Request) throws -> Set<String> {
        guard let body = request.body else { throw CheckFailure(description: "Missing tool selection request body") }
        let value = try JSONDecoder().decode(AgentJSON.self, from: body)
        guard case .array(let entries) = value["disabledTools"] else {
            throw CheckFailure(description: "Tool selection must be an explicit array, including when empty")
        }
        let strings = entries.compactMap(\.string)
        try expect(strings.count == entries.count && Set(strings).count == strings.count)
        return Set(strings)
    }

    func defaultsAndAllToolNames() async throws {
        let transport = FakeAgentTransport()
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        let store = ChatStore(provider: provider)
        defer { store.closePresentation() }
        try expect(store.disabledTools.isEmpty && store.canSelectTools && !store.isSubagent)
        for name in names {
            store.setToolEnabled(name, false)
            await store.waitForPendingSave()
        }
        try expect(store.disabledTools == Set(names))
        for name in names {
            store.setToolEnabled(name, true)
            await store.waitForPendingSave()
        }
        try expect(store.disabledTools.isEmpty && store.autoApproveTools)
        let inherited = ChatStore(provider: provider, defaultAutoApproveTools: false, disabledTools: ["shell", "delegate"])
        defer { inherited.closePresentation() }
        try expect(inherited.disabledTools == ["shell", "delegate"] && !inherited.autoApproveTools)
        let requests = await transport.requests
        try expect(requests.isEmpty) // Local choices need neither a workspace nor a live connection.
    }

    func snapshotsReplaceSelectionAndSupportLegacyMetadata() throws {
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())), disabledTools: ["shell"])
        defer { store.closePresentation() }
        let legacy = try snapshot().decoded(AgentSnapshot.self)
        try expect(legacy.metadata.disabledTools == nil)
        try store.apply(legacy)
        try expect(store.disabledTools.isEmpty && store.canSelectTools)
        try store.apply(snapshot(disabled: names).decoded(AgentSnapshot.self))
        try expect(store.disabledTools == Set(names))
        try store.apply(snapshot(disabled: ["web_search"]).decoded(AgentSnapshot.self))
        try expect(store.disabledTools == ["web_search"])
        try store.apply(snapshot(disabled: []).decoded(AgentSnapshot.self))
        try expect(store.disabledTools.isEmpty)
        try store.apply(snapshot(disabled: ["shell"]).decoded(AgentSnapshot.self))
        try store.apply(legacy)
        try expect(store.disabledTools.isEmpty) // Missing metadata clears, rather than retaining stale policy.
    }

    func creationAndReenablePersistThroughNormalSave() async throws {
        let transport = SessionToolTransport()
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        let store = ChatStore(provider: provider, defaultAutoApproveTools: false, disabledTools: ["edit_file"])
        defer { store.closePresentation() }
        store.selectedModel = "deepseek/test"
        store.systemPrompt = "Keep this prompt"
        try store.setInitialWorkspace(Workspace(root: URL(fileURLWithPath: "/tmp")))
        let path = AgentAPI.path(AgentIntegrationTests.conversationID)
        let created = try snapshot(disabled: ["edit_file", "shell"])
        await transport.saveNext(created)
        store.setToolEnabled("shell", false)
        await store.waitForPendingSave()
        try expect(store.currentSessionID == AgentIntegrationTests.conversationID && !store.hasUnsavedChanges)
        try expect(store.disabledTools == ["edit_file", "shell"] && store.error == nil)
        var writes = await transport.responses.requests.filter { $0.method != "GET" }
        try expect(writes.count == 1)
        guard let create = writes.first else { throw CheckFailure(description: "Missing session creation") }
        try expect(create.method == "POST" && create.path == "/v1/conversations")
        try expect(try disabledNames(in: create) == ["edit_file", "shell"])

        // Replacement preserves other disabled tools; the last re-enable sends [], not omission.
        for disabled in [["edit_file"], []] as [[String]] {
            let saved = try snapshot(disabled: disabled)
            await transport.saveNext(saved)
            store.setToolEnabled(disabled.isEmpty ? "edit_file" : "shell", true)
            await store.waitForPendingSave()
            try expect(store.disabledTools == Set(disabled) && !store.hasUnsavedChanges && store.error == nil)
            writes = await transport.responses.requests.filter { $0.method != "GET" }
            guard let patch = writes.last else { throw CheckFailure(description: "Missing selection update") }
            try expect(patch.method == "PATCH" && patch.path == path)
            try expect(try disabledNames(in: patch) == Set(disabled))
            let reopened = ChatStore(provider: provider, disabledTools: ["delegate"])
            defer { reopened.closePresentation() }
            try reopened.apply(saved.decoded(AgentSnapshot.self))
            try expect(reopened.disabledTools == Set(disabled))
        }
        try expect(writes.count == 3 && !store.autoApproveTools)
    }

    func busySessionsAndChildrenCannotToggle() async throws {
        for (state, child) in [("running", false), ("awaiting_approval", false), ("cancelling", false),
                               ("completed", true), ("running", true)] {
            let transport = FakeAgentTransport()
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            try store.apply(snapshot(disabled: ["shell"], state: state, child: child).decoded(AgentSnapshot.self))
            try expect(store.isSubagent == child && !store.canSelectTools)
            store.setToolEnabled("shell", true)
            store.setToolEnabled("web_search", false)
            await store.waitForPendingSave()
            try expect(store.disabledTools == ["shell"])
            if !child {
                try store.apply(snapshot(disabled: ["shell"]).decoded(AgentSnapshot.self))
                try expect(store.canSelectTools)
                await store.waitForPendingSave()
                await Task.yield()
                try expect(store.disabledTools == ["shell"]) // Rejected toggles must not queue until idle.
            }
            let writes = await transport.requests.filter { $0.method != "GET" }
            try expect(writes.isEmpty)
        }
    }

    func newConversationsResetSelectionWithoutChangingSource() async throws {
        let transport = FakeAgentTransport()
        let suite = "exec-session-tools-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        let source = library.current
        try source.apply(snapshot(disabled: ["shell", "delegate"]).decoded(AgentSnapshot.self))
        source.draft = "Keep this source draft"
        library.newConversation()
        let next = library.current
        await source.waitForPendingSave()
        await next.waitForPendingSave()
        try expect(library.current === next && next !== source && next.disabledTools.isEmpty && next.canSelectTools)
        next.setToolEnabled("read_file", false)
        await next.waitForPendingSave()
        try expect(next.disabledTools == ["read_file"] && source.disabledTools == ["shell", "delegate"])
        library.newConversation()
        await library.current.waitForPendingSave()
        try expect(library.current !== next && library.current.disabledTools.isEmpty)
        try expect(next.disabledTools == ["read_file"] && source.disabledTools == ["shell", "delegate"])
        try expect(source.workspace?.root.path == "/tmp" && source.currentSessionID == AgentIntegrationTests.conversationID)
        try expect(source.draft == "Keep this source draft" && source.error == nil && library.error == nil)
        try expect(library.openConversations.contains { $0 === source })
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.isEmpty)
    }
}
