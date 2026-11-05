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
    private var retained: [UUID: ChatStore] = [:]
    private var loading: ChatStore?
    private var navigationTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private let provider: any ChatProvider
    private let sessions: SessionStore

    init(provider: any ChatProvider, sessions: SessionStore) throws {
        self.provider = provider
        self.sessions = sessions
        current = ChatStore(provider: try provider.makeConversationProvider(), sessions: sessions, selectOnCheckpoint: false)
        observe(current)
    }

    var messages: [Message] { current.messages }
    var draft: String {
        get { current.draft }
        set { if !navigating && !authenticating { current.draft = newValue } }
    }
    var selectedModel: String {
        get { current.selectedModel }
        set { if !busy { current.selectedModel = newValue } }
    }
    var error: String? {
        get { navigationError ?? current.error }
        set { navigationError = nil; current.error = newValue }
    }
    var account: String? { current.account }
    var connectionTitle: String { provider.connectionTitle }
    var workspace: Workspace? { current.workspace }
    var tools: ToolExecutor { current.tools }
    var autoApproveTools: Bool { current.autoApproveTools }
    var currentSessionID: UUID? { current.currentSessionID }
    var sidebarSelectionID: UUID? { openingSessionID ?? currentSessionID }
    var busy: Bool { navigating || authenticating || current.busy }
    var isSending: Bool { current.isSending }
    var isWorking: Bool { authenticating || current.busy }
    var canNavigate: Bool { !navigating && !authenticating }
    var accountBusy: Bool { authenticating || conversations.contains { $0.isSending } }
    var hasUnsavedChanges: Bool { conversations.contains { $0.hasUnsavedChanges } }
    var hasUnsentDrafts: Bool { conversations.contains { !$0.draft.isEmpty } }
    var hasRunningOperations: Bool { navigating || authenticating || conversations.contains { $0.busy } }

    private var conversations: [ChatStore] {
        var result = [current] + retained.values.filter { $0 !== current }
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
        current.currentSessionID == id ? current : retained[id]
    }

    func setAutoApproveTools(_ enabled: Bool) {
        guard canNavigate else { return }
        current.setAutoApproveTools(enabled)
    }

    func send() {
        guard canNavigate else { return }
        guard !current.busy else { return }
        navigate {
            // Select before starting; subsequent checkpoints (including background ones) only save data.
            if let id = self.currentSessionID { try await self.sessions.select(id) }
            try Task.checkCancellation()
            self.remember(self.current)
            self.current.send()
        }
    }

    func stop() {
        guard !navigating else { return }
        if authenticating { accountTask?.cancel() }
        current.stop()
    }

    func stopAll() {
        navigationTask?.cancel()
        accountTask?.cancel()
        for conversation in conversations { conversation.stop() }
    }

    func restore() { accountOperation { self.current.restore() } }
    func connect() { accountOperation { self.current.connect() } }
    func disconnect() { accountOperation { self.current.disconnect() } }

    private func accountOperation(_ start: () -> Void) {
        guard canNavigate, !conversations.contains(where: { $0.busy }) else { return }
        let identity = provider.conversationIdentity
        for conversation in conversations { conversation.setAutoApproveTools(false) }
        authenticating = true
        navigationError = nil
        start()
        accountTask = Task {
            defer { authenticating = false; accountTask = nil; prune() }
            await current.waitUntilIdle()
            if identity != provider.conversationIdentity { retained.removeAll() }
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
        guard canNavigate, id != currentSessionID else { return }
        openingSessionID = id // Keep the clicked row selected while disk I/O completes.
        navigate {
            await self.preserveCurrent()
            try Task.checkCancellation()
            let next: ChatStore
            if let existing = self.retained[id] {
                next = existing // Never restore disk state over a live runner or its draft.
            } else {
                next = try self.makeConversation()
                self.loading = next
                next.openSession(id, loadModels: false)
                await next.waitUntilIdle()
                try Task.checkCancellation()
                guard next.currentSessionID == id else {
                    throw HarnessError(next.error ?? "Could not open the saved conversation.")
                }
            }
            self.current = next
            self.remember(next)
            try await self.refreshCatalog()
            try await self.selectCurrent()
        }
    }

    func newConversation() {
        guard canNavigate else { return }
        let workspace = current.workspace
        navigate {
            await self.preserveCurrent()
            try Task.checkCancellation()
            let next = try self.makeConversation(workspace: workspace)
            self.current = next
            self.remember(next)
            try await next.saveIfIdle()
            try await self.refreshCatalog()
            try await self.selectCurrent()
        }
    }

    func selectWorkspace(_ url: URL) {
        guard canNavigate, !current.busy else { return }
        navigate {
            let loading = Task.detached(priority: .userInitiated) { try Workspace.load(url) }
            let workspace = try await withTaskCancellationHandler {
                try await loading.value
            } onCancel: { loading.cancel() }
            try Task.checkCancellation()
            try await self.replaceWorkspace(workspace)
        }
    }

    func closeWorkspace() {
        guard canNavigate, !current.busy else { return }
        navigate { try await self.replaceWorkspace(nil) }
    }

    private func replaceWorkspace(_ workspace: Workspace?) async throws {
        await preserveCurrent()
        try Task.checkCancellation()
        let next = try makeConversation(workspace: workspace)
        current = next
        remember(next)
        try await next.saveIfIdle()
        try await refreshCatalog()
        try await selectCurrent()
    }

    func renameSession(_ id: UUID, title: String) {
        guard canNavigate, sessionList.contains(where: { $0.id == id && !$0.unreadable }) else { return }
        navigate {
            // Persist an unsaved idle draft/workspace session before changing its metadata.
            if let conversation = self.conversation(id) { try await conversation.saveIfIdle(force: true) }
            try await self.sessions.rename(id: id, title: title, identity: self.provider.conversationIdentity)
            try await self.refreshCatalog()
        }
    }

    func deleteSession(_ id: UUID) {
        guard canNavigate, !isSessionRunning(id) else { return }
        navigate {
            var failure: Error?
            do { try await self.sessions.delete(id: id) }
            catch { failure = error }
            self.savedSummaries = try await self.sessions.list(identity: self.provider.conversationIdentity)
            if !self.savedSummaries.contains(where: { $0.id == id }) {
                self.retained[id] = nil
                if self.currentSessionID == id { self.current = try self.makeConversation() }
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
        observe(conversation)
        return conversation
    }

    private func observe(_ conversation: ChatStore) {
        conversation.didCheckpoint = { [weak self] in try await self?.refreshCatalog() }
        conversation.didFinish = { [weak self] in self?.prune() }
    }

    private func preserveCurrent() async {
        let conversation = current
        remember(conversation)
        do { try await conversation.saveIfIdle() }
        catch { conversation.error = error.localizedDescription }
        // Failed saves remain retained in memory, so navigation never discards the only copy.
    }

    private func remember(_ conversation: ChatStore) {
        if let id = conversation.currentSessionID { retained[id] = conversation }
    }

    private func prune() {
        retained = retained.filter { _, conversation in
            conversation === current || conversation.busy || !conversation.draft.isEmpty ||
            conversation.hasUnsavedChanges || conversation.error != nil || conversation.autoApproveTools
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
        navigationTask = Task {
            defer { navigating = false; openingSessionID = nil; loading = nil; navigationTask = nil; prune() }
            do { try await operation() }
            catch is CancellationError {}
            catch { navigationError = error.localizedDescription }
        }
    }
}
