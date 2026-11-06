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
    private var sidebarOrder: [UUID] = []
    private var catalogRequest = 0
    private(set) var openConversations: [ChatStore] = []
    private(set) var detachedSessionIDs: Set<UUID> = []

    var sidebarSessions: [SessionSummary] {
        sessionList.filter { !detachedSessionIDs.contains($0.id) }
    }
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

    private let preferences: UserDefaults
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    private var titleRequests: [UUID: UUID] = [:]
    var generatedTitlesEnabled: Bool {
        didSet {
            preferences.set(generatedTitlesEnabled, forKey: "generatedTitlesEnabled")
            if !generatedTitlesEnabled { cancelTitleGeneration() }
        }
    }
    var systemPrompt: String {
        didSet { preferences.set(systemPrompt, forKey: "systemPrompt") }
    }
    var titleModel: String {
        didSet {
            preferences.set(titleModel, forKey: "sessionTitleModel")
            cancelTitleGeneration()
        }
    }

    init(provider: any ChatProvider, sessions: SessionStore, residentLimit: Int = 8,
         preferences: UserDefaults = .standard) throws {
        self.preferences = preferences
        systemPrompt = preferences.string(forKey: "systemPrompt") ?? ""
        generatedTitlesEnabled = preferences.bool(forKey: "generatedTitlesEnabled")
        titleModel = preferences.string(forKey: "sessionTitleModel") ?? ""
        self.residentLimit = max(1, residentLimit)
        self.provider = provider
        self.sessions = sessions
        current = ChatStore(provider: try provider.makeConversationProvider(), sessions: sessions, selectOnCheckpoint: false,
                            systemPrompt: preferences.string(forKey: "systemPrompt") ?? "")
        observe(current)
        remember(current)
    }

    /// A blank runner supports account restoration but is not a chat document.
    /// Previously saved sessions remain openable even without messages/workspace.
    func hasConversation(_ conversation: ChatStore) -> Bool {
        conversation.workspace != nil || !conversation.messages.isEmpty ||
            savedSummaries.contains { $0.id == conversation.currentSessionID }
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
    var isWorking: Bool { !authenticating && current.isWorking }
    // A cold open can be superseded by another selection; mutations still serialize.
    var canNavigate: Bool { !authenticating && (!navigating || openingSessionID != nil) }
    private var canModify: Bool { !navigating && !authenticating }
    var canReorderSessions: Bool { canModify }
    var accountBusy: Bool { authenticating || conversations.contains { $0.busy || $0.isSaving } }
    var hasUnsavedChanges: Bool { conversations.contains { $0.hasUnsavedChanges } }
    var hasUnsentDrafts: Bool { conversations.contains { $0.hasUnsentDraft } }
    var hasRunningOperations: Bool {
        navigating || authenticating || selectionTask != nil || !titleTasks.isEmpty || conversations.contains { $0.busy || $0.isSaving }
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
        var ordered = sidebarOrder.compactMap { summaries.removeValue(forKey: $0) }
        ordered += savedSummaries.compactMap { summaries.removeValue(forKey: $0.id) }
        ordered += summaries.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return ordered
    }

    // Shortcuts follow the same current ordering as the sidebar, never creation
    // order or the resident cache. There is deliberately no shortcut for row 10+.
    var sessionShortcuts: [(number: Int, session: SessionSummary)] {
        sidebarSessions.prefix(9).enumerated().map { (number: $0.offset + 1, session: $0.element) }
    }

    func isSessionRunning(_ id: UUID) -> Bool { conversation(id)?.busy == true }
    func isSessionResponding(_ id: UUID) -> Bool {
        guard let conversation = conversation(id) else { return false }
        return conversation.isSending || conversation.isCompacting
    }
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

    func send(in destination: ChatStore? = nil) {
        let destination = destination ?? current
        guard canModify else { return }
        if destination.isSending || destination.isCompacting { destination.send(); return }
        guard !destination.busy else { return }
        navigate(reportingTo: destination) {
            // Detached conversations save normally, but never steal the main selection.
            if destination === self.current, let id = destination.currentSessionID {
                try await self.sessions.select(id)
            }
            try Task.checkCancellation()
            self.remember(destination)
            destination.send()
        }
    }

    func resumeQueuedMessages(in destination: ChatStore? = nil) {
        let destination = destination ?? current
        guard canModify, !destination.busy else { return }
        navigate(reportingTo: destination) {
            if destination === self.current, let id = destination.currentSessionID {
                try await self.sessions.select(id)
            }
            try Task.checkCancellation()
            self.remember(destination)
            destination.resumeQueuedMessages()
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
        cancelTitleGeneration()
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
        cancelTitleGeneration()
        let identity = provider.conversationIdentity
        for conversation in conversations { conversation.suspendAutoApproval() }
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
            if identity != provider.conversationIdentity {
                detachedSessionIDs.removeAll()
                openConversations = [current]
            }
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
            openConversations.removeAll { $0 === conversation }
        }
    }

    func selectWorkspace(_ url: URL, in destination: ChatStore? = nil) {
        let destination = destination ?? current
        guard canModify, !destination.busy, destination.messages.isEmpty else { return }
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
            try await self.sessions.reorder(reordered, identity: self.provider.conversationIdentity)
            try await self.refreshCatalog()
        }
    }

    func renameSession(_ id: UUID, title: String) {
        guard canModify, sessionList.contains(where: { $0.id == id && !$0.unreadable }) else { return }
        cancelTitleGeneration(for: id)
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

    func canDeleteSession(_ id: UUID) -> Bool {
        canModify && !isSessionRunning(id) && sessionList.contains { $0.id == id }
    }

    func deleteSession(_ id: UUID) {
        guard canDeleteSession(id) else { return }
        cancelTitleGeneration(for: id)
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
            self.savedSummaries = try await self.sessions.list(identity: self.provider.conversationIdentity)
            if !self.savedSummaries.contains(where: { $0.id == id }) {
                // Close the detached window only after deletion is confirmed by
                // the store. Failed deletion leaves its conversation available.
                self.detachedSessionIDs.remove(id)
                self.openConversations.removeAll { $0.currentSessionID == id }
                do {
                    if let nextID {
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
        let conversation = ChatStore(provider: try provider.makeConversationProvider(), sessions: sessions,
                                     selectOnCheckpoint: false, newConversation: true, workspace: workspace,
                                     systemPrompt: systemPrompt)
        conversation.models = models
        conversation.selectedModel = current.selectedModel.isEmpty ? models.first?.id ?? "" : current.selectedModel
        conversation.selectedEffort = current.effectiveEffort
        observe(conversation)
        return conversation
    }

    private func cancelTitleGeneration(for id: UUID? = nil) {
        let ids = id.map { [$0] } ?? Array(titleTasks.keys)
        for id in ids {
            titleTasks.removeValue(forKey: id)?.cancel()
            titleRequests.removeValue(forKey: id)
        }
    }

    private func generateTitle(for conversation: ChatStore, message: Message) {
        guard let id = conversation.currentSessionID else { return }
        cancelTitleGeneration(for: id)
        guard generatedTitlesEnabled, models.contains(where: { $0.id == titleModel }),
              let summary = sessionList.first(where: { $0.id == id }) else { return }
        let request = UUID()
        let identity = provider.conversationIdentity
        let model = titleModel
        titleRequests[id] = request
        titleTasks[id] = Task { [weak self, provider, sessions] in
            defer {
                if self?.titleRequests[id] == request {
                    self?.titleTasks[id] = nil
                    self?.titleRequests[id] = nil
                }
            }
            do {
                let title = try await SessionTitleGenerator.generate(provider: provider, model: model,
                                                                    title: summary.customTitle ?? "", message: message.text)
                guard let self, !Task.isCancelled, self.titleRequests[id] == request,
                      identity == provider.conversationIdentity else { return }
                try await sessions.rename(id: id, title: title, identity: identity)
                try await self.refreshCatalog()
            } catch {
                // Optional metadata must not fail the chat turn or retry inference.
            }
        }
    }

    private func observe(_ conversation: ChatStore) {
        conversation.didLoadSessionList = { [weak self, weak conversation] summaries in
            guard let self, let conversation, conversation === self.current else { return }
            self.catalogRequest += 1
            self.applyCatalog(summaries)
        }
        conversation.didSendMessage = { [weak self, weak conversation] message in
            guard let conversation else { return }
            self?.generateTitle(for: conversation, message: message)
        }
        conversation.didStop = { [weak self, weak conversation] in
            guard let id = conversation?.currentSessionID else { return }
            self?.cancelTitleGeneration(for: id)
        }
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
        if let id = conversation.currentSessionID, !sidebarOrder.contains(id),
           !savedSummaries.contains(where: { $0.id == id }) {
            sidebarOrder.insert(id, at: 0)
        }
    }

    private func activate(_ conversation: ChatStore) {
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
        if request == catalogRequest { applyCatalog(summaries) }
    }

    private func applyCatalog(_ summaries: [SessionSummary]) {
        let persisted = Set(summaries.map(\.id))
        let resident = Set(conversations.filter { $0.conversationIdentity == provider.conversationIdentity }.compactMap(\.currentSessionID))
        // New unsaved sessions retain their creation position until their
        // first checkpoint. Resident LRU ordering is unrelated to the sidebar.
        sidebarOrder = sidebarOrder.filter { !persisted.contains($0) && resident.contains($0) } + summaries.map(\.id)
        savedSummaries = summaries
    }

    private func selectCurrent() async throws {
        // Only foreground actions select a session; background saves never steal it on restart.
        let selected = savedSummaries.contains(where: { $0.id == currentSessionID }) ? currentSessionID : nil
        try await sessions.select(selected)
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
