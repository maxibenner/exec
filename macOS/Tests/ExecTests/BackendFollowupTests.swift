import Foundation

@MainActor struct BackendFollowupTests {
    private func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out awaiting follow-up state")
    }
    private func snapshotJSON(_ state: String, model: String = "openai/test", auto: Bool = false) throws -> AgentJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try encoder.encode(AgentIntegrationTests.fixture(state: state, result: state != "running"))
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "deepseek/test", with: model)
            .replacingOccurrences(of: "\"autoApprove\":false", with: "\"autoApprove\":\(auto)")
        return try JSONDecoder().decode(AgentJSON.self, from: Data(text.utf8))
    }
    private func snapshot(_ state: String, model: String = "openai/test", auto: Bool = false) throws -> AgentSnapshot {
        try snapshotJSON(state, model: model, auto: auto).decoded(AgentSnapshot.self)
    }
    func localDraftSurvivesNavigationAndUncertainCreate() async throws {
        for fail in [false, true] {
            let transport = FakeAgentTransport()
            let suite = "exec-draft-navigation-\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
            defer { library.closePresentations() }
            try library.current.setInitialWorkspace(Workspace(root: URL(fileURLWithPath: "/tmp")))
            library.newConversation()
            let source = library.current
            await source.waitForPendingSave()
            source.selectedModel = "openai/test"
            source.draft = "Keep this unsubmitted draft"
            let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
            try await transport.reply("/v1/library", config)
            try await transport.reply("/v1/conversations", snapshotJSON("completed"))
            if fail { await transport.fail("/v1/conversations") }
            library.newConversation()
            if fail {
                try await wait { library.current === source && source.hasUnsavedChanges }
                library.newConversation()
                try await wait { library.current === source }
            } else {
                try await wait { source.currentSessionID != nil && !source.isSaving }
                try expect(library.current !== source && library.openConversations.contains { $0 === source })
                library.openSession(source.currentSessionID!)
                try expect(library.current === source)
            }
            try expect(source.draft == "Keep this unsubmitted draft")
            let creates = await transport.requests.filter { $0.method == "POST" && $0.path == "/v1/conversations" }
            try expect(creates.count == 1)
        }
    }

    func remoteDeletionReconcilesAndPreservesLocalDraft() async throws {
        for draft in ["", "Keep this local draft"] {
            let transport = FakeAgentTransport()
            let suite = "exec-remote-deletion-\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
            defer { library.closePresentations() }
            let prior = library.current
            try prior.apply(snapshot("completed"))
            prior.draft = draft
            let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
            try await transport.reply("/v1/library", config)
            try await transport.reply("/v1/conversations", .array([]))
            try await library.refreshSharedState()
            try expect(prior.deletedRemotely && prior.messages.isEmpty && !prior.canFork && !prior.canRequestCommands)
            if draft.isEmpty {
                try expect(library.current !== prior && library.sessionList.isEmpty)
            } else {
                try expect(library.current === prior && prior.draft == draft && prior.summary?.title == "Unsent draft")
                prior.send()
                await Task.yield()
                let writes = await transport.requests.filter { $0.method != "GET" }
                try expect(writes.isEmpty)
            }
        }
    }

    func inheritedWorkspaceCanBeChosenExactlyOnce() async throws {
        let transport = FakeAgentTransport()
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        let suite = "exec-workspace-choice-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: provider, preferences: preferences)
        defer { library.closePresentations() }
        try library.current.apply(snapshot("completed"))
        let previous = library.current
        library.newConversation()
        let inherited = library.current
        await inherited.waitForPendingSave()
        try expect(inherited !== previous && inherited.workspace?.root == previous.workspace?.root)
        inherited.selectedModel = "openai/test"
        try await transport.reply("/v1/conversations", snapshotJSON("completed"))
        let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
        try await transport.reply("/v1/library", config)
        inherited.scheduleSave()
        await inherited.waitForPendingSave()
        try expect(!inherited.canSelectWorkspace && inherited.currentSessionID != nil)
        try expect(library.sidebarSessions.contains { $0.id == inherited.currentSessionID })
        try expect(inherited.draft.isEmpty)
        try expectFailure { try inherited.setInitialWorkspace(Workspace(root: URL(fileURLWithPath: "/tmp/another"))) }
        try expect(previous.workspace?.root.path == "/tmp")

        // Sending directly in the inherited folder starts the immutable backend session.
        try await transport.reply("/v1/providers", .array([.object(["id": .string("openai"), "name": .string("OpenAI"), "connected": .bool(true)])]))
        try await provider.refreshConnections()
        let store = ChatStore(provider: provider, workspace: Workspace(root: URL(fileURLWithPath: "/tmp")), defaultAutoApproveTools: false)
        defer { store.closePresentation() }
        store.systemPrompt = "Keep this prompt"
        store.installModels([ChatModel(id: "openai/test", name: "Test")])
        let terminal = try snapshotJSON("completed")
        try await transport.reply("/v1/conversations", terminal)
        try await transport.reply(AgentAPI.path(AgentIntegrationTests.conversationID), terminal)
        store.draft = "Test"
        try expect(store.canSelectWorkspace)
        store.send()
        await store.waitUntilIdle()
        try expect(store.currentSessionID != nil && !store.canSelectWorkspace)
        let creates = await transport.requests.filter { $0.method == "POST" && $0.path == "/v1/conversations" }
        try expect(creates.count == 2)
    }

    func usageRefreshesOnlyOnSettingsRequest() async throws {
        let transport = FakeAgentTransport()
        let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
        try await transport.reply("/v1/library", config)
        try await transport.reply("/v1/providers", .array([.object(["id": .string("openai"), "name": .string("OpenAI"), "connected": .bool(true)])]))
        let suite = "exec-usage-settings-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        try await library.restore()
        try library.current.apply(snapshot("running"))
        try library.current.apply(snapshot("completed"))
        for _ in 0..<20 { await Task.yield() }
        let before = await transport.requests
        try expect(!before.contains { $0.path.hasSuffix("/usage") })
        try await transport.reply("/v1/providers/openai/usage", .object([
            "fetchedAt": .number(Date().timeIntervalSince1970 * 1000),
            "windows": .array([.object(["durationSeconds": .number(18000), "usedPercent": .number(25), "resetsAt": .number(Date().timeIntervalSince1970 + 3600)])])]))
        library.refreshAccountUsage()
        try await wait { library.displayedAccountUsage != nil }
        let after = await transport.requests.filter { $0.path.hasSuffix("/usage") }
        try expect(after.count == 1)
    }

    func commandsWaitForIdleAndPreserveApprovals() async throws {
        let transport = FakeAgentTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try store.apply(snapshot("running"))
        let oldApproval = store.tools.pendingApproval?.id
        store.selectedModel = "openai/next"
        store.scheduleSave()
        store.setAutoApproveTools(true)
        var actions: [String] = []
        store.whenIdle("fork") { actions.append("stale fork") }
        store.whenIdle("fork") { actions.append("fork") }
        store.whenIdle("workspace") { actions.append("workspace") }
        for _ in 0..<5 { await Task.yield() }
        let before = await transport.requests
        try expect(before.isEmpty && actions.isEmpty && store.tools.pendingApproval?.id == oldApproval)
        try expect(store.canCompact && store.canRequestFork && !store.canFork)
        let terminal = try snapshot("completed")
        let desired = try snapshot("completed", model: "openai/next", auto: true)
        let value = try snapshotJSON("completed", model: "openai/next", auto: true)
        try await transport.reply(AgentAPI.path(terminal.id, "/model"), value)
        try await transport.reply(AgentAPI.path(terminal.id, "/settings"), value)
        try store.apply(terminal)
        try await wait { !store.busy }
        try expect(actions == ["fork", "workspace"] && store.selectedModel == "openai/next" && store.autoApproveTools)
        let requests = await transport.requests
        try expect(requests.filter { $0.path.hasSuffix("/model") }.count == 1)
        try expect(requests.allSatisfy { !$0.path.hasSuffix("/approvals") })
        // Terminal snapshots do not run the queue twice; shutdown must discard queued effects.
        try store.apply(desired)
        try store.apply(snapshot("running"))
        store.whenIdle("fork") { actions.append("must not run") }
        store.cancelPendingCommands()
        try store.apply(desired)
        for _ in 0..<5 { await Task.yield() }
        try expect(actions == ["fork", "workspace"])
    }

    func compactQueuesOnceAndConfigurationFailureStopsActions() async throws {
        let transport = FakeAgentTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        let terminal = try snapshot("completed")
        let terminalJSON = try snapshotJSON("completed")
        try await transport.reply(AgentAPI.path(terminal.id), terminalJSON)
        try store.apply(snapshot("running"))
        store.compact(); store.compact()
        let before = await transport.requests
        try expect(before.isEmpty)
        try store.apply(terminal)
        try await wait { !store.busy }
        let compactions = await transport.requests.filter { $0.path.hasSuffix("/compact") }
        try expect(compactions.count == 1)
        try store.apply(snapshot("running"))
        store.setAutoApproveTools(true)
        await transport.fail(AgentAPI.path(terminal.id, "/settings"))
        var ran = false
        store.whenIdle("fork") { ran = true }
        try store.apply(terminal)
        try await wait { !store.busy }
        try expect(store.hasUnsavedChanges && !ran)
        try store.apply(terminal)
        for _ in 0..<5 { await Task.yield() }
        let writes = await transport.requests.filter { $0.path.hasSuffix("/settings") }
        try expect(writes.count == 1 && !ran)
    }

    func desktopRequiresExplicitGrantAndDiscardsCancelledCapture() async throws {
        let transport = ControlledAgentTransport()
        let api = AgentAPI(transport: transport)
        let frontend = "11111111-2222-4333-8444-555555555555"
        let conversation = AgentIntegrationTests.conversationID
        var permission = false, permissionRequests = 0, captureCount = 0
        var finish: CheckedContinuation<ScreenshotTool.Output, Never>?
        let desktop = AgentDesktop(api: api, preflight: { permission }, requestPermission: {
            permissionRequests += 1; permission = true; return true
        }, capture: { request in
            captureCount += 1
            return await withCheckedContinuation { finish = $0 }
        })
        defer { desktop.stop() }
        try transport.emit(.object(["type": .string("registered"), "frontendID": .string(frontend)]))
        try await desktop.start()
        try expect(permissionRequests == 0 && desktop.enabled.isEmpty)
        try await desktop.setEnabled(true, for: conversation)
        try expect(permissionRequests == 1 && desktop.enabled.contains(conversation))
        let request = AgentJSON.object([
            "id": .string("capture-one"), "frontendID": .string(frontend),
            "conversationID": .string(conversation.uuidString.lowercased()),
            "operationID": .string(AgentIntegrationTests.operationID.uuidString.lowercased()), "callID": .string("call"),
            "action": .object(["target": .string("list_windows"), "windowID": .null])])
        try transport.emit(.object(["type": .string("request"), "request": request]))
        try await wait { finish != nil }
        try transport.emit(.object(["type": .string("cancelled"), "request": request]))
        for _ in 0..<20 { await Task.yield() }
        finish?.resume(returning: .init(text: "Private title", windows: [.init(id: 1, title: "Private title")]))
        finish = nil
        for _ in 0..<20 { await Task.yield() }
        let replies = await transport.requests.requests.filter { $0.path == "/v1/native/results" }
        try expect(captureCount == 1 && replies.isEmpty)
        permission = false
        try transport.emit(.object(["type": .string("ping")]))
        try await wait { desktop.enabled.isEmpty }
        permission = true
        try transport.emit(.object(["type": .string("ping")]))
        for _ in 0..<20 { await Task.yield() }
        try expect(desktop.enabled.isEmpty) // OS restoration is not a renewed session grant.
        transport.channel.continuation.finish(throwing: ExecError("Disconnected"))
        try await wait { desktop.frontendID == nil }
    }

    func desktopRepliesExactlyOnceWithoutRetry() async throws {
        let transport = ControlledAgentTransport()
        let api = AgentAPI(transport: transport)
        let desktop = AgentDesktop(api: api, preflight: { true }, requestPermission: { false }, capture: { _ in
            .init(text: "Untrusted titles", windows: [.init(id: 42, title: "Window")])
        })
        defer { desktop.stop() }
        let frontend = UUID().uuidString.lowercased()
        try transport.emit(.object(["type": .string("registered"), "frontendID": .string(frontend)]))
        try await desktop.start()
        try await desktop.setEnabled(true, for: AgentIntegrationTests.conversationID)
        await transport.requests.fail("/v1/native/results")
        let request = AgentJSON.object(["id": .string("one"), "frontendID": .string(frontend),
            "conversationID": .string(AgentIntegrationTests.conversationID.uuidString.lowercased()),
            "operationID": .string("operation"), "callID": .string("call"),
            "action": .object(["target": .string("list_windows")])])
        try transport.emit(.object(["type": .string("request"), "request": request]))
        for _ in 0..<100 {
            if await transport.requests.requests.contains(where: { $0.path == "/v1/native/results" }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let replies = await transport.requests.requests.filter { $0.path == "/v1/native/results" }
        try expect(replies.count == 1)
        let body = try JSONDecoder().decode(AgentJSON.self, from: replies[0].body!)
        try expect(body["request"] == request && body["result"]["type"].string == "windows")
        try expect(body["result"]["windows"].array.first?["id"].number == 42)
        try await desktop.setEnabled(false, for: AgentIntegrationTests.conversationID)
        try expect(desktop.enabled.isEmpty)
    }
}
