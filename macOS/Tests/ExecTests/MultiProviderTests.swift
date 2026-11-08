import Foundation
import AppKit
import SwiftUI

@MainActor private final class RegistryProbe: ChatProvider {
    final class Connection {
        var account: String? = "account"
        var discoveriesFail = false
        var connectFails = false
        var disconnectFails = false
        var disconnectAction: (() async -> Void)?
        var modelsAction: (() async throws -> Void)?
        var catalog: [ChatModel]?
        var usage: AccountUsage?
        var balance: [AccountBalance] = []
        var balanceAction: (() async throws -> [AccountBalance])?
        var requests: [String] = []
        var inputs: [[Message]] = []
        var definitions: [[String]] = []
        var searches: [String] = []
        var script: [[ChatEvent]] = []
        var onSend: (() -> Void)?
        var restored: [Data] = []
    }
    let displayName: String
    let connectionTitle = "Connect"
    let connection: Connection
    var account: String? { connection.account }
    let supportsWebSearch = true
    var supportsImageGeneration: Bool { displayName == "OpenAI" }
    var supportsCompaction: Bool { displayName == "OpenAI" }
    var state: Data?
    init(_ name: String, connection: Connection = Connection()) { displayName = name; self.connection = connection }
    func makeConversationProvider() throws -> any ChatProvider { RegistryProbe(displayName, connection: connection) }
    var connections: [ProviderConnection] {
        [.init(id: displayName, name: displayName, account: account,
               authentication: displayName == "DeepSeek" ? .apiKey : .browser,
               balanceIdentity: displayName == "DeepSeek" ? account : nil)]
    }
    var webSearchConfiguration: ProviderConnection.WebSearch {
        displayName == "DeepSeek" ? .service("DeepSeek Search") : .model
    }
    func accountUsage() async throws -> AccountUsage? { connection.usage }
    func accountBalance(providerID: String) async throws -> [AccountBalance] {
        try expect(providerID == displayName)
        return try await connection.balanceAction?() ?? connection.balance
    }
    func usesSearchModel(_ model: String) -> Bool { displayName == "OpenAI" }
    func connect() async throws {
        if connection.connectFails { throw ExecError("Connection failed") }
        connection.account = "account"
    }
    func disconnect() async throws {
        if connection.disconnectFails { throw ExecError("Disconnect failed") }
        connection.account = nil
        await connection.disconnectAction?()
    }
    func models() async throws -> [ChatModel] {
        try await connection.modelsAction?()
        if connection.discoveriesFail { throw ExecError("Unavailable") }
        return connection.catalog ?? [ChatModel(id: "model", name: displayName, acceptsImages: supportsImageGeneration)]
    }
    func encodeConversationState() throws -> Data? { state }
    func restoreConversationState(_ data: Data?, history: [Message]) throws {
        state = data
        if let data { connection.restored.append(data) }
    }
    func searchWeb(query: String, model: String, effort: String?) async throws -> WebSearchResult {
        connection.searches.append(model)
        return WebSearchResult(query: query, answer: "Found", sources: [])
    }
    func send(_ messages: [Message], model: String, effort: String?, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        connection.requests.append(model)
        connection.inputs.append(messages)
        connection.definitions.append(tools.map(\.name))
        connection.onSend?()
        state = Data(displayName.utf8)
        let events = connection.script.isEmpty ? [.text(displayName), .completed] : connection.script.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@MainActor struct MultiProviderTests {
    private func registry(_ openAI: RegistryProbe, _ deepSeek: RegistryProbe) -> ProviderRegistry {
        ProviderRegistry(entries: [.init(id: "openai", provider: openAI), .init(id: "deepseek", provider: deepSeek)], libraryIdentity: "account")
    }

    func switchesProvidersAndRestoresMixedHistory() async throws {
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let registry = registry(openAI, deepSeek)
        let provider = MultiProvider(registry: registry)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true)
        store.installModels(try await provider.models(), cached: false)
        for (model, text) in [("model", "First"), ("deepseek/model", "Second"), ("model", "Third")] {
            store.selectedModel = model
            store.draft = text
            store.send()
            await store.waitUntilIdle()
            try expect(store.error == nil)
        }
        try expect(openAI.connection.requests == ["model", "model"] && deepSeek.connection.requests == ["model"])
        try expect(openAI.connection.inputs.last?.contains { $0.text == "DeepSeek" } == true)
        try expect(deepSeek.connection.inputs.last?.contains { $0.text == "OpenAI" } == true)
        try expect(openAI.connection.definitions[0].contains("generate_image"))
        try expect(!deepSeek.connection.definitions[0].contains("generate_image"))
        let id = store.currentSessionID!
        let snapshot = try await sessions.load(id: id)!
        let reopened = ChatStore(provider: MultiProvider(registry: registry), sessions: sessions)
        reopened.installModels(store.models, cached: false)
        try await reopened.loadSession(id)
        try expect(reopened.messages == snapshot.messages && reopened.currentSessionID == id)
        try expect(openAI.connection.restored == [Data("OpenAI".utf8)])
        try expect(deepSeek.connection.restored == [Data("DeepSeek".utf8)])
        reopened.selectedModel = "deepseek/model"
        reopened.draft = "After restart"
        reopened.send()
        await reopened.waitUntilIdle()
        try expect(reopened.error == nil && deepSeek.connection.inputs.last?.contains { $0.text == "Third" } == true)
    }

    func toolsStayWithRunningProviderWhileSelectionChanges() async throws {
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let provider = MultiProvider(registry: registry(openAI, deepSeek))
        let store = ChatStore(provider: provider, newConversation: true)
        store.installModels(try await provider.models(), cached: false)
        store.selectedModel = "deepseek/model"
        store.searchModel = "model" // A Codex preference must not cross the provider boundary.
        deepSeek.connection.script = [[.toolCall(.init(id: "search", name: "web_search", arguments: #"{"query":"Swift"}"#)), .completed], [.text("Done"), .completed]]
        deepSeek.connection.onSend = { store.selectedModel = "model" }
        defer { deepSeek.connection.onSend = nil }
        store.draft = "Search"
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil)
        try expect(deepSeek.connection.requests == ["model", "model"])
        try expect(deepSeek.connection.searches == ["model"] && openAI.connection.searches.isEmpty)
        try expect(deepSeek.connection.definitions.allSatisfy { !$0.contains("generate_image") })
        try expect(openAI.connection.requests.isEmpty && store.selectedModel == "model")
    }

    func independentDisconnectAndPartialCatalogFailure() async throws {
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let registry = registry(openAI, deepSeek)
        let provider = MultiProvider(registry: registry)
        let models = try await provider.models()
        try expect(models.map(\.id) == ["model", "deepseek/model"])
        openAI.connection.discoveriesFail = true
        let partial = try await provider.models()
        try expect(partial.count == 2)
        try expect(provider.modelDiscoveryWarning?.contains("OpenAI") == true)
        let child = try provider.makeConversationProvider()
        let store = ChatStore(provider: child, newConversation: true)
        store.installModels(models, cached: false)
        store.selectedModel = "model"
        try await provider.disconnect(id: "openai")
        try expect(openAI.account == nil && deepSeek.account != nil && child.account != nil)
        try expect(child.conversationIdentity == "account")
        try expect(!child.isModelAvailable("model") && child.isModelAvailable("deepseek/model"))
        let remaining = try await provider.models()
        try expect(remaining.map(\.id) == ["deepseek/model"])
        store.installModels(remaining, cached: false)
        try expect(store.selectedModel == "model") // No silent cross-provider fallback.
        store.draft = "Keep my chosen provider"
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil && store.draft == "Keep my chosen provider" && store.messages.isEmpty && deepSeek.connection.requests.isEmpty)
        try expect(!provider.supportsImageGeneration(model: "deepseek/model") && !provider.supportsCompaction(model: "deepseek/model"))
        for try await _ in child.send([Message(role: .user, text: "Continue")], model: "deepseek/model", effort: nil, instructions: "", tools: []) {}
        try expect(deepSeek.connection.requests == ["model"])
        do {
            for try await _ in child.send([Message(role: .user, text: "No fallback")], model: "model", effort: nil, instructions: "", tools: []) {}
            throw CheckFailure(description: "Expected disconnected provider failure")
        } catch is ExecError {}
        try expect(deepSeek.connection.requests.count == 1)
    }

    func legacyStateAndAccountBoundaries() async throws {
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let registry = registry(openAI, deepSeek)
        let provider = MultiProvider(registry: registry)
        let legacy = Data(#"{"version":1,"outputs":{}}"#.utf8)
        try provider.restoreConversationState(legacy, history: [])
        try expect(openAI.connection.restored == [legacy] && deepSeek.connection.restored.isEmpty)
        let saved = try provider.encodeConversationState()
        openAI.connection.account = "different-account"
        let reopened = MultiProvider(registry: registry)
        try reopened.restoreConversationState(saved, history: [])
        try expect(openAI.connection.restored == [legacy]) // No opaque state reuse for another account.
        try expectFailure { try reopened.restoreConversationState(Data(#"{"format":"exec.providers.future"}"#.utf8), history: []) }
    }

    func libraryRetainsSessionsAndOtherConnectionOnSignout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MultiProviderTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let provider = MultiProvider(registry: registry(openAI, deepSeek))
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root), preferences: preferences)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations && library.models.count == 2 }
        library.selectedModel = "deepseek/model"
        library.draft = "Preserve me"
        library.send()
        try await wait { !library.hasRunningOperations }
        let id = library.currentSessionID
        library.disconnect(providerID: "openai")
        try await wait { !library.hasRunningOperations && library.models.count == 1 }
        try expect(library.currentSessionID == id && library.messages.contains { $0.text == "Preserve me" })
        try expect(library.connections.first?.account == nil && library.connections.last?.account != nil)
        library.disconnect(providerID: "deepseek")
        try await wait { !library.hasRunningOperations }
        try expect(library.account == nil && library.currentSessionID == id && library.sessionList.contains { $0.id == id })
        library.connect(providerID: "deepseek")
        try await wait { !library.hasRunningOperations && library.models.count == 1 }
        try expect(library.currentSessionID == id && library.messages.contains { $0.text == "Preserve me" })
    }

    func availabilityReconcilesEveryWindowAndDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ProviderAvailability.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        preferences.set("model", forKey: "defaultSessionModel")
        preferences.set("high", forKey: "defaultSessionEffort")
        preferences.set("model", forKey: "sessionTitleModel")
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        openAI.connection.catalog = [.init(id: "model", name: "Codex", efforts: [.init(id: "high", name: "High")])]
        deepSeek.connection.catalog = [.init(id: "model", name: "DeepSeek"),
                                      .init(id: "other", name: "DeepSeek Other", efforts: [.init(id: "low", name: "Low")])]
        deepSeek.connection.account = nil
        let provider = MultiProvider(registry: registry(openAI, deepSeek))
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root), preferences: preferences)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations && library.models.count == 1 }
        library.draft = "Existing conversation"
        library.send()
        try await wait { !library.hasRunningOperations }
        let existing = library.current
        let existingID = existing.currentSessionID!
        let panel = ChatPanel(library: library, conversation: existing)
        library.detachSession(existingID) { _ in }
        try await wait { !library.hasRunningOperations && library.detachedSessionIDs.contains(existingID) }
        let empty = library.current
        existing.draft = "Keep this draft"
        library.disconnect(providerID: "openai")
        try await wait { !library.hasRunningOperations }
        try expect(!library.hasConnectedProvider && library.models.isEmpty && library.modelGroups.isEmpty)
        try expect(library.connectedProviders.isEmpty && library.usageConnection == nil)
        try expect(panel.selectedModel.isEmpty && !panel.canSend && existing.selectedModel == "model")
        try expect(panel.modelUnavailableReason == "Connect a provider in settings")
        try expect(library.defaultSessionModel == nil && library.effectiveTitleModel.isEmpty && library.searchModels.isEmpty)
        let messageCount = existing.messages.count
        panel.send()
        existing.send() // The runner guards this too, independently of SwiftUI.
        try expect(existing.messages.count == messageCount && existing.draft == "Keep this draft")
        try expect(existing.pendingInput.isEmpty && openAI.connection.requests.count == 1)

