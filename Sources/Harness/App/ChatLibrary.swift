import Foundation
import Observation

/// Owns navigation and account-wide actions. Each conversation keeps its own runner and provider context.
@MainActor @Observable final class ChatLibrary {
    private(set) var current: ChatStore
    private(set) var models: [ChatModel] = []
    private(set) var openingSessionID: UUID?
    private(set) var navigating = false
    private(set) var authenticating = false
    private var navigationError: String?
    private var savedSummaries: [SessionSummary] = []
    private var catalogRequest = 0
    private(set) var openConversations: [ChatStore] = []
    private var loading: ChatStore?
    private var navigationTask: Task<Void, Never>?
    private var navigationRequest = 0
    private var selectionTask: Task<Void, Never>?
    private var selectionRequest = 0
    private var accountTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var usageRequest = 0
    private(set) var accountUsage: AccountUsage?
    private let provider: any ChatProvider
    private let residentLimit: Int
    private let sessions: SessionStore

    init(provider: any ChatProvider, sessions: SessionStore, residentLimit: Int = 8) throws {
        self.residentLimit = max(1, residentLimit)
        self.provider = provider
        self.sessions = sessions
        current = ChatStore(provider: try provider.makeConversationProvider(), sessions: sessions, selectOnCheckpoint: false)
        observe(current)
        remember(current)
    }

    var messages: [Message] { current.messages }
    var draft: String {
        get { current.draft }
        set { if !navigating && !authenticating { current.draft = newValue } }
    }
    var selectedModel: String {
        get { current.selectedModel }
        set {
            guard !busy, newValue != current.selectedModel else { return }
            current.selectedModel = newValue
            current.scheduleSave()
        }
    }
    var selectedEffort: String? {
        get { current.effectiveEffort }
        set {
            guard !busy, newValue == nil || current.model?.efforts.contains(where: { $0.id == newValue }) == true else { return }
            current.selectedEffort = newValue
            current.scheduleSave()
        }
    }
    var error: String? {
        get { navigationError ?? current.error }
        set { navigationError = nil; current.error = newValue }
    }
    var account: String? { current.account }
    var connectionTitle: String { provider.connectionTitle }
    var workspace: Workspace? { current.workspace }
    var canSelectWorkspace: Bool { canModify && !current.busy && current.messages.isEmpty }
    var tools: ToolExecutor { current.tools }
    var autoApproveTools: Bool { current.autoApproveTools }
    var currentSessionID: UUID? { current.currentSessionID }
    var sidebarSelectionID: UUID? { openingSessionID ?? currentSessionID }
    var busy: Bool { navigating || authenticating || current.busy }
    var isSending: Bool { current.isSending }
    var isWorking: Bool { authenticating || current.busy }
    // A cold open can be superseded by another selection; mutations still serialize.
    var canNavigate: Bool { !authenticating && (!navigating || openingSessionID != nil) }
    private var canModify: Bool { !navigating && !authenticating }
    var accountBusy: Bool { authenticating || conversations.contains { $0.busy || $0.isSaving } }
    var hasUnsavedChanges: Bool { conversations.contains { $0.hasUnsavedChanges } }
    var hasUnsentDrafts: Bool { conversations.contains { $0.hasUnsentDraft } }
    var hasRunningOperations: Bool {
        navigating || authenticating || selectionTask != nil || conversations.contains { $0.busy || $0.isSaving }
    }

    private var conversations: [ChatStore] {
        var result = openConversations
        if let loading, !result.contains(where: { $0 === loading }) { result.append(loading) }
        return result
    }

