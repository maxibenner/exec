import Foundation
import Observation

/// Native navigation/account presentation. Rust owns all durable conversation state.
@MainActor @Observable final class ChatLibrary {
    private(set) var current: ChatStore
    private(set) var models: [ChatModel] = []
    enum SettingsTab: CaseIterable { case modelsAndTools, tools, systemPrompt, accounts, remoteAccess, usage, updates }
    var settingsTab = SettingsTab.modelsAndTools
    var connectionError: String?
    private(set) var openingSessionID: UUID?
    private(set) var navigating = false
    private(set) var authenticating = false
    private var navigationError: String?
    private var modelRefreshError: String?
    private var savedSummaries: [SessionSummary] = []
    private var sidebarOrder: [UUID] = []
    private var pendingSidebarOrder: [UUID]?
    var isReorderingSessions: Bool { pendingSidebarOrder != nil }
    private(set) var pendingNewConversation: ChatStore?
    private var catalogRequest = 0
    private(set) var openConversations: [ChatStore] = []
    private(set) var detachedSessionIDs: Set<UUID> = []
    private var loading: ChatStore?
    private var navigationTask: Task<Void, Never>?
    private var navigationRequest = 0
    private var accountTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var defaultsTask: Task<Void, Never>?
    private var defaultsRevision = 0
    private var accountGeneration = 0
    private var registeringIDs: Set<UUID> = []
    private let provider: any ChatProvider
    private let sessions: SessionCatalog
    private let preferences: UserDefaults
    private static let modelCacheKey = "chat.modelCatalog"
    private let residentLimit: Int
    private var restoringDefaults = false
    private var synchronization: Task<Void, Never>?
    private let synchronizationSleep: @Sendable (Duration) async throws -> Void
    // Keep the last acknowledged remote state across settings presentations, scoped
    // to this library's backend. Pairing QR content remains local to the view.
    let remoteAccessSettings: RemoteAccessSettings
    private struct UsageCache: Codable {
        var accounts: [String: String] = [:]
        var usage: CachedAccountUsage?
        var balances: [String: [AccountBalance]] = [:]
    }
    private static let usageCacheKey = "chat.accountUsage"
    private var usageAccounts: [String: String] = [:]
    private var cachedUsage: CachedAccountUsage?
    private var balances: [String: [AccountBalance]] = [:]
    var accountUsage: AccountUsage? { displayedAccountUsage == nil ? nil : cachedUsage?.current() }
    var displayedAccountUsage: AccountUsage? { matchesUsageAccount("openai") ? cachedUsage?.usage : nil }
    var accountUsageFetchedAt: Date? { displayedAccountUsage == nil ? nil : cachedUsage?.fetchedAt }
    var descriptiveShellTitles: Bool { preferences.bool(forKey: ToolDisplayPreferences.descriptiveShellTitlesKey) }
    var systemPrompt = "" { didSet { guard !restoringDefaults else { return }; saveDefaults(); for item in openConversations { item.systemPrompt = systemPrompt; item.scheduleSave() } } }
    var defaultModel = "" { didSet { if defaultModel != oldValue { defaultEffort = nil }; saveDefaults() } }
    var defaultEffort: String? { didSet { saveDefaults() } }
    var automaticTitles = true { didSet { saveDefaults() } }
    var defaultAutoApproveTools = true { didSet { saveDefaults() } }
    private(set) var defaultDisabledTools: Set<String> = ["shell"] { didSet { saveDefaults() } }
    func setDefaultToolEnabled(_ name: String, _ enabled: Bool) {
        guard SessionTool.names.contains(name), defaultDisabledTools.contains(name) == enabled else { return }
        if enabled { defaultDisabledTools.remove(name) }
        else { defaultDisabledTools.insert(name) }
    }
    var searchModel = "" { didSet { guard !restoringDefaults else { return }; saveDefaults(); for item in openConversations { item.searchModel = searchModel; item.scheduleSave() } } }
    var defaultSessionModel: ChatModel? { models.first { $0.id == defaultModel } ?? models.first }
    var effectiveDefaultModel: String { defaultModel.isEmpty ? "" : defaultSessionModel?.id ?? "" }
    var effectiveDefaultEffort: String? { defaultSessionModel?.efforts.contains { $0.id == defaultEffort } == true ? defaultEffort : nil }
    var effectiveSearchModel: String { searchModels.first { $0.id == searchModel }?.id ?? searchModels.first?.id ?? "" }
    func setDefaultEffort(_ effort: String?) { defaultEffort = effort }