        library.connect(providerID: "deepseek", credential: "test-key")
        try await wait { !library.hasRunningOperations && library.models.count == 2 }
        try expect(library.models.allSatisfy { $0.id.hasPrefix("deepseek/") })
        try expect(library.connectedProviders.map(\.id) == ["deepseek"])
        try expect(library.connectedProviders[0].webSearch == .service("DeepSeek Search"))
        try expect(!library.connectedProviders[0].supportsImageGeneration && library.usageConnection == nil)
        try expect(library.effectiveDefaultModel == "deepseek/model" && library.effectiveDefaultEffort == nil)
        try expect(empty.selectedModel == "model" && !empty.hasUsableModel)
        let emptyPanel = ChatPanel(library: library, conversation: empty)
        try expect(emptyPanel.modelUnavailableReason == "Model unavailable" && !emptyPanel.canSend)
        empty.draft = "Keep the unsent draft too"
        emptyPanel.send()
        try expect(empty.draft == "Keep the unsent draft too" && empty.messages.isEmpty)
        try expect(panel.modelUnavailableReason == "Model unavailable")
        try expect(panel.selectedModel.isEmpty && !panel.canSend)
        try expect(library.effectiveTitleModel.isEmpty && library.titleModel(for: empty) == nil)
        try expect(library.searchModels.isEmpty)
        panel.selectedModel = "model" // Stale programmatic selections cannot bypass the picker.
        try expect(panel.selectedModel.isEmpty)
        panel.selectedModel = "deepseek/other"
        try await wait { !library.hasRunningOperations }
        try expect(panel.canSend && panel.modelUnavailableReason == nil && existing.draft == "Keep this draft")
        library.defaultModel = "deepseek/other"
        library.setDefaultEffort("low")
        library.titleModel = "" // Same as chat, even when another provider returns.
        library.connect(providerID: "openai")
        try await wait { !library.hasRunningOperations && library.models.count == 3 }
        try expect(panel.selectedModel == "deepseek/other" && library.effectiveDefaultModel == "deepseek/other")
        try expect(library.usageConnection?.id == "openai")
        try expect(library.connectedProviders.first { $0.id == "openai" }?.webSearch == .model)
        try expect(library.connectedProviders.first { $0.id == "openai" }?.supportsImageGeneration == true)
        try expect(library.searchModels(for: "deepseek").isEmpty)
        try expect(library.searchModels(for: "openai").map(\.id) == ["model"])
        try expect(library.effectiveTitleModel.isEmpty && library.modelGroups.count == 2)
        library.defaultModel = "model"
        try expect(library.effectiveDefaultEffort == "high")
        library.disconnect(providerID: "openai")
        try await wait { !library.hasRunningOperations }
        try expect(library.effectiveDefaultModel == "deepseek/other" && library.effectiveDefaultEffort == "low")
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.current.selectedModel == "deepseek/other" && library.current.effectiveEffort == "low")
        let restarted = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root), preferences: preferences)
        defer { restarted.stopAll() }
        restarted.restore()
        try await wait { !restarted.hasRunningOperations && restarted.models.count == 2 }
        try expect(restarted.effectiveDefaultModel == "deepseek/other" && restarted.effectiveDefaultEffort == "low")
    }

    func failedConnectionsAndLateCatalogsDoNotReviveModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ProviderRaces.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let library = try ChatLibrary(provider: MultiProvider(registry: registry(openAI, deepSeek)),
                                      sessions: SessionStore(directory: root), preferences: preferences)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations && library.models.count == 2 }
        openAI.connection.disconnectFails = true
        library.disconnect(providerID: "openai")
        try await wait { !library.hasRunningOperations }
        try expect(library.connectionError == "Disconnect failed" && library.models.count == 2)
        openAI.connection.disconnectFails = false
        var pending: CheckedContinuation<Void, Never>?
        openAI.connection.modelsAction = { await withCheckedContinuation { pending = $0 } }
        defer { pending?.resume() }
        library.refreshModels()
        try await wait { pending != nil }
        library.disconnect(providerID: "openai")
        try await wait { !library.hasRunningOperations && library.models.count == 1 }
        pending?.resume(); pending = nil
        openAI.connection.modelsAction = nil
        await Task.yield()
        try expect(library.models.map(\.id) == ["deepseek/model"] && library.connectionError == nil)
        openAI.connection.connectFails = true
        library.connect(providerID: "openai")
        try await wait { !library.hasRunningOperations }
        try expect(library.connectionError == "Connection failed" && library.models.map(\.id) == ["deepseek/model"])
        openAI.connection.connectFails = false
        library.connect(providerID: "openai")
        try await wait { !library.hasRunningOperations && library.models.count == 2 }
        try expect(library.connectionError == nil)
        // Cancellation after Keychain removal must still invalidate every model route.
        var removing: CheckedContinuation<Void, Never>?
        deepSeek.connection.disconnectAction = { await withCheckedContinuation { removing = $0 } }
        defer { removing?.resume() }
        library.disconnect(providerID: "deepseek")
        try await wait { removing != nil }
        library.stop()
        removing?.resume(); removing = nil
        try await wait { !library.hasRunningOperations }
        try expect(library.models.map(\.id) == ["model"])
        try expect(!library.connections.contains { $0.id == "deepseek" && $0.account != nil })
    }

    func cachedCatalogSurvivesOnlyWhileAuthenticated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ProviderOffline.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let cache = AccountMetadataCache(directory: root.appendingPathComponent("cache"))
        let cached = [ChatModel(id: "model", name: "Cached Codex"), ChatModel(id: "deepseek/model", name: "Cached DeepSeek")]
        await cache.saveModels(cached, fetchedAt: .now, key: "Providers:account")
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        openAI.connection.discoveriesFail = true
        let library = try ChatLibrary(provider: MultiProvider(registry: registry(openAI, deepSeek)),
            sessions: SessionStore(directory: root.appendingPathComponent("sessions")), preferences: preferences, metadataCache: cache)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations && library.models.count == 2 }
        // Wait for the successful provider's replacement of its cached entry.
        try await wait { library.models.contains { $0.name == "DeepSeek" } }
        try expect(library.models.contains { $0.id == "model" && $0.name == "Cached Codex" })
        library.disconnect(providerID: "openai")
        try await wait { !library.hasRunningOperations }
        try expect(library.models.map(\.id) == ["deepseek/model"])
    }

    func optimisticStartupRemembersRealProviderDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ProviderStartupDefaults.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        preferences.set("preferred", forKey: "defaultSessionModel")
        preferences.set("high", forKey: "defaultSessionEffort")
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        openAI.connection.catalog = [.init(id: "model", name: "First"),
            .init(id: "preferred", name: "Preferred", efforts: [.init(id: "high", name: "High")])]
        let provider = MultiProvider(registry: registry(openAI, deepSeek))
        let cache = AccountMetadataCache(directory: root.appendingPathComponent("cache"))
        await cache.saveStartupAccount(.init(providerName: provider.displayName, connectionTitle: provider.connectionTitle,
                                            accountName: provider.account!, conversationIdentity: provider.conversationIdentity!))
        await cache.saveModels(try await provider.models(), fetchedAt: .now, key: "Providers:account")
        let preview = try await ChatLibrary.startupPresentation(sessions: SessionStore(directory: root.appendingPathComponent("sessions")),
                                                               cache: cache, preferences: preferences)!
        defer { preview.stopAll() }
        try await preview.reconcileStartup(with: provider)
        try await wait { !preview.hasRunningOperations && preview.models.count == 3 }
        preview.defaultModel = "deepseek/model"
        preview.disconnect(providerID: "deepseek")
        try await wait { !preview.hasRunningOperations }
        try expect(preview.effectiveDefaultModel == "preferred" && preview.effectiveDefaultEffort == "high")
        try expect((preferences.dictionary(forKey: "providerDefaultModels") as? [String: String])?["openai"] == "preferred")
    }

    func balanceCacheSurvivesRefreshAndClearsOnRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "BalanceCache.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let cache = AccountMetadataCache(directory: root.appendingPathComponent("cache"))
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let expected = [AccountBalance(amount: Decimal(string: "12.3456")!, currency: "USD")]
        deepSeek.connection.balance = expected
        let provider = MultiProvider(registry: registry(openAI, deepSeek))
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")),
                                      preferences: preferences, metadataCache: cache)
        defer { library.stopAll() }
        await library.refreshAccountBalance(for: "deepseek")
        try expect(library.accountBalance(for: "deepseek") == expected)
        try expect(library.accountBalance(for: "openai").isEmpty)
        deepSeek.connection.balanceAction = { throw ExecError("Offline") }
        await library.refreshAccountBalance(for: "deepseek")
        try expect(library.accountBalance(for: "deepseek") == expected)
        let reopened = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")),
                                       preferences: preferences, metadataCache: cache)
        defer { reopened.stopAll() }
        await reopened.refreshAccountBalance(for: "deepseek")
        try expect(reopened.accountBalance(for: "deepseek") == expected)

        var pending: CheckedContinuation<[AccountBalance], Never>?
        deepSeek.connection.balanceAction = { await withCheckedContinuation { pending = $0 } }
        let refresh = Task { await library.refreshAccountBalance(for: "deepseek") }
        try await wait { pending != nil }
        try expect(library.accountBalance(for: "deepseek") == expected)
        let updated = [AccountBalance(amount: 11, currency: "USD")]
        pending?.resume(returning: updated)
        await refresh.value
        try expect(library.accountBalance(for: "deepseek") == updated)

        pending = nil
        let staleRefresh = Task { await library.refreshAccountBalance(for: "deepseek") }
        try await wait { pending != nil }
        library.disconnect(providerID: "deepseek")
        try await wait { !library.hasRunningOperations }
        pending?.resume(returning: expected)
        await staleRefresh.value
        try expect(library.accountBalance(for: "deepseek").isEmpty)
        let disk = await cache.load(key: "account-balance:deepseek:account")
        try expect(disk.balances == nil)
    }

    func nativeProviderSettingsFitAndRender() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ProviderLayout.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        openAI.connection.usage = AccountUsage(windows: [
            .init(durationSeconds: 18_000, usedPercent: 24, resetsAt: .now.addingTimeInterval(3_600)),
            .init(durationSeconds: 604_800, usedPercent: 62, resetsAt: .now.addingTimeInterval(86_400))])
        let library = try ChatLibrary(provider: MultiProvider(registry: registry(openAI, deepSeek)),
            sessions: SessionStore(directory: root), preferences: preferences)
        defer { library.stopAll() }
        library.settingsTab = .accounts
        deepSeek.connection.balance = [.init(amount: Decimal(string: "12.3456")!, currency: "USD")]
        library.restore()
        try await wait { !library.hasRunningOperations && library.models.count == 2 && library.accountUsage != nil }
        let previews = ProcessInfo.processInfo.environment["EXEC_SETTINGS_PREVIEWS"].map { URL(fileURLWithPath: $0) }
        if let previews { try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true) }
        for tab in [ChatLibrary.SettingsTab.accounts, .modelsAndTools, .usage, .updates] {
            library.settingsTab = tab
            for dark in [false, true] {
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 420),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                defer { window.orderOut(nil); window.contentView = nil }
                let host = NSHostingView(rootView: SettingsView(store: library, canCheckForUpdates: false, checkForUpdates: {})
                    .frame(width: 500, height: 420).environment(\.colorScheme, dark ? .dark : .light))
                window.contentView = host
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                try expect(abs(host.fittingSize.width - 500) < 1 && host.fittingSize.height <= 421)
                if let previews, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: previews.appendingPathComponent("\(tab)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        let sheet = NSHostingView(rootView: ProviderKeySheet(providerName: "DeepSeek", connect: { _ in }))
        try expect(sheet.fittingSize.width <= 410 && sheet.fittingSize.height < 260)
        if let previews {
            library.settingsTab = .modelsAndTools
            try await renderPreview(SettingsView(store: library, canCheckForUpdates: false, checkForUpdates: {}), size: NSSize(width: 500, height: 680),
                                    to: previews.appendingPathComponent("models-and-tools-all.png"))
            library.settingsTab = .usage
            try await renderPreview(SettingsView(store: library, canCheckForUpdates: false, checkForUpdates: {}), size: NSSize(width: 500, height: 420),
                                    to: previews.appendingPathComponent("usage-both.png"))
            try await renderPreview(ProviderKeySheet(providerName: "DeepSeek", connect: { _ in }),
                                    size: NSSize(width: 360, height: 166), to: previews.appendingPathComponent("key-sheet.png"))
            library.disconnect(providerID: "openai")
            try await wait { !library.hasRunningOperations && library.models.count == 1 }
            library.settingsTab = .accounts
            try await renderPreview(SettingsView(store: library, canCheckForUpdates: false, checkForUpdates: {}), size: NSSize(width: 500, height: 420),
                                    to: previews.appendingPathComponent("providers-single.png"))
            library.defaultModel = "model" // A remembered Codex default is unavailable.
            let panel = ChatPanel(library: library, conversation: library.current)
            try expect(panel.modelUnavailableReason == "Model unavailable")
            try await renderPreview(ComposerPreview(panel: panel), size: NSSize(width: 540, height: 160),
                                    to: previews.appendingPathComponent("composer-model-unavailable.png"))
            library.settingsTab = .modelsAndTools
            try await renderPreview(SettingsView(store: library, canCheckForUpdates: false, checkForUpdates: {}), size: NSSize(width: 500, height: 420),
                                    to: previews.appendingPathComponent("deepseek-defaults.png"))
            library.disconnect(providerID: "deepseek")
            try await wait { !library.hasRunningOperations }
            try expect(panel.modelUnavailableReason == "Connect a provider in settings")
            try await renderPreview(ComposerPreview(panel: panel), size: NSSize(width: 540, height: 160),
                                    to: previews.appendingPathComponent("composer-provider-unavailable.png"))
            library.settingsTab = .accounts
            try await renderPreview(SettingsView(store: library, canCheckForUpdates: false, checkForUpdates: {}), size: NSSize(width: 500, height: 420),
                                    to: previews.appendingPathComponent("providers-empty.png"))
            library.settingsTab = .modelsAndTools
            try await renderPreview(SettingsView(store: library, canCheckForUpdates: false, checkForUpdates: {}), size: NSSize(width: 500, height: 420),
                                    to: previews.appendingPathComponent("models-and-tools-empty.png"))
            library.settingsTab = .usage
            try await renderPreview(SettingsView(store: library, canCheckForUpdates: false, checkForUpdates: {}), size: NSSize(width: 500, height: 420),
                                    to: previews.appendingPathComponent("usage-empty.png"))
        }
    }

    private struct ComposerPreview: View {
        let panel: ChatPanel
        @FocusState private var focused: Bool
        var body: some View { ChatComposer(store: panel, focused: $focused) }
    }

    private func renderPreview<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ExecError("Preview unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Provider registry test timed out")
    }
}
