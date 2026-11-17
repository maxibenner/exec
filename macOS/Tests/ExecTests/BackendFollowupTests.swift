import AppKit
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
            let source = library.current
            await source.waitForPendingSave()
            try source.setInitialWorkspace(Workspace(root: URL(fileURLWithPath: "/tmp")))
            source.selectedModel = "openai/test"
            source.draft = "Keep this unsubmitted draft"
            let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
            try await transport.reply("/v1/library", config)
            try await transport.reply("/v1/conversations", snapshotJSON("completed"))
            if fail { await transport.fail("/v1/conversations") }
            let destinationID = UUID()
            guard case .object(var destinationFields) = try snapshotJSON("completed") else {
                throw CheckFailure(description: "Expected destination snapshot")
            }
            destinationFields["id"] = .string(destinationID.uuidString)
            try await transport.reply(AgentAPI.path(destinationID), .object(destinationFields))
            library.openSession(destinationID)
            if fail {
                try await wait { library.current === source && source.hasUnsavedChanges }
                library.openSession(destinationID)
                await library.waitForNavigation()
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

    func freshSessionsUseSettingsDefaultsAndRequestWorkspace() async throws {
        let transport = FakeAgentTransport()
        let suite = "exec-fresh-session-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let models = [
            ChatModel(id: "openai/test", name: "Source", efforts: [ChatEffort(id: "low", name: "Low")]),
            ChatModel(id: "openai/default", name: "Default", efforts: [ChatEffort(id: "high", name: "High")])
        ]
        preferences.set(try JSONEncoder().encode(models), forKey: "chat.modelCatalog")
        var config = AgentLibraryConfiguration()
        config.defaultModel = "openai/default"
        config.settings = AgentSettings(systemPrompt: "Settings prompt", autoApprove: false,
                                        effort: "high", searchModel: "openai/default-search")
        try await transport.reply("/v1/library", try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(config)))
        guard case .object(var fields) = try snapshotJSON("completed"),
              case .object(var configuration) = fields["configuration"],
              case .object(var metadata) = fields["metadata"] else {
            throw CheckFailure(description: "Expected source snapshot")
        }
        configuration["settings"] = .object([
            "systemPrompt": .string("Source prompt"), "autoApprove": .bool(true),
            "effort": .string("low"), "searchModel": .string("openai/source-search")])
        metadata["disabledTools"] = .array([.string("shell"), .string("delegate")])
        fields["configuration"] = .object(configuration)
        fields["metadata"] = .object(metadata)
        let saved = AgentJSON.object(fields)
        try await transport.reply("/v1/conversations", .array([saved]))
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        try await library.refreshSharedState()
        let source = library.current
        try source.apply(saved.decoded(AgentSnapshot.self))
        source.draft = "Keep this unsubmitted draft"
        let messages = source.messages
        let sourceID = source.currentSessionID

        for _ in 0..<2 {
            let previous = library.current
            library.newConversation()
            let fresh = library.pendingNewConversation!
            await fresh.waitForPendingSave()
            try expect(library.current === previous && fresh !== source)
            try expect(fresh.currentSessionID == nil && fresh.workspace == nil)
            try expect(fresh.needsInitialWorkspaceSelection && fresh.canSelectWorkspace)
            try expect(fresh.selectedModel == config.defaultModel && fresh.selectedEffort == config.settings.effort)
            try expect(fresh.systemPrompt == config.settings.systemPrompt && fresh.searchModel == config.settings.searchModel)
            try expect(!fresh.autoApproveTools && fresh.disabledTools.isEmpty)
            try expect(fresh.messages.isEmpty && fresh.contextUsage == nil && !fresh.hasUnsentDraft)
            // Each fresh session presents its own picker once, only in its owning window.
            let window = NSWindow()
            var pickerWindows: [NSWindow] = []
            var pickerDirectories: [URL?] = []
            let panel = ChatPanel(library: library, conversation: source) { owner, directory, completion in
                pickerWindows.append(owner); pickerDirectories.append(directory)
                completion(nil)
            }
            panel.chooseInitialWorkspaceIfNeeded()
            try expect(pickerWindows.isEmpty && fresh.needsInitialWorkspaceSelection)
            panel.window = window
            panel.chooseInitialWorkspaceIfNeeded()
            panel.chooseInitialWorkspaceIfNeeded()
            try expect(pickerWindows.count == 1 && pickerWindows[0] === window && pickerDirectories[0] == nil)
            try expect(library.current === source && library.pendingNewConversation == nil)
            // Dismissing the picker, even followed by a forced save, must not create a session.
            try await fresh.saveIfIdle(force: true)
            try expect(!fresh.needsInitialWorkspaceSelection && fresh.currentSessionID == nil && fresh.workspace == nil)
            try expect(library.sidebarSessions.map(\.id) == [sourceID!])
            try expect(library.openConversations.contains { $0 === source })
            try expect(source.currentSessionID == sourceID && source.workspace?.root.path == "/tmp")
            try expect(source.messages == messages && source.draft == "Keep this unsubmitted draft")
            try expect(source.selectedModel == "openai/test" && source.selectedEffort == "low")
            try expect(source.systemPrompt == "Source prompt" && source.searchModel == "openai/source-search")
            try expect(source.autoApproveTools && source.disabledTools == ["shell", "delegate"])
            try expect(source.error == nil && fresh.error == nil && library.error == nil)
        }
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.isEmpty)
    }

    func modelCatalogSurvivesLaunchAndRefreshes() async throws {
        let transport = FakeAgentTransport()
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        let suite = "exec-model-cache-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        try await transport.reply("/v1/providers", .array([.object([
            "id": .string("openai"), "name": .string("OpenAI"), "connected": .bool(true)
        ])]))
        try await provider.refreshConnections()
        let model = ChatModel(id: "openai/test", name: "Previous model", contextWindow: 100000,
                              efforts: [ChatEffort(id: "high", name: "High")], defaultEffort: "high", acceptsImages: true)
        try await transport.reply("/v1/models", .array([try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(model))]))
        let first = ChatLibrary(provider: provider, preferences: preferences)
        defer { first.closePresentations() }
        first.refreshModels()
        try await wait { first.models == [model] }

        let relaunched = ChatLibrary(provider: provider, preferences: preferences)
        defer { relaunched.closePresentations() }
        try relaunched.current.apply(snapshot("completed"))
        let panel = ChatPanel(library: relaunched, conversation: relaunched.current)
        try expect(panel.selectedModel == model.id && panel.models == [model])
        try expect(panel.modelUnavailableReason == nil && relaunched.current.model == model)

        // A failed discovery is not evidence that the selected model disappeared.
        await transport.fail("/v1/models")
        relaunched.refreshModels()
        try await wait { relaunched.error != nil }
        try expect(panel.selectedModel == model.id && panel.modelUnavailableReason == nil)

        // A successful empty catalog, unlike a failed request, is authoritative.
        let refreshedTransport = FakeAgentTransport()
        let refreshedProvider = AgentAccounts(api: AgentAPI(transport: refreshedTransport))
        try await refreshedTransport.reply("/v1/providers", .array([.object([
            "id": .string("openai"), "name": .string("OpenAI"), "connected": .bool(true)
        ])]))
        try await refreshedProvider.refreshConnections()
        try await refreshedTransport.reply("/v1/models", .array([]))
        let refreshed = ChatLibrary(provider: refreshedProvider, preferences: preferences)
        defer { refreshed.closePresentations() }
        try refreshed.current.apply(snapshot("completed"))
        let refreshedPanel = ChatPanel(library: refreshed, conversation: refreshed.current)
        refreshed.refreshModels()
        try await wait { refreshed.models.isEmpty }
        try expect(refreshed.current.selectedModel == model.id)
        try expect(refreshedPanel.selectedModel.isEmpty && refreshedPanel.modelUnavailableReason == "Model unavailable")
        let nextLaunch = ChatLibrary(provider: refreshedProvider, preferences: preferences)
        defer { nextLaunch.closePresentations() }
        try expect(nextLaunch.models.isEmpty)

        // Account restoration invalidates cached models from disconnected providers.
        // Use a fresh cache from the first successful fetch, without account data.
        preferences.set(try JSONEncoder().encode([model]), forKey: "chat.modelCatalog")
        let signedOutTransport = FakeAgentTransport()
        try await signedOutTransport.reply("/v1/providers", .array([]))
        try await signedOutTransport.reply("/v1/library", try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration())))
        try await signedOutTransport.reply("/v1/conversations", .array([]))
        let signedOut = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: signedOutTransport)), preferences: preferences)
        defer { signedOut.closePresentations() }
        try expect(signedOut.models == [model])
        try await signedOut.restore()
        try expect(signedOut.models.isEmpty && signedOut.current.models.isEmpty)
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

        // Both types of report are available synchronously after relaunch.
        try await transport.reply("/v1/providers", .array([
            .object(["id": .string("openai"), "name": .string("OpenAI"), "connected": .bool(true)]),
            .object(["id": .string("deepseek"), "name": .string("DeepSeek"), "connected": .bool(true)])]))
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        try await provider.refreshConnections()
        let relaunched = ChatLibrary(provider: provider, preferences: preferences)
        defer { relaunched.closePresentations() }
        try expect(relaunched.displayedAccountUsage == library.displayedAccountUsage)
        try expect(relaunched.accountUsageFetchedAt == library.accountUsageFetchedAt)
        try await transport.reply("/v1/providers/deepseek/balance", .array([
            .object(["amount": .string("12.50"), "currency": .string("USD")])]))
        await relaunched.refreshAccountBalance(for: "deepseek")
        let nextLaunch = ChatLibrary(provider: provider, preferences: preferences)
        defer { nextLaunch.closePresentations() }
        try expect(nextLaunch.accountBalance(for: "deepseek") == [AccountBalance(amount: Decimal(string: "12.50")!, currency: "USD")])

        // Refreshing keeps the previous value until a new report arrives.
        try await transport.reply("/v1/providers/openai/usage", .object([
            "fetchedAt": .number(Date().timeIntervalSince1970 * 1000),
            "windows": .array([.object(["durationSeconds": .number(18000), "usedPercent": .number(40), "resetsAt": .number(Date().timeIntervalSince1970 + 3600)])])]))
        nextLaunch.refreshAccountUsage()
        try expect(nextLaunch.displayedAccountUsage?.windows.first?.usedPercent == 25)
        try await wait { nextLaunch.displayedAccountUsage?.windows.first?.usedPercent == 40 }
        await transport.fail("/v1/providers/deepseek/balance")
        await nextLaunch.refreshAccountBalance(for: "deepseek")
        try expect(nextLaunch.accountBalance(for: "deepseek") == relaunched.accountBalance(for: "deepseek"))

        // Never show a cached report for a disconnected or different account.
        try await transport.reply("/v1/providers", .array([
            .object(["id": .string("openai"), "name": .string("OpenAI"), "connected": .bool(true), "email": .string("other@example.test")]),
            .object(["id": .string("deepseek"), "name": .string("DeepSeek"), "connected": .bool(false)])]))
        try await provider.refreshConnections()
        try expect(nextLaunch.displayedAccountUsage == nil && nextLaunch.accountUsage == nil)
        try expect(nextLaunch.accountBalance(for: "deepseek").isEmpty)
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
        try expect(store.canCompact && store.canRequestFork && store.canFork)
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

    func desktopRequestsOSPermissionOnUseAndDiscardsCancelledCapture() async throws {
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
        try expect(permissionRequests == 0 && desktop.enabled.contains(conversation))
        let request = AgentJSON.object([
            "id": .string("capture-one"), "frontendID": .string(frontend),
            "conversationID": .string(conversation.uuidString.lowercased()),
            "operationID": .string(AgentIntegrationTests.operationID.uuidString.lowercased()), "callID": .string("call"),
            "action": .object(["target": .string("list_windows"), "windowID": .null])])
        try transport.emit(.object(["type": .string("request"), "request": request]))
        try await wait { finish != nil }
        try expect(permissionRequests == 1)
        try transport.emit(.object(["type": .string("cancelled"), "request": request]))
        for _ in 0..<20 { await Task.yield() }
        finish?.resume(returning: .init(text: "Private title", windows: [.init(id: 1, title: "Private title")]))
        finish = nil
        for _ in 0..<20 { await Task.yield() }
        let replies = await transport.requests.requests.filter { $0.path == "/v1/native/results" }
        try expect(captureCount == 1 && replies.isEmpty)
        permission = false
        try transport.emit(.object(["type": .string("ping")]))
        for _ in 0..<20 { await Task.yield() }
        try expect(desktop.enabled.contains(conversation))
        permission = true
        try transport.emit(.object(["type": .string("ping")]))
        for _ in 0..<20 { await Task.yield() }
        try expect(desktop.enabled.contains(conversation)) // Adapter binding is not screen consent.
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