    var sessionList: [SessionSummary] {
        var summaries = Dictionary(uniqueKeysWithValues: savedSummaries.map { ($0.id, $0) })
        for conversation in conversations where conversation.conversationIdentity == provider.conversationIdentity {
            if var summary = conversation.summary {
                if let title = summaries[summary.id]?.customTitle {
                    summary.title = title
                    summary.customTitle = title
                }
                summaries[summary.id] = summary
            }
        }
        return summaries.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    func isSessionRunning(_ id: UUID) -> Bool { conversation(id)?.busy == true }
    func needsApproval(_ id: UUID) -> Bool { conversation(id)?.tools.pendingApproval != nil }
    func needsAttention(_ id: UUID) -> Bool {
        guard let conversation = conversation(id) else { return false }
        return conversation.error != nil || conversation.hasUnsavedChanges
    }
    private func conversation(_ id: UUID) -> ChatStore? {
        openConversations.first { $0.currentSessionID == id }
    }

    func setAutoApproveTools(_ enabled: Bool) {
        guard canModify else { return }
        current.setAutoApproveTools(enabled)
    }

    func send() {
        guard canModify else { return }
        if current.isSending { current.send(); return }
        guard !current.busy else { return }
        navigate {
            // Select before starting; subsequent checkpoints (including background ones) only save data.
            if let id = self.currentSessionID { try await self.sessions.select(id) }
            try Task.checkCancellation()
            self.remember(self.current)
            self.current.send()
        }
    }

    func resumeQueuedMessages() {
        guard canModify, !current.busy else { return }
        navigate {
            if let id = self.currentSessionID { try await self.sessions.select(id) }
            try Task.checkCancellation()
            self.remember(self.current)
            self.current.resumeQueuedMessages()
        }
    }

    var canCompact: Bool { canModify && current.canCompact }
    func compact() {
        guard canCompact else { return }
        current.compact()
    }

    func stop() {
        guard !navigating else { return }
        if authenticating { accountTask?.cancel() }
        current.stop()
    }

    func stopAll() {
        navigationTask?.cancel()
        accountTask?.cancel()
        usageTask?.cancel()
        for conversation in conversations { conversation.stop() }
    }

    func restore() { accountOperation { self.current.restore() } }
    func connect() { accountOperation { self.current.connect() } }
    func disconnect() { accountOperation { self.current.disconnect() } }

    private func accountOperation(_ start: () -> Void) {
        guard canModify, !conversations.contains(where: { $0.busy || $0.isSaving }) else { return }
        let identity = provider.conversationIdentity
        for conversation in conversations { conversation.setAutoApproveTools(false) }
        authenticating = true
        usageTask?.cancel()
        usageRequest += 1
        accountUsage = nil
        navigationError = nil
        start()
        accountTask = Task {
            defer {
                authenticating = false; accountTask = nil
                if !Task.isCancelled { refreshAccountUsage() }
            }
            await current.waitUntilIdle()
            if identity != provider.conversationIdentity { openConversations = [current] }
            models = current.models
            for conversation in conversations {
                conversation.account = provider.account
                conversation.models = models
            }
            savedSummaries = current.sessionList
            remember(current)
            do {
                try await refreshCatalog()
                if currentSessionID != nil { try await selectCurrent() }
            }
            catch { navigationError = error.localizedDescription }
        }
    }

    func openSession(_ id: UUID) {
        guard canNavigate else { return }
        cancelOpening()
        navigationError = nil
        if let existing = conversation(id) {
            activate(existing) // No snapshot I/O or provider restoration on the resident path.
            return
        }
        openingSessionID = id
        navigate {
            let next = try self.makeConversation()
            self.loading = next
            try await next.loadSession(id)
            try Task.checkCancellation()
            self.activate(next)
        }
    }

    func newConversation() {
        guard canNavigate else { return }
        cancelOpening()
        navigationError = nil
        do {
            let next = try makeConversation(workspace: current.workspace)
            activate(next)
            next.scheduleSave()
        } catch { navigationError = error.localizedDescription }
    }

    /// Evict least recently visited idle sessions; runners and unsaved input never
    /// depend on the cache limit. Saved conversations remain in the sidebar.
    private func trimConversations() {
        for conversation in openConversations {
            guard openConversations.count > residentLimit else { break }
            guard conversation !== current, !conversation.busy, !conversation.isSaving,
                  !conversation.hasUnsentDraft, !conversation.hasUnsavedChanges else { continue }
            openConversations.removeAll { $0 === conversation }
        }
    }

    func selectWorkspace(_ url: URL) {
        guard canSelectWorkspace else { return }
        navigate {
            let loading = Task.detached(priority: .userInitiated) { try Workspace.load(url) }
            let workspace = try await withTaskCancellationHandler {
                try await loading.value
            } onCancel: { loading.cancel() }
            await self.current.waitForPendingSave()
            try Task.checkCancellation()
            try self.current.setInitialWorkspace(workspace)
            try await self.current.saveIfIdle()
            try await self.refreshCatalog()
            try await self.selectCurrent()
        }
    }

    func renameSession(_ id: UUID, title: String) {
        guard canModify, sessionList.contains(where: { $0.id == id && !$0.unreadable }) else { return }
        navigate {
            // Persist an unsaved idle draft/workspace session before changing its metadata.
            if let conversation = self.conversation(id) {
                await conversation.waitForPendingSave()
                try Task.checkCancellation()
                try await conversation.saveIfIdle(force: true)
            }
            try await self.sessions.rename(id: id, title: title, identity: self.provider.conversationIdentity)
            try await self.refreshCatalog()
        }
    }

    func deleteSession(_ id: UUID) {
        guard canModify, !isSessionRunning(id) else { return }
        navigate {
            await self.conversation(id)?.waitForPendingSave()
            try Task.checkCancellation()
            var failure: Error?
            do { try await self.sessions.delete(id: id) }
            catch { failure = error }
            self.savedSummaries = try await self.sessions.list(identity: self.provider.conversationIdentity)
            if !self.savedSummaries.contains(where: { $0.id == id }) {
                self.openConversations.removeAll { $0.currentSessionID == id }
                if self.currentSessionID == id { self.activate(try self.makeConversation()) }
            }
            if let failure { throw failure }
            try await self.refreshCatalog()
            try await self.selectCurrent()
        }
    }

    private func makeConversation(workspace: Workspace? = nil) throws -> ChatStore {
        let conversation = ChatStore(provider: try provider.makeConversationProvider(), sessions: sessions,
                                     selectOnCheckpoint: false, newConversation: true, workspace: workspace)
        conversation.models = models
        conversation.selectedModel = current.selectedModel.isEmpty ? models.first?.id ?? "" : current.selectedModel
        conversation.selectedEffort = current.effectiveEffort
        observe(conversation)
        return conversation
    }

    private func observe(_ conversation: ChatStore) {
        conversation.didCheckpoint = { [weak self] in try await self?.refreshCatalog() }
        conversation.didFinish = { [weak self] in
            self?.trimConversations()
            self?.refreshAccountUsage()
        }
    }

    private func refreshAccountUsage() {
        guard !authenticating else { return }
        usageTask?.cancel()
        usageRequest += 1
        let request = usageRequest
        let identity = provider.conversationIdentity
        guard provider.account != nil else { accountUsage = nil; return }
        usageTask = Task { [weak self, provider] in
            // Optional account metadata must never fail a chat turn or retry inference.
            let usage = try? await provider.accountUsage()
            guard let self, !Task.isCancelled, request == self.usageRequest,
                  identity == provider.conversationIdentity else { return }
            self.accountUsage = usage
            self.usageTask = nil
        }
    }

    private func remember(_ conversation: ChatStore) {
        if !openConversations.contains(where: { $0 === conversation }) { openConversations.append(conversation) }
    }

    private func activate(_ conversation: ChatStore) {
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

    /// Coalesce rapid selections, without blocking the visible tab on an index write.
    /// Background checkpoints never enter this foreground-selection path.
    private func persistSelection() {
        selectionRequest += 1
        guard selectionTask == nil else { return }
        selectionTask = Task {
            defer { selectionTask = nil }
            while true {
                let request = selectionRequest
                let id = currentSessionID
                do { try await sessions.select(id) }
                catch {
                    if request == selectionRequest { navigationError = error.localizedDescription }
                }
                if request == selectionRequest { return }
            }
        }
    }

    private func refreshCatalog() async throws {
        catalogRequest += 1
        let request = catalogRequest
        let summaries = try await sessions.list(identity: provider.conversationIdentity)
        if request == catalogRequest { savedSummaries = summaries }
    }

    private func selectCurrent() async throws {
        // Only foreground actions select a session; background saves never steal it on restart.
        let selected = savedSummaries.contains(where: { $0.id == currentSessionID }) ? currentSessionID : nil
        try await sessions.select(selected)
    }

    private func navigate(_ operation: @escaping @MainActor () async throws -> Void) {
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
            catch { if request == navigationRequest { navigationError = error.localizedDescription } }
        }
    }
}
