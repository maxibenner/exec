import Foundation
import Observation

/// Native navigation/account presentation. Rust owns all durable conversation state.
@MainActor @Observable final class ChatLibrary {
    private(set) var current: ChatStore
    private(set) var models: [ChatModel] = []
    enum SettingsTab { case modelsAndTools, systemPrompt, accounts, usage, updates }
    var settingsTab = SettingsTab.modelsAndTools
    var connectionError: String?
    private(set) var openingSessionID: UUID?
    private(set) var navigating = false
    private(set) var authenticating = false
    private var navigationError: String?
    private var modelRefreshError: String?
    private var savedSummaries: [SessionSummary] = []
    private var sidebarOrder: [UUID] = []
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
    private let residentLimit: Int
    private var restoringDefaults = false
    private var cachedUsage: CachedAccountUsage?
    private var balances: [String: [AccountBalance]] = [:]
    var accountUsage: AccountUsage? { cachedUsage?.current() }
    var displayedAccountUsage: AccountUsage? { cachedUsage?.usage }
    var accountUsageFetchedAt: Date? { cachedUsage?.fetchedAt }
    var descriptiveShellTitles: Bool { preferences.bool(forKey: ToolDisplayPreferences.descriptiveShellTitlesKey) }
    var systemPrompt = "" { didSet { guard !restoringDefaults else { return }; saveDefaults(); for item in openConversations { item.systemPrompt = systemPrompt; item.scheduleSave() } } }
    var defaultModel = "" { didSet { if defaultModel != oldValue { defaultEffort = nil }; saveDefaults() } }
    var defaultEffort: String? { didSet { saveDefaults() } }
    var defaultAutoApproveTools = true { didSet { saveDefaults() } }
    var searchModel = "" { didSet { guard !restoringDefaults else { return }; saveDefaults(); for item in openConversations { item.searchModel = searchModel; item.scheduleSave() } } }
    var defaultSessionModel: ChatModel? { models.first { $0.id == defaultModel } ?? models.first }
    var effectiveDefaultModel: String { defaultModel.isEmpty ? "" : defaultSessionModel?.id ?? "" }
    var effectiveDefaultEffort: String? { defaultSessionModel?.efforts.contains { $0.id == defaultEffort } == true ? defaultEffort : nil }
    var effectiveSearchModel: String { searchModels.first { $0.id == searchModel }?.id ?? searchModels.first?.id ?? "" }
    func setDefaultEffort(_ effort: String?) { defaultEffort = effort }

