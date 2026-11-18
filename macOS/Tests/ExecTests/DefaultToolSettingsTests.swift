import Foundation

@MainActor struct DefaultToolSettingsTests {
    private func configuration(_ disabled: [String]? = nil) throws -> AgentJSON {
        var config = AgentLibraryConfiguration()
        config.defaultDisabledTools = disabled ?? ["shell"]
        let encoded = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(config))
        guard case .object(var fields) = encoded else { throw CheckFailure(description: "Invalid library fixture") }
        if disabled == nil { fields.removeValue(forKey: "defaultDisabledTools") }
        return .object(fields)
    }

    private func waitForDefaults(_ library: ChatLibrary) async throws {
        for _ in 0..<200 {
            if !library.accountBusy {
                try expect(library.error == nil)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out saving default tools")
    }

    func initialAndLegacyDefaultsDisableShell() async throws {
        let transport = FakeAgentTransport()
        let suite = "exec-default-tools-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        try expect(AgentLibraryConfiguration().defaultDisabledTools == ["shell"])
        try expect(library.defaultDisabledTools == ["shell"] && library.current.disabledTools == ["shell"])
        let legacy = try configuration()
        try expect(try legacy.decoded(AgentLibraryConfiguration.self).defaultDisabledTools == ["shell"])
        try await transport.reply("/v1/library", legacy)
        try await transport.reply("/v1/providers", .array([]))
        try await transport.reply("/v1/conversations", .array([]))
        try await library.restore()
        try expect(library.defaultDisabledTools == ["shell"] && library.current.disabledTools == ["shell"])
        library.setDefaultToolEnabled("not-a-tool", false)
        library.setDefaultToolEnabled("shell", false)
        library.setDefaultToolEnabled("read_file", true)
        try expect(!library.accountBusy && library.defaultDisabledTools == ["shell"])
        library.newConversation()
        try expect(library.pendingNewConversation?.disabledTools == ["shell"])
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.isEmpty)
    }

    func explicitAllEnabledPersistsAndRestores() async throws {
        let transport = FakeAgentTransport()
        let suite = "exec-default-tools-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        let library = ChatLibrary(provider: provider, preferences: preferences)
        defer { library.closePresentations() }
        try await transport.reply("/v1/library", configuration())
        try await transport.reply("/v1/providers", .array([]))
        try await transport.reply("/v1/conversations", .array([]))
        try await library.restore()
        let existing = library.current
        library.newConversation()
        let pending = library.pendingNewConversation!

        let allEnabled = try configuration([])
        let decoded = try allEnabled.decoded(AgentLibraryConfiguration.self)
        let roundtrip = try JSONDecoder().decode(AgentLibraryConfiguration.self, from: JSONEncoder().encode(decoded))
        try expect(roundtrip.defaultDisabledTools.isEmpty)
        try await transport.reply("/v1/library", allEnabled)
        library.setDefaultToolEnabled("shell", true)
        try await waitForDefaults(library)
        try expect(library.defaultDisabledTools.isEmpty)
        try expect(existing.disabledTools == ["shell"] && pending.disabledTools == ["shell"])
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.count == 1)
        guard let patch = writes.first, let body = patch.body else { throw CheckFailure(description: "Missing library patch") }
        try expect(patch.method == "PATCH" && patch.path == "/v1/library")
        try expect(try JSONDecoder().decode(AgentJSON.self, from: body) == .object(["defaultDisabledTools": .array([])]))
        library.newConversation()
        try expect(library.pendingNewConversation?.disabledTools.isEmpty == true)

        let reopened = ChatLibrary(provider: provider, preferences: preferences)
        defer { reopened.closePresentations() }
        try await reopened.restore()
        try expect(reopened.defaultDisabledTools.isEmpty && reopened.current.disabledTools.isEmpty)
        reopened.newConversation()
        try expect(reopened.pendingNewConversation?.disabledTools.isEmpty == true)
    }

    func sharedDefaultsOnlyAffectFutureConversations() async throws {
        let transport = FakeAgentTransport()
        let suite = "exec-default-tools-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        let existing = library.current
        // Legacy session metadata still means all enabled, independently of library defaults.
        let snapshot = try AgentIntegrationTests.fixture(state: "completed", result: true)
        try existing.apply(snapshot.decoded(AgentSnapshot.self))
        existing.draft = "Keep my draft"
        try await transport.reply("/v1/conversations", .array([snapshot]))
        try await transport.reply(AgentAPI.path(AgentIntegrationTests.conversationID), snapshot)
        library.newConversation()
        let pending = library.pendingNewConversation!
        try expect(existing.disabledTools.isEmpty && pending.disabledTools == ["shell"])

        for disabled in [["delegate", "shell"], ["shell", "unavailable"], []] as [[String]] {
            try await transport.reply("/v1/library", configuration(disabled))
            try await library.refreshSharedState()
            try expect(library.defaultDisabledTools == Set(disabled))
            try expect(library.current === existing && existing.disabledTools.isEmpty)
            try expect(existing.draft == "Keep my draft" && pending.disabledTools == ["shell"])
            library.newConversation()
            try expect(library.pendingNewConversation?.disabledTools == Set(disabled).intersection(SessionTool.names))
        }
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.isEmpty)
    }
}
