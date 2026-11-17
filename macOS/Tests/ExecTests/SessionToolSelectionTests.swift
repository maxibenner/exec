import Foundation

/// Publish the next saved snapshot only when its write arrives, not while an observer
/// is still reading the previous policy. All I/O remains in the existing fake transport.
private actor SessionToolTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private var nextSnapshot: AgentJSON?
    private var pauseNextSave = false
    private var heldSave: CheckedContinuation<Void, Never>?
    var isSavePaused: Bool { heldSave != nil }
    func saveNext(_ snapshot: AgentJSON, pause: Bool = false) {
        nextSnapshot = snapshot
        pauseNextSave = pause
    }
    func resumeSave() { heldSave?.resume(); heldSave = nil }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "POST" || method == "PATCH", let snapshot = nextSnapshot {
            nextSnapshot = nil
            let pause = pauseNextSave
            pauseNextSave = false
            try await responses.reply(path, snapshot)
            let id = try snapshot.decoded(AgentSnapshot.self).id
            try await responses.reply(AgentAPI.path(id), snapshot)
            let data = try await responses.request(method, path, body: body)
            if pause { await withCheckedContinuation { heldSave = $0 } }
            return data
        }
        return try await responses.request(method, path, body: body)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
}

@MainActor struct SessionToolSelectionTests {
    private let names = SessionTool.names

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
            // A snapshot reconciliation can hand the save to the idle command drain.
            try await waitForSave(store)
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

    private func waitForSave(_ store: ChatStore) async throws {
        for _ in 0..<200 {
            if !store.busy && !store.isSaving { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out saving tool selection")
    }

    func activeSelectionsReconcileAtIdle() async throws {
        for (active, terminal) in [("running", "completed"), ("awaiting_approval", "interrupted"), ("cancelling", "failed")] {
            let transport = SessionToolTransport()
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            let initial = try snapshot(disabled: ["shell"], state: active).decoded(AgentSnapshot.self)
            try store.apply(initial)
            let approval = store.tools.pendingApproval?.id
            try expect(store.canSelectTools)
            store.setToolEnabled("shell", true)
            store.setToolEnabled("web_search", false)
            store.setToolEnabled("shell", false) // Reconciles to disabled, not two queued mutations.
            store.setToolEnabled("read_file", false)
            store.setToolEnabled("read_file", true)
            try expect(store.disabledTools == ["shell", "web_search"] && store.canSelectTools)
            try expect(!store.hasUnsavedChanges && !store.isSaving && store.error == nil)
            try store.apply(initial) // Streaming/approval snapshots must not overwrite the selection.
            await store.waitForPendingSave()
            let before = await transport.responses.requests
            try expect(before.isEmpty && store.disabledTools == ["shell", "web_search"])
            try expect(store.tools.pendingApproval?.id == approval)

            let saved = try snapshot(disabled: ["shell", "web_search"], state: terminal)
            await transport.saveNext(saved)
            var commandSawSelection = false
            store.whenIdle("after-selection") {
                let writes = await transport.responses.requests.filter { $0.method == "PATCH" }
                if writes.count == 1 {
                    commandSawSelection = try self.disabledNames(in: writes[0]) == ["shell", "web_search"]
                }
            }
            try store.apply(snapshot(disabled: ["shell"], state: terminal).decoded(AgentSnapshot.self))
            try await waitForSave(store)
            let writes = await transport.responses.requests.filter { $0.method != "GET" }
            try expect(writes.count == 1 && commandSawSelection)
            try expect(writes[0].method == "PATCH" && writes[0].path == AgentAPI.path(initial.id))
            try expect(try disabledNames(in: writes[0]) == ["shell", "web_search"])
            try expect(store.disabledTools == ["shell", "web_search"] && !store.hasUnsavedChanges && store.error == nil)
        }
    }

    func netUnchangedSelectionDoesNotWrite() async throws {
        let transport = FakeAgentTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try store.apply(snapshot(disabled: ["shell"], state: "running").decoded(AgentSnapshot.self))
        store.setToolEnabled("shell", true)
        store.setToolEnabled("shell", false)
        store.setToolEnabled("read_file", false)
        store.setToolEnabled("read_file", true)
        let terminal = try snapshot(disabled: ["shell"])
        try await transport.reply(AgentAPI.path(AgentIntegrationTests.conversationID), terminal)
        try store.apply(terminal.decoded(AgentSnapshot.self))
        try await waitForSave(store)
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.isEmpty && store.disabledTools == ["shell"] && store.error == nil)
    }

    func selectionsDuringSaveKeepLatestChoice() async throws {
        let transport = SessionToolTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try store.apply(snapshot().decoded(AgentSnapshot.self))
        await transport.saveNext(try snapshot(disabled: ["shell"]), pause: true)
        store.setToolEnabled("shell", false)
        for _ in 0..<200 {
            if await transport.isSavePaused { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let paused = await transport.isSavePaused
        let selectableWhileSaving = store.isSaving && store.canSelectTools
        store.setToolEnabled("web_search", false)
        store.setToolEnabled("shell", true)
        store.setToolEnabled("read_file", false)
        store.setToolEnabled("read_file", true)
        await transport.saveNext(try snapshot(disabled: ["web_search"]))
        await transport.resumeSave()
        await store.waitForPendingSave()
        try expect(paused && selectableWhileSaving)
        let writes = await transport.responses.requests.filter { $0.method != "GET" }
        try expect(writes.count == 2)
        try expect(try disabledNames(in: writes[0]) == ["shell"])
        try expect(try disabledNames(in: writes[1]) == ["web_search"])
        try expect(store.disabledTools == ["web_search"] && store.error == nil && !store.hasUnsavedChanges)
    }

    func failedSelectionSaveIsNotRetried() async throws {
        let transport = FakeAgentTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try store.apply(snapshot(state: "running").decoded(AgentSnapshot.self))
        store.setToolEnabled("shell", false)
        await transport.fail(AgentAPI.path(AgentIntegrationTests.conversationID))
        let terminal = try snapshot().decoded(AgentSnapshot.self)
        try store.apply(terminal)
        try await waitForSave(store)
        try expect(store.hasUnsavedChanges && !store.canSelectTools && store.error != nil)
        try store.apply(terminal)
        store.setToolEnabled("read_file", false)
        for _ in 0..<5 { await Task.yield() }
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.count == 1 && store.disabledTools == ["shell"])
    }

    func childrenCannotToggle() async throws {
        for state in ["completed", "running"] {
            let transport = FakeAgentTransport()
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            try store.apply(snapshot(disabled: ["shell"], state: state, child: true).decoded(AgentSnapshot.self))
            try expect(store.isSubagent && !store.canSelectTools)
            store.setToolEnabled("shell", true)
            store.setToolEnabled("web_search", false)
            await store.waitForPendingSave()
            try expect(store.disabledTools == ["shell"])
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