    init(provider: any ChatProvider, preferences: UserDefaults = .standard, residentLimit: Int = 8) {
        self.provider = provider
        self.preferences = preferences
        self.residentLimit = max(1, residentLimit)
        sessions = SessionCatalog(api: provider.api, preferences: preferences)
        current = ChatStore(provider: provider)
        observe(current)
        openConversations = [current]
    }
    func restore() async throws {
        try await sessions.restore()
        restoringDefaults = true
        let config = sessions.configuration
        defaultModel = config.defaultModel ?? ""
        defaultEffort = config.settings.effort
        systemPrompt = config.settings.systemPrompt
        searchModel = config.settings.searchModel ?? ""
        defaultAutoApproveTools = config.settings.autoApprove
        restoringDefaults = false
        current = try makeConversation()
        openConversations = [current]
        try await provider.refreshConnections()
        try await refreshCatalog()
        if let id = sessions.selected, savedSummaries.contains(where: { $0.id == id && !$0.unreadable }) {
            try await current.loadSession(id)
        }
        refreshModels()
        refreshAccountUsage()
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
                do { try await sessions.update { $0.defaultModel = model; $0.settings = settings } }
                catch { navigationError = error.localizedDescription; return }
                if revision == defaultsRevision { return }
            }
        }
    }
    var sidebarSessions: [SessionSummary] { sessionList.filter { !detachedSessionIDs.contains($0.id) } }
    func hasConversation(_ conversation: ChatStore) -> Bool { conversation.workspace != nil || !conversation.messages.isEmpty || conversation.currentSessionID != nil }
    var sessionList: [SessionSummary] {
        var summaries = Dictionary(uniqueKeysWithValues: savedSummaries.map { ($0.id, $0) })
        for item in openConversations { if let summary = item.summary { summaries[summary.id] = summary } }
        var result = sidebarOrder.compactMap { summaries.removeValue(forKey: $0) }
        result += savedSummaries.compactMap { summaries.removeValue(forKey: $0.id) }
        result += summaries.values.sorted { $0.id.uuidString < $1.id.uuidString }
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
    var hasRunningOperations: Bool { navigating || authenticating || defaultsTask != nil || conversations.contains { $0.busy || $0.isSaving } }
    var error: String? {
        get { navigationError ?? current.error ?? modelRefreshError }
        set { navigationError = nil; modelRefreshError = nil; current.error = newValue }
    }
    private var conversations: [ChatStore] {
        var result = openConversations
        if let loading, !result.contains(where: { $0 === loading }) { result.append(loading) }
        return result
    }
    private func conversation(_ id: UUID) -> ChatStore? { openConversations.first { $0.currentSessionID == id } }
    func isSessionRunning(_ id: UUID) -> Bool { conversation(id)?.busy == true }
    func isSessionResponding(_ id: UUID) -> Bool { conversation(id).map { $0.isSending || $0.isCompacting } == true }
    func needsApproval(_ id: UUID) -> Bool { conversation(id)?.tools.pendingApproval != nil }
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
        for item in conversations where item.busy { item.stop() }
    }
    func closePresentations() { for item in conversations { item.closePresentation() } }
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
            defer { authenticating = false; accountTask = nil; refreshModels(); refreshAccountUsage() }
            do { try await operation() }
            catch { connectionError = error.localizedDescription }
            try? await provider.refreshConnections()
            models = models.filter { provider.isModelAvailable($0.id) }
            balances = [:]; cachedUsage = nil
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
                for item in conversations { applyModels(to: item) }
                if models.isEmpty { modelRefreshError = "Could not load models. Remove and add the provider in Settings → Providers to try again." }
            } catch {
                if !Task.isCancelled { modelRefreshError = "Could not load models. Remove and add the provider in Settings → Providers to try again." }
            }
        }
    }
    private func applyModels(to conversation: ChatStore) {
        guard !conversation.busy else { return }
        let needsDefault = conversation.selectedModel.isEmpty
        conversation.installModels(models)
        conversation.systemPrompt = systemPrompt
        conversation.searchModel = searchModel
        if needsDefault { conversation.selectedModel = defaultSessionModel?.id ?? defaultModel; conversation.selectedEffort = effectiveDefaultEffort }
        if conversation.currentSessionID == nil, conversation.workspace != nil { conversation.scheduleSave() }
    }
    func accountBalance(for providerID: String) -> [AccountBalance] { balances[providerID] ?? [] }
    func refreshAccountBalance(for providerID: String) async {
        guard !authenticating, connectedProviders.contains(where: { $0.id == providerID }) else { return }
        let generation = accountGeneration
        do {
            let values = try await provider.api.get("/v1/providers/\(providerID)/balance")
            guard generation == accountGeneration, !authenticating else { return }
            balances[providerID] = values.array.compactMap { value in
                guard let amount = value["amount"].string.flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }),
                      let currency = value["currency"].string else { return nil }
                return AccountBalance(amount: amount, currency: currency)
            }
        } catch { /* Keep the last report; account observations must not fail a chat. */ }
    }
    private func refreshAccountUsage() {
        guard !authenticating, usageConnection != nil else { return }
        let generation = accountGeneration
        Task {
            guard let value = try? await provider.api.get("/v1/providers/openai/usage") else { return }
            guard generation == accountGeneration, !authenticating else { return }
            let windows = value["windows"].array.compactMap { item -> AccountUsage.Window? in
                guard let duration = item["durationSeconds"].number, let used = item["usedPercent"].number,
                      let resets = item["resetsAt"].number else { return nil }
                return .init(durationSeconds: Int(duration), usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
            }
            if !windows.isEmpty { cachedUsage = CachedAccountUsage(usage: AccountUsage(windows: windows), fetchedAt: Date(timeIntervalSince1970: (value["fetchedAt"].number ?? 0) / 1000)) }
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

    func canForkConversation(_ source: ChatStore) -> Bool {
        canModify && source.canFork && hasConversation(source) && openConversations.contains { $0 === source }
    }

    func forkConversation(_ source: ChatStore, onOpened: @escaping @MainActor () -> Void = {}) {
        guard canForkConversation(source) else { return }
        let commandDraft = source.draft
        navigate(reportingTo: source) {
            let next = try self.makeConversation()
            self.loading = next
            try await next.copyConversation(from: source)
            try await next.saveIfIdle(force: true)
            try Task.checkCancellation()
            if source.draft == commandDraft, let command = ComposerCommand(commandDraft),
               command.page == .fork || (command.page == nil && ComposerCommand.Page.fork.matches(command.query)) {
                source.draft = ""
            }
            self.activate(next)
            onOpened()
        }
    }

    func newConversation() {
        guard canNavigate else { return }
        cancelOpening()
        navigationError = nil
        do {
            let next = try makeConversation(workspace: current.workspace)
            next.requestInitialWorkspaceSelection()
            activate(next)
            next.scheduleSave()
        } catch { navigationError = error.localizedDescription }
    }

    /// Evict least recently visited idle sessions; runners and unsaved input never
    /// depend on the cache limit. Saved conversations remain in the sidebar.
    private func trimConversations() {
        for conversation in openConversations {
            guard openConversations.count > residentLimit else { break }
            guard conversation !== current,
                  conversation.currentSessionID.map(detachedSessionIDs.contains) != true,
                  !conversation.busy, !conversation.isSaving,
                  !conversation.hasUnsentDraft, !conversation.hasUnsavedChanges else { continue }
            conversation.closePresentation()
            openConversations.removeAll { $0 === conversation }
        }
    }

    func selectWorkspace(_ url: URL, in destination: ChatStore? = nil) {
        let destination = destination ?? current
        guard canModify, destination.canSelectWorkspace else { return }
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

    func renameSession(_ id: UUID, title: String) {
        guard canModify, !isSessionRunning(id), sessionList.contains(where: { $0.id == id && !$0.unreadable }) else { return }
        navigate {
            // Persist an unsaved idle draft/workspace session before changing its metadata.
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
        canModify && !isSessionRunning(id) && sessionList.contains { $0.id == id }
    }

    func deleteSession(_ id: UUID) {
        guard canDeleteSession(id) else { return }
        let wasDetached = detachedSessionIDs.contains(id)
        let rows = sidebarSessions.map(\.id)
        // Deleting a detached conversation must not change the main selection.
        // Otherwise use visible sidebar order, not activity or resident-cache order.
        let nextID: UUID? = rows.firstIndex(of: id).flatMap { index in
            index + 1 < rows.count ? rows[index + 1] : (index > 0 ? rows[index - 1] : nil)
        }
        navigate(reportingTo: wasDetached ? conversation(id) : nil) {
            await self.conversation(id)?.waitForPendingSave()
            try Task.checkCancellation()
            var failure: Error?
            do { try await self.sessions.delete(id: id) }
            catch { failure = error }
            self.savedSummaries = try await self.sessions.list()
            if !self.savedSummaries.contains(where: { $0.id == id }) {
                // Close the detached window only after deletion is confirmed by
                // the store. Failed deletion leaves its conversation available.
                self.detachedSessionIDs.remove(id)
                self.conversation(id)?.closePresentation()
                self.openConversations.removeAll { $0.currentSessionID == id }
                do {
                    if !wasDetached, let nextID {
                        if let resident = self.conversation(nextID) {
                            self.activate(resident)
                        } else {
                            let next = try self.makeConversation()
                            self.loading = next
                            try await next.loadSession(nextID)
                            try Task.checkCancellation()
                            self.activate(next)
                        }
                    } else if self.currentSessionID == id {
                        self.activate(try self.makeConversation())
                    }
                } catch {
                    // Never leave a deleted conversation active if its neighbor
                    // cannot be restored, or a cold load is cancelled.
                    if self.currentSessionID == id { self.activate(try self.makeConversation()) }
                    throw error
                }
            }
            if let failure { throw failure }
            try await self.refreshCatalog()
            try await self.selectCurrent()
        }
    }

    private func makeConversation(workspace: Workspace? = nil) throws -> ChatStore {
        let conversation = ChatStore(provider: provider, workspace: workspace, defaultAutoApproveTools: defaultAutoApproveTools)
        conversation.installModels(models)
        conversation.selectedModel = defaultSessionModel?.id ?? defaultModel
        conversation.selectedEffort = effectiveDefaultEffort
        conversation.systemPrompt = systemPrompt
        conversation.searchModel = searchModel
        observe(conversation)
        return conversation
    }
    private func observe(_ conversation: ChatStore) {
        conversation.didCheckpoint = { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            if let id = conversation.currentSessionID, !self.savedSummaries.contains(where: { $0.id == id }),
               self.registeringIDs.insert(id).inserted {
                defer { self.registeringIDs.remove(id) }
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
            self.refreshAccountUsage()
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
        applyModels(to: conversation)
        remember(conversation)
        current = conversation
        openConversations.removeAll { $0 === conversation }
        openConversations.append(conversation) // Oldest visit first, most recent last.
        // An untouched blank isn't an open document.
        openConversations.removeAll { conversation in
            conversation !== current && conversation.summary == nil && !conversation.busy && !conversation.isSaving &&
            !conversation.hasUnsavedChanges && conversation.error == nil &&
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

    private func refreshCatalog() async throws {
        catalogRequest += 1
        let request = catalogRequest
        let summaries = try await sessions.list()
        if request == catalogRequest { applyCatalog(summaries) }
    }

    private func applyCatalog(_ summaries: [SessionSummary]) {
        let persisted = Set(summaries.map(\.id))
        let resident = Set(conversations.compactMap(\.currentSessionID))
        // New unsaved sessions retain their creation position until their
        // first checkpoint. Resident LRU ordering is unrelated to the sidebar.
        sidebarOrder = sidebarOrder.filter { !persisted.contains($0) && resident.contains($0) } + summaries.map(\.id)
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