    init(provider: any ChatProvider, preferences: UserDefaults = .standard, residentLimit: Int = 8,
         synchronizationSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.synchronizationSleep = synchronizationSleep
        self.provider = provider
        self.preferences = preferences
        self.residentLimit = max(1, residentLimit)
        sessions = SessionCatalog(api: provider.api, preferences: preferences)
        remoteAccessSettings = RemoteAccessSettings(api: provider.api)
        current = ChatStore(provider: provider, disabledTools: ["shell"])
        if let data = preferences.data(forKey: Self.modelCacheKey),
           let cached = try? JSONDecoder().decode([ChatModel].self, from: data) {
            models = cached
            current.installModels(cached)
        }
        if let data = preferences.data(forKey: Self.usageCacheKey),
           let cached = try? JSONDecoder().decode(UsageCache.self, from: data) {
            usageAccounts = cached.accounts
            cachedUsage = cached.usage
            balances = cached.balances
        }
        observe(current)
        openConversations = [current]
    }
    func restore() async throws {
        try await sessions.restore()
        restoringDefaults = true
        let config = sessions.configuration
        automaticTitles = config.automaticTitles
        defaultModel = config.defaultModel ?? ""
        defaultEffort = config.settings.effort
        systemPrompt = config.settings.systemPrompt
        searchModel = config.settings.searchModel ?? ""
        defaultAutoApproveTools = config.settings.autoApprove
        defaultDisabledTools = Set(config.defaultDisabledTools)
        restoringDefaults = false
        current = try makeConversation()
        openConversations = [current]
        try await provider.refreshConnections()
        models = models.filter { provider.isModelAvailable($0.id) }
        cacheModels()
        for item in conversations { applyModels(to: item) }
        try await refreshCatalog()
        if let id = sessions.selected, savedSummaries.contains(where: { $0.id == id && !$0.unreadable }) {
            try await current.loadSession(id)
        }
        refreshModels()
    }
    private func saveDefaults() {
        guard !restoringDefaults else { return }
        defaultsRevision += 1
        guard defaultsTask == nil else { return }
        defaultsTask = Task {
            defer { defaultsTask = nil }
            await Task.yield()
            while true {
                let revision = defaultsRevision
                let model = defaultModel.isEmpty ? nil : defaultModel
                let settings = AgentSettings(systemPrompt: systemPrompt, autoApprove: defaultAutoApproveTools,
                    effort: defaultEffort, searchModel: searchModel.isEmpty ? nil : searchModel)
                let titles = automaticTitles
                let disabledTools = defaultDisabledTools.sorted()
                do {
                    try await sessions.update {
                        $0.defaultModel = model; $0.settings = settings; $0.automaticTitles = titles
                        $0.defaultDisabledTools = disabledTools
                    }
                }
                catch { navigationError = error.localizedDescription; return }
                if revision == defaultsRevision { return }
            }
        }
    }
    var sidebarSessions: [SessionSummary] {
        sessionList.filter { $0.parent == nil && !detachedSessionIDs.contains($0.id) }
    }
    func childSessions(of id: UUID?) -> [SessionSummary] {
        guard let id else { return [] }
        return sessionList.filter { $0.parent?.sessionId == id }
    }
    func hasConversation(_ conversation: ChatStore) -> Bool { conversation.workspace != nil || !conversation.messages.isEmpty || conversation.currentSessionID != nil }
    var sessionList: [SessionSummary] {
        var summaries = Dictionary(uniqueKeysWithValues: savedSummaries.map { ($0.id, $0) })
        for item in openConversations { if let summary = item.summary { summaries[summary.id] = summary } }
        // A create response can arrive before its catalog order is persisted.
        // Show those new residents at the top from their very first frame.
        let knownIDs = Set(sidebarOrder + savedSummaries.map(\.id))
        var result = openConversations.reversed().compactMap { item -> SessionSummary? in
            guard let id = item.currentSessionID, !knownIDs.contains(id) else { return nil }
            return summaries.removeValue(forKey: id)
        }
        result += sidebarOrder.compactMap { summaries.removeValue(forKey: $0) }
        result += savedSummaries.compactMap { summaries.removeValue(forKey: $0.id) }
        result += summaries.values.sorted { $0.id.uuidString < $1.id.uuidString }
        if let pendingSidebarOrder {
            // Keep the dropped order through intervening checkpoint/catalog updates.
            // New sessions still appear at the top; removed sessions stay removed.
            var remaining = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            let ordered = pendingSidebarOrder.compactMap { remaining.removeValue(forKey: $0) }
            return result.filter { remaining[$0.id] != nil } + ordered
        }
        return result
    }
    var sessionShortcuts: [(number: Int, session: SessionSummary)] { sidebarSessions.prefix(9).enumerated().map { ($0.offset + 1, $0.element) } }
    var connections: [ProviderConnection] { provider.connections }
    var connectedProviders: [ProviderConnection] { connections.filter { $0.account != nil } }
    var hasConnectedProvider: Bool { !connectedProviders.isEmpty }
    var account: String? { provider.account }
    var usageConnection: ProviderConnection? { connectedProviders.first { $0.id == "openai" } }
    var modelGroups: [ProviderModelGroup] {
        connections.compactMap { connection in
            let available = models.filter { provider.providerID(for: $0.id) == connection.id }
            return available.isEmpty ? nil : ProviderModelGroup(id: connection.id, name: connection.name, models: available)
        }
    }
    var searchModels: [ChatModel] { models.filter { provider.providerID(for: $0.id) == "openai" } }
    func searchModels(for providerID: String) -> [ChatModel] { searchModels.filter { provider.providerID(for: $0.id) == providerID } }
    func providerName(for model: String) -> String { connections.first { $0.id == provider.providerID(for: model) }?.name ?? "" }
    var currentSessionID: UUID? { current.currentSessionID }
    var sidebarSelectionID: UUID? { openingSessionID ?? currentSessionID }
    var canNavigate: Bool { !authenticating && (!navigating || openingSessionID != nil) }
    private var canModify: Bool { !navigating && !authenticating }
    var canReorderSessions: Bool { canModify }
    var accountBusy: Bool { authenticating || defaultsTask != nil || conversations.contains { $0.busy || $0.isSaving } }
    var hasUnsavedChanges: Bool { conversations.contains { $0.hasUnsavedChanges } }
    var hasUnsentDrafts: Bool { conversations.contains { $0.hasUnsentDraft } }
    var hasRunningOperations: Bool {
        navigating || authenticating || defaultsTask != nil || conversations.contains { $0.busy || $0.isSaving } ||
            savedSummaries.contains { conversation($0.id) == nil && $0.isRunning }
    }
    var error: String? {
        get { navigationError ?? pendingNewConversation?.error ?? current.error ?? modelRefreshError }
        set {
            navigationError = nil
            modelRefreshError = nil
            if let pendingNewConversation, pendingNewConversation.error != nil {
                pendingNewConversation.error = nil
                cancelNewConversation(pendingNewConversation)
            }
            current.error = newValue
        }
    }
    private var conversations: [ChatStore] {
        var result = openConversations
        if let loading, !result.contains(where: { $0 === loading }) { result.append(loading) }
        return result
    }
    private func conversation(_ id: UUID) -> ChatStore? { openConversations.first { $0.currentSessionID == id } }
    func isSessionRunning(_ id: UUID) -> Bool { conversation(id)?.busy ?? (savedSummaries.first { $0.id == id }?.isRunning == true) }
    func isSessionWaiting(_ id: UUID) -> Bool { conversation(id)?.isWaiting ?? (savedSummaries.first { $0.id == id }?.isWaiting == true) }
    func isSessionResponding(_ id: UUID) -> Bool { conversation(id).map { $0.isSending || $0.isCompacting } == true }
    func needsApproval(_ id: UUID) -> Bool {
        if let resident = conversation(id) { return resident.tools.pendingApproval != nil }
        return savedSummaries.first { $0.id == id }?.awaitingApproval == true
    }
    func needsAttention(_ id: UUID) -> Bool { conversation(id).map { $0.error != nil || $0.hasUnsavedChanges } == true }
    func send(in destination: ChatStore? = nil) {
        guard canModify else { return }
        (destination ?? current).send()
    }
    func stop() {
        if authenticating { Task { await provider.cancelConnection() } }
        else { current.stop() }
    }
    func stopAll() {
        navigationTask?.cancel()
        Task { await provider.cancelConnection() }
        modelTask?.cancel()
        for item in conversations { item.cancelPendingCommands(); if item.busy { item.stop() } }
    }
    func closePresentations() { synchronization?.cancel(); synchronization = nil; for item in conversations { item.closePresentation() } }
    func startSynchronization() {
        guard synchronization == nil else { return }
        let changes = provider.api.changes
        let sleep = synchronizationSleep
        synchronization = Task { [weak self] in
            let subscription = await changes.subscribe(.catalog)
            defer { subscription.close() }
            for await signal in subscription.stream {
                var delay = 250
                repeat {
                    do {
                        try Task.checkCancellation()
                        guard let self else { return }
                        // A guarded/skipped read must not consume the invalidation.
                        // Retry only this pending catchup, never poll an idle catalog.
                        if try await !self.catchUpSharedState() {
                            try await sleep(.milliseconds(100))
                            continue
                        }
                        delay = 250
                        if case .unsupported = signal { try await sleep(.seconds(2)) }
                        else { break }
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled else { return }
                        self?.connectionError = error.localizedDescription
                        do { try await sleep(.milliseconds(delay)) } catch { return }
                        delay = min(delay * 2, 8_000)
                    }
                } while !Task.isCancelled
            }
        }
    }
    func refreshSharedState() async throws { _ = try await catchUpSharedState() }
    private func catchUpSharedState() async throws -> Bool {
        guard !navigating, defaultsTask == nil else { return false }
        let revision = defaultsRevision
        try await sessions.restore()
        try Task.checkCancellation()
        guard defaultsTask == nil, revision == defaultsRevision else { return false }
        let config = sessions.configuration
        restoringDefaults = true
        defaultModel = config.defaultModel ?? ""
        defaultEffort = config.settings.effort
        automaticTitles = config.automaticTitles
        systemPrompt = config.settings.systemPrompt
        searchModel = config.settings.searchModel ?? ""
        defaultAutoApproveTools = config.settings.autoApprove
        defaultDisabledTools = Set(config.defaultDisabledTools)
        restoringDefaults = false
        guard try await refreshCatalog() else { return false }
        guard !navigating else { return false }
        for conversation in openConversations { conversation.reconnectIfNeeded() }
        connectionError = nil
        return true
    }
    func connect(providerID: String, credential: String? = nil) {
        accountOperation { try await self.provider.connect(id: providerID, credential: credential) }
    }
    func disconnect(providerID: String) {
        accountOperation { try await self.provider.disconnect(id: providerID) }
    }
    private func accountOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        guard canModify, !accountBusy else { return }
        authenticating = true
        accountGeneration += 1
        modelTask?.cancel()
        connectionError = nil
        accountTask = Task {
            defer { authenticating = false; accountTask = nil; refreshModels() }
            do { try await operation() }
            catch { connectionError = error.localizedDescription }
            try? await provider.refreshConnections()
            models = models.filter { provider.isModelAvailable($0.id) }
            cacheModels()
            balances = [:]; cachedUsage = nil; usageAccounts = [:]
            preferences.removeObject(forKey: Self.usageCacheKey)
            for item in conversations { applyModels(to: item) }
        }
    }
    func refreshModels() {
        guard !authenticating, hasConnectedProvider else { return }
        modelTask?.cancel()
        modelTask = Task {
            do {
                let available = try await provider.models()
                guard !Task.isCancelled else { return }
                models = available.filter { provider.isModelAvailable($0.id) }
                cacheModels()
                modelRefreshError = nil
                for item in conversations { applyModels(to: item) }
                if models.isEmpty { modelRefreshError = "Could not load models. Remove and add the provider in Settings → Providers to try again." }
            } catch {
                if !Task.isCancelled { modelRefreshError = "Could not load models. Remove and add the provider in Settings → Providers to try again." }
            }
        }
    }
    // Catalog metadata only: never persist account identities or credentials.
    // Failed refreshes leave the last successful catalog intact.
    private func cacheModels() {
        if let data = try? JSONEncoder().encode(models) {
            preferences.set(data, forKey: Self.modelCacheKey)
        }
    }
    private func applyModels(to conversation: ChatStore) {
        guard !conversation.busy else { return }
        let needsDefault = conversation.selectedModel.isEmpty
        conversation.installModels(models)
        if conversation.currentSessionID == nil {
            conversation.systemPrompt = systemPrompt
            conversation.searchModel = searchModel
        }
        if needsDefault { conversation.selectedModel = defaultSessionModel?.id ?? defaultModel; conversation.selectedEffort = effectiveDefaultEffort }
        if conversation.currentSessionID == nil, conversation.workspace != nil { conversation.scheduleSave() }
    }
    private func matchesUsageAccount(_ providerID: String) -> Bool {
        guard let account = connectedProviders.first(where: { $0.id == providerID })?.account else { return false }
        return usageAccounts[providerID] == account
    }
    private func cacheAccountReports() {
        let cache = UsageCache(accounts: usageAccounts, usage: cachedUsage, balances: balances)
        if let data = try? JSONEncoder().encode(cache) { preferences.set(data, forKey: Self.usageCacheKey) }
    }
    func accountBalance(for providerID: String) -> [AccountBalance] {
        matchesUsageAccount(providerID) ? balances[providerID] ?? [] : []
    }
    func refreshAccountBalance(for providerID: String) async {
        guard !authenticating, let account = connectedProviders.first(where: { $0.id == providerID })?.account else { return }
        let generation = accountGeneration
        do {
            let values = try await provider.api.get("/v1/providers/\(providerID)/balance")
            guard generation == accountGeneration, !authenticating,
                  connectedProviders.first(where: { $0.id == providerID })?.account == account else { return }
            balances[providerID] = values.array.compactMap { value in
                guard let amount = value["amount"].string.flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }),
                      let currency = value["currency"].string else { return nil }
                return AccountBalance(amount: amount, currency: currency)
            }
            usageAccounts[providerID] = account
            cacheAccountReports()
        } catch { /* Keep the last report; account observations must not fail a chat. */ }
    }
    func refreshAccountUsage() {
        guard !authenticating, let account = usageConnection?.account else { return }
        let generation = accountGeneration
        Task {
            guard let value = try? await provider.api.get("/v1/providers/openai/usage") else { return }
            guard generation == accountGeneration, !authenticating, usageConnection?.account == account else { return }
            let windows = value["windows"].array.compactMap { item -> AccountUsage.Window? in
                guard let duration = item["durationSeconds"].number, let used = item["usedPercent"].number,
                      let resets = item["resetsAt"].number else { return nil }
                return .init(durationSeconds: Int(duration), usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
            }
            if !windows.isEmpty {
                cachedUsage = CachedAccountUsage(usage: AccountUsage(windows: windows), fetchedAt: Date(timeIntervalSince1970: (value["fetchedAt"].number ?? 0) / 1000))
                usageAccounts["openai"] = account
                cacheAccountReports()
            }
        }
    }
    /// Window ownership never creates a second runner or restores a resident provider.
    func detachSession(_ id: UUID, present: @escaping (ChatStore) -> Void) {
        guard canModify, !detachedSessionIDs.contains(id),
              sessionList.contains(where: { $0.id == id && !$0.unreadable }) else { return }
        func finish(_ conversation: ChatStore) throws {
            // Prepare the replacement before changing ownership, so failure is atomic.
            var replacement = current
            if conversation === current {
                // With no remaining resident, use the same blank placeholder as
                // deletion. Inheriting a workspace would create a phantom session.
                replacement = try openConversations.first(where: {
                    $0 !== conversation && $0.currentSessionID.map(detachedSessionIDs.contains) != true
                }) ?? makeConversation()
            }
            remember(conversation)
            detachedSessionIDs.insert(id)
            if conversation === current { activate(replacement) }
            present(conversation)
        }
        if let resident = conversation(id) {
            do { try finish(resident) }
            catch { navigationError = error.localizedDescription }
        } else {
            navigate {
                let conversation = try self.makeConversation()
                self.loading = conversation
                try await conversation.loadSession(id)
                try Task.checkCancellation()
                try finish(conversation)
            }
        }
    }

    /// Closing a detached window returns it without deleting or stopping its work.
    func attachSession(_ id: UUID) {
        guard detachedSessionIDs.remove(id) != nil else { return }
        // A close during a catalog operation still returns ownership safely; it
        // need not change the main selection until navigation becomes available.
        if canNavigate, let resident = conversation(id) {
            cancelOpening()
            activate(resident)
        }
    }

    func openSession(_ id: UUID, onOpened: @escaping @MainActor () -> Void = {}) {
        guard canNavigate, !detachedSessionIDs.contains(id) else { return }
        if let pendingNewConversation { cancelNewConversation(pendingNewConversation) }
        cancelOpening()
        navigationError = nil
        if let existing = conversation(id) {
            existing.reconnectIfNeeded()
            activate(existing) // No snapshot I/O or provider restoration on the resident path.
            onOpened()
            return
        }
        openingSessionID = id
        navigate {
            let next = try self.makeConversation()
            self.loading = next
            try await next.loadSession(id)
            try Task.checkCancellation()
            self.activate(next)
            onOpened()
        }
    }

    func waitForNavigation() async { await navigationTask?.value }
    func canRequestFork(_ source: ChatStore) -> Bool {
        canModify && source.canRequestFork && hasConversation(source) && openConversations.contains { $0 === source }
    }
    func canForkConversation(_ source: ChatStore) -> Bool {
        canModify && source.canFork && hasConversation(source) && openConversations.contains { $0 === source }
    }

    func forkConversation(_ source: ChatStore, onOpened: @escaping @MainActor () -> Void = {}) {
        guard canForkConversation(source) else { return }
        let commandDraft = source.draft
        navigate(reportingTo: source) {
            await source.waitForPendingSave()
            try await source.saveIfIdle()
            try Task.checkCancellation()
            let next = try self.makeConversation()
            self.loading = next
            try await next.copyConversation(from: source)
            try await next.didCheckpoint?()
            try Task.checkCancellation()
            if source.draft == commandDraft, let command = ComposerCommand(commandDraft),
               command.page == .fork || (command.page == nil && ComposerCommand.Page.fork.matches(command.query)) {
                source.draft = ""
            }
            self.activate(next)
            onOpened()
        }
    }

    func newConversation(onCreated: @escaping @MainActor () -> Void = {}) {
        guard canNavigate else { return }
        if let pendingNewConversation,
           !pendingNewConversation.needsInitialWorkspaceSelection, pendingNewConversation.error == nil { return }
        cancelOpening()
        navigationError = nil
        if let pendingNewConversation { cancelNewConversation(pendingNewConversation) }
        do {
            let next = try makeConversation()
            let checkpoint = next.didCheckpoint
            next.didCheckpoint = { [weak self, weak next] in
                guard let self, let next else { return }
                // A blank may wait for workspace/model selection. Only its first
                // confirmed save is creation, not activation or a catalog refresh.
                if next.currentSessionID != nil {
                    next.didCheckpoint = checkpoint
                    // Only a confirmed creation may replace the visible conversation.
                    // Explicit navigation while it was pending takes precedence.
                    if self.pendingNewConversation === next { self.activate(next) }
                    onCreated()
                }
                try await checkpoint?()
            }
            next.requestInitialWorkspaceSelection()
            pendingNewConversation = next
            remember(next)
        } catch { navigationError = error.localizedDescription }
    }

    func cancelNewConversation(_ conversation: ChatStore) {
        guard pendingNewConversation === conversation else { return }
        pendingNewConversation = nil
        // Never discard a request in flight or an uncertain save.
        if conversation.currentSessionID == nil, conversation.workspace == nil,
           !conversation.isSaving, !conversation.hasUnsentDraft {
            conversation.closePresentation()
            openConversations.removeAll { $0 === conversation }
        }
    }

    /// Evict least recently visited idle sessions; runners and unsaved input never
    /// depend on the cache limit. Saved conversations remain in the sidebar.
    private func trimConversations() {
        for conversation in openConversations {
            guard openConversations.count > residentLimit else { break }
            guard conversation !== current, conversation !== pendingNewConversation,
                  conversation.currentSessionID.map(detachedSessionIDs.contains) != true,
                  !conversation.busy, !conversation.isSaving,
                  !conversation.hasUnsentDraft, !conversation.hasUnsavedChanges else { continue }
            conversation.closePresentation()
            openConversations.removeAll { $0 === conversation }
        }
    }

    func selectWorkspace(_ url: URL, in destination: ChatStore? = nil) {
        let destination = destination ?? pendingNewConversation ?? current
        guard canModify, destination.canSelectWorkspace,
              openConversations.contains(where: { $0 === destination }) else { return }
        navigate(reportingTo: destination) {
            let loading = Task.detached(priority: .userInitiated) { try Workspace.load(url) }
            let workspace = try await withTaskCancellationHandler {
                try await loading.value
            } onCancel: { loading.cancel() }
            await destination.waitForPendingSave()
            try Task.checkCancellation()
            try destination.setInitialWorkspace(workspace)
            try await destination.saveIfIdle()
            try await self.refreshCatalog()
            try await self.selectCurrent()
        }
    }

    func moveSession(_ id: UUID, before nextID: UUID?) {
        let ids = sessionList.map(\.id)
        guard let source = ids.firstIndex(of: id), nextID != id else { return }
        let destination = nextID.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        moveSessions(from: IndexSet(integer: source), to: destination)
    }

    /// List offsets refer only to visible rows, not conversations in other windows.
    func moveSidebarSessions(from offsets: IndexSet, to destination: Int) {
        let visible = sidebarSessions.map(\.id)
        guard !offsets.isEmpty, offsets.allSatisfy({ visible.indices.contains($0) }),
              (0...visible.count).contains(destination) else { return }
        let ids = sessionList.map(\.id)
        let moving = Set(offsets.map { visible[$0] })
        let sources = IndexSet(ids.indices.filter { moving.contains(ids[$0]) })
        let target = destination < visible.count ? ids.firstIndex(of: visible[destination])! : ids.count
        moveSessions(from: sources, to: target)
    }

    func moveSessions(from offsets: IndexSet, to destination: Int) {
        let ids = sessionList.map(\.id)
        guard canReorderSessions, !offsets.isEmpty,
              offsets.allSatisfy({ ids.indices.contains($0) }),
              (0...ids.count).contains(destination) else { return }
        let moving = offsets.map { ids[$0] }
        var reordered = ids.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        reordered.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        guard reordered != ids else { return }
        // Publish synchronously in the native drop transaction. Persistence must
        // not determine when the list commits its drag animation.
        pendingSidebarOrder = reordered
        navigate {
            // A visible draft may not have a snapshot yet. Save it before making
            // its position durable, without interrupting any running conversation.
            for id in ids where !self.savedSummaries.contains(where: { $0.id == id }) {
                if let conversation = self.conversation(id) {
                    await conversation.waitForPendingSave()
                    try Task.checkCancellation()
                    try await conversation.saveIfIdle(force: true)
                }
            }
            try Task.checkCancellation()
            try await self.sessions.reorder(reordered)
            try await self.refreshCatalog()
        }
    }

    func canRenameSession(_ id: UUID) -> Bool {
        canModify && sessionList.contains { $0.id == id && !$0.unreadable }
    }

    func renameSession(_ id: UUID, title: String) {
        guard canRenameSession(id) else { return }
        navigate {
            // Persist an unsaved idle draft/workspace session before changing its metadata.
            // Running sessions already exist in Rust; saveIfIdle leaves their runner
            // and queued configuration untouched while the title is checkpointed there.
            if let conversation = self.conversation(id) {
                await conversation.waitForPendingSave()
                try Task.checkCancellation()
                try await conversation.saveIfIdle(force: true)
            }
            try await self.sessions.rename(id: id, title: title)
            try await self.refreshCatalog()
        }
    }

    func canDeleteSession(_ id: UUID) -> Bool {
        canModify && sessionList.contains { $0.id == id }
    }

    func deleteSession(_ id: UUID) {
        guard canDeleteSession(id) else { return }
        let wasDetached = detachedSessionIDs.contains(id)
        let rows = sidebarSessions.map(\.id)
        // Child deletion returns to its parent. Top-level deletion uses visible
        // sidebar order; detached deletions leave the main selection alone.
        let parentID = sessionList.first { $0.id == id }?.parent?.sessionId
        let nextID: UUID? = parentID ?? rows.firstIndex(of: id).flatMap { index in
            index + 1 < rows.count ? rows[index + 1] : (index > 0 ? rows[index - 1] : nil)
        }
        let family = Set([id] + childSessions(of: id).map(\.id))
        navigate(reportingTo: wasDetached ? conversation(id) : nil) {
            let deleting = self.openConversations.filter { $0.currentSessionID.map(family.contains) == true }
            for conversation in deleting { await conversation.waitForPendingSave() }
            try Task.checkCancellation()
            // Cascading deletion closes every family member's stream. Pause all
            // resident presentations, then reconcile against the confirmed catalog.
            for conversation in deleting { conversation.beginDeletion() }
            defer {
                for conversation in deleting where self.openConversations.contains(where: { $0 === conversation }) {
                    conversation.resumeAfterFailedDeletion()
                }
            }
            var failure: Error?
            do { try await self.sessions.delete(id: id) }
            catch { failure = error }
            try await self.refreshCatalog()
            let removed = family.subtracting(self.savedSummaries.map(\.id))
            let currentRemoved = self.currentSessionID.map(removed.contains) == true
            self.detachedSessionIDs.subtract(removed)
            for conversation in deleting where conversation.currentSessionID.map(removed.contains) == true {
                conversation.closePresentation()
            }
            self.openConversations.removeAll { $0.currentSessionID.map(removed.contains) == true }
            self.sidebarOrder.removeAll { removed.contains($0) }
            if removed.contains(id) || currentRemoved {
                // A partial cascade can remove the selected child but retain its
                // parent. Keep that parent selected so the failure stays inspectable.
                let destinationID = removed.contains(id) ? nextID : id
                do {
                    if !wasDetached || parentID != nil, let nextID = destinationID {
                        if let resident = self.conversation(nextID) {
                            self.activate(resident)
                        } else {
                            let next = try self.makeConversation()
                            self.loading = next
                            try await next.loadSession(nextID)
                            try Task.checkCancellation()
                            self.activate(next)
                        }
                    } else if currentRemoved {
                        self.activate(try self.makeConversation())
                    }
                } catch {
                    // Never leave a deleted conversation active if its neighbor
                    // cannot be restored, or a cold load is cancelled.
                    if self.currentSessionID.map(removed.contains) == true { self.activate(try self.makeConversation()) }
                    throw error
                }
            }
            if let failure { throw failure }
            try await self.refreshCatalog()
            try await self.selectCurrent()
        }
    }

    private func makeConversation() throws -> ChatStore {
        // Keep unavailable names in shared defaults, but only submit this client's
        // selectable tools when creating a session with an explicit selection.
        let conversation = ChatStore(provider: provider, defaultAutoApproveTools: defaultAutoApproveTools,
                                     disabledTools: defaultDisabledTools.intersection(SessionTool.names))
        conversation.installModels(models)
        conversation.selectedModel = defaultSessionModel?.id ?? defaultModel
        conversation.selectedEffort = effectiveDefaultEffort
        conversation.systemPrompt = systemPrompt
        conversation.searchModel = searchModel
        observe(conversation)
        return conversation
    }
    private func observe(_ conversation: ChatStore) {
        conversation.confirmPresence = { [weak self, weak conversation] in
            guard let self, let conversation else { return .present }
            guard try await self.refreshCatalog() else { return .superseded }
            // A local save/cancel can temporarily prevent resident removal.
            // The confirmed catalog still distinguishes absence from a failed read.
            return self.savedSummaries.contains { $0.id == conversation.currentSessionID } ? .present : .removed
        }
        conversation.didCheckpoint = { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            if let id = conversation.currentSessionID, !self.savedSummaries.contains(where: { $0.id == id }),
               self.registeringIDs.insert(id).inserted {
                defer { self.registeringIDs.remove(id) }
                self.sidebarOrder.removeAll { $0 == id }
                self.sidebarOrder.insert(id, at: 0)
                try await self.sessions.update { config in
                    config.order.removeAll { $0 == id }
                    config.order.insert(id, at: 0)
                }
            }
            try await self.refreshCatalog()
            if conversation === self.current { self.persistSelection() }
        }
        conversation.didFinish = { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            self.applyModels(to: conversation)
            self.trimConversations()
        }
    }
    private func remember(_ conversation: ChatStore) {
        if !openConversations.contains(where: { $0 === conversation }) { openConversations.append(conversation) }
        if let id = conversation.currentSessionID, !sidebarOrder.contains(id),
           !savedSummaries.contains(where: { $0.id == id }) {
            sidebarOrder.insert(id, at: 0)
        }
    }

    private func activate(_ conversation: ChatStore) {
        let previous = current
        if let pendingNewConversation { cancelNewConversation(pendingNewConversation) }
        if previous !== conversation, previous.currentSessionID == nil, previous.hasUnsentDraft {
            previous.scheduleSave(force: true)
            Task {
                await previous.waitUntilIdle()
                await previous.waitForPendingSave()
                do {
                    guard previous.currentSessionID != nil else { throw ExecError(previous.error ?? "Choose a workspace and model before leaving this draft.") }
                } catch {
                    previous.error = error.localizedDescription
                    // A failed/uncertain create is not retried or allowed to hide the draft.
                    if self.current === conversation { self.current = previous; self.persistSelection() }
                    self.navigationError = error.localizedDescription
                }
            }
        }
        applyModels(to: conversation)
        remember(conversation)
        current = conversation
        openConversations.removeAll { $0 === conversation }
        openConversations.append(conversation) // Oldest visit first, most recent last.
        // An untouched blank isn't an open document.
        openConversations.removeAll { conversation in
            conversation !== current && conversation.summary == nil && !conversation.busy && !conversation.isSaving &&
            !conversation.hasUnsentDraft && !conversation.hasUnsavedChanges && conversation.error == nil &&
            !savedSummaries.contains(where: { $0.id == conversation.currentSessionID })
        }
        trimConversations()
        persistSelection()
    }

    private func cancelOpening() {
        guard openingSessionID != nil else { return }
        navigationRequest += 1
        navigationTask?.cancel()
        navigationTask = nil
        openingSessionID = nil
        loading = nil
        navigating = false
    }

    private func persistSelection() { sessions.select(currentSessionID) }

    @discardableResult private func refreshCatalog() async throws -> Bool {
        catalogRequest += 1
        let request = catalogRequest
        // Only presentations that existed when this read began can be removed.
        // A create/load that finishes in flight must survive an older catalog.
        let observedResidents = Dictionary(uniqueKeysWithValues: openConversations.compactMap { conversation -> (UUID, UUID)? in
            guard let id = conversation.currentSessionID, !registeringIDs.contains(id) else { return nil }
            return (conversation.id, id)
        })
        let summaries = try await sessions.list()
        guard request == catalogRequest else { return false }
        applyCatalog(summaries)
        try reconcileMissingResidents(observedResidents)
        return true
    }

    private func reconcileMissingResidents(_ observedResidents: [UUID: UUID]) throws {
        let persisted = Set(savedSummaries.map(\.id))
        var removedCurrent = false
        var parentID: UUID?
        for conversation in openConversations {
            guard let id = conversation.currentSessionID, observedResidents[conversation.id] == id,
                  !persisted.contains(id), !registeringIDs.contains(id) else { continue }
            let parent = conversation.summary?.parent?.sessionId
            guard conversation.markDeletedRemotely(), !conversation.hasUnsentDraft else { continue }
            if current === conversation { removedCurrent = true; parentID = parent }
            detachedSessionIDs.remove(id)
            openConversations.removeAll { $0 === conversation }
            sidebarOrder.removeAll { $0 == id }
        }
        guard removedCurrent else { return }
        if let parentID, !detachedSessionIDs.contains(parentID), let parent = conversation(parentID) {
            activate(parent)
        } else {
            // Never retain a removed selection or borrow a detached parent's
            // presentation. The child's observer may be cancelled by reconciliation.
            let fallback = try makeConversation()
            activate(fallback)
            guard let parentID, !detachedSessionIDs.contains(parentID),
                  savedSummaries.contains(where: { $0.id == parentID && !$0.unreadable }) else { return }
            if !navigating {
                openSession(parentID)
            } else if openingSessionID == nil {
                // A rename/reorder can also reconcile cleanup. Wait for it without
                // superseding a user's subsequent navigation or restoring a stale child.
                Task { [weak self] in
                    guard let self else { return }
                    await self.waitForNavigation()
                    guard self.current === fallback, !self.navigating else { return }
                    self.openSession(parentID)
                }
            }
        }
    }

    private func applyCatalog(_ summaries: [SessionSummary]) {
        let persisted = Set(summaries.map(\.id))
        let resident = Set(conversations.compactMap(\.currentSessionID))
        // New unsaved sessions retain their creation position until their
        // first checkpoint. Resident LRU ordering is unrelated to the sidebar.
        let pending = sidebarOrder.filter {
            resident.contains($0) && (!persisted.contains($0) || registeringIDs.contains($0))
        }
        sidebarOrder = pending + summaries.map(\.id).filter { !pending.contains($0) }
        savedSummaries = summaries
    }

    private func selectCurrent() async throws {
        // Only foreground actions select a session; background saves never steal it on restart.
        let selected = savedSummaries.contains(where: { $0.id == currentSessionID }) ? currentSessionID : nil
        sessions.select(selected)
    }

    private func navigate(reportingTo destination: ChatStore? = nil,
                          _ operation: @escaping @MainActor () async throws -> Void) {
        navigating = true
        navigationError = nil
        navigationRequest += 1
        let request = navigationRequest
        navigationTask = Task {
            defer {
                if request == navigationRequest {
                    // Clear optimistic ordering even if cancelled before operation starts.
                    // Failures expose the latest confirmed catalog without replaying writes.
                    pendingSidebarOrder = nil
                    navigating = false; openingSessionID = nil; loading = nil; navigationTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                try await operation()
            }
            catch is CancellationError {}
            catch {
                if request == navigationRequest {
                    if let destination { destination.error = error.localizedDescription }
                    else { navigationError = error.localizedDescription }
                }
            }
        }
    }
}
