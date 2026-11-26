import Foundation
import Observation
import CryptoKit

/// Window-local presentation of a Rust conversation. No inference loop, tool executor,
/// provider context, checkpoint writer or recovery logic lives in the frontend.
@MainActor @Observable final class ChatStore: Identifiable {
    let id = UUID()
    let provider: any ChatProvider
    private var api: AgentAPI { provider.api }
    var models: [ChatModel] = []
    var selectedModel = ""
    var selectedEffort: String?
    var systemPrompt = ""
    var searchModel = ""
    var effectiveSearchModel: String? { provider.effectiveSearchModel(searchModel, for: selectedModel) }
    var toolAvailabilityQuery: ToolAvailabilityQuery {
        ToolAvailabilityQuery(names: SessionTool.names, conversationID: currentSessionID,
                              model: requestModelID, searchModel: effectiveSearchModel,
                              captureFrontendID: api.desktop.frontendID)
    }
    var model: ChatModel? { models.first { $0.id == selectedModel } }
    var effectiveEffort: String? { model?.efforts.contains { $0.id == selectedEffort } == true ? selectedEffort : nil }
    var account: String? { provider.account }
    var hasUsableModel: Bool { model != nil && provider.isModelAvailable(selectedModel) && !hasUnsavedChanges && !deletedRemotely }
    var requestModelID: String { selectedModel }
    private(set) var messages: [Message] = []
    private(set) var queuedMessages: [Message] = []
    // Presentation intent from a local /turns receipt, never from queue or history snapshots.
    private(set) var latestImmediateSendID: UUID?
    private(set) var deletedRemotely = false { didSet { updateThinkingIndicator() } }
    var draft = ""
    var draftImages: [ImageAttachment] = []
    var draftFiles: [FileAttachment] = []
    private var uploadedFiles: [UUID: (session: UUID, file: AgentFile)] = [:]
    private(set) var isImportingAttachments = false
    var hasUnsentDraft: Bool { !draft.isEmpty || !draftImages.isEmpty || !draftFiles.isEmpty || isImportingAttachments || (!deletedRemotely && snapshot?.pendingInput.isEmpty == false) }
    var error: String?
    private(set) var currentSessionID: UUID?
    private(set) var workspace: Workspace?
    private var workspaceChosen = false
    private var commitInheritedWorkspace = false
    private(set) var isRestoringSession = false { didSet { updateThinkingIndicator() } }
    private(set) var isSending = false
    private(set) var isCompacting = false { didSet { updateThinkingIndicator() } }
    private(set) var isStopping = false { didSet { updateThinkingIndicator() } }
    private(set) var isSaving = false
    private(set) var hasUnsavedChanges = false
    private var submitting = false
    private var acceptedOperationID: UUID?
    private var snapshot: AgentSnapshot? { didSet { updateThinkingIndicator() } }
    private var operationActive: Bool { snapshot?.operation?.active == true }
    private var backendBusy: Bool { isRestoringSession || submitting || compactionTask != nil || operationActive || isStopping || clearTask != nil }
    var busy: Bool { !deletedRemotely && (backendBusy || commandTask != nil) }
    var isWaiting: Bool { !deletedRemotely && !isStopping && snapshot?.operation?.state == "running" && snapshot?.activeToolName == "wait" }
    private var compactionTask: Task<UUID?, Never>?
    private var commandTask: Task<Void, Never>?
    private var pendingCommands: [(key: String, action: @MainActor () async throws -> Void)] = []
    private var providerRemovalPending = false
    private var commandsClosed = false { didSet { updateThinkingIndicator() } }
    var canRequestCommands: Bool { !commandsClosed && !providerRemovalPending && !isRestoringSession && !configurationUncertain }

    /// Coalesce repeat actions, bind them to this conversation, and never send an idle-only
    /// mutation against a running backend operation. Settings use their latest chosen value.
    func whenIdle(_ key: String, action: @escaping @MainActor () async throws -> Void) {
        guard canRequestCommands else { return }
        if let index = pendingCommands.firstIndex(where: { $0.key == key }) { pendingCommands[index].action = action }
        else { pendingCommands.append((key, action)) }
        drainCommands()
    }
    private func drainCommands() {
        guard !commandsClosed, !providerRemovalPending, !configurationUncertain, !backendBusy, !isSaving, commandTask == nil,
              currentSessionID != nil || workspaceChosen || !pendingCommands.isEmpty,
              settingsDirty || !pendingCommands.isEmpty else { return }
        commandTask = Task {
            defer { commandTask = nil; updateSleepActivity() }
            await saveTask?.value
            do {
                while !backendBusy && !commandsClosed && !providerRemovalPending {
                    try Task.checkCancellation()
                    if settingsDirty {
                        isSaving = true
                        do { try await persistConfiguration() }
                        catch { isSaving = false; throw error }
                        isSaving = false
                    }
                    guard !pendingCommands.isEmpty else { break }
                    let command = pendingCommands.removeFirst()
                    try await command.action()
                }
            } catch {
                pendingCommands.removeAll()
                self.error = error.localizedDescription
            }
        }
    }
    /// Discard queued actions like Stop, without deleting history or closing the presentation.
    func pauseForProviderRemoval(_ id: String) -> Bool {
        let model = snapshot?.model ?? selectedModel
        let search = snapshot?.configuration.settings.searchModel ?? searchModel
        guard provider.providerID(for: model) == id
            || (!disabledTools.contains("web_search") && provider.providerID(for: search) == id)
            || ((snapshot?.activeToolName == "generate_image" || snapshot?.approval?.call.name == "generate_image") && connectionsSupportImages(id)) else { return false }
        providerRemovalPending = true
        pendingCommands.removeAll()
        commandTask?.cancel()
        return true
    }
    private func connectionsSupportImages(_ id: String) -> Bool {
        provider.connections.contains { $0.id == id && $0.supportsImageGeneration }
    }
    func finishProviderRemoval() {
        providerRemovalPending = false
        drainCommands()
    }
    func cancelPendingCommands() {
        commandsClosed = true
        pendingCommands.removeAll()
        commandTask?.cancel()
    }
    var isWorking: Bool { busy }
    private(set) var showsThinkingIndicator = false
    private var thinkingOperationID: UUID?
    private var thinkingDelayTask: Task<Void, Never>?

    /// Track each idle gap even while this session's transcript is unmounted.
    /// A different operation is a fresh gap, even without an intervening terminal snapshot.
    private func updateThinkingIndicator() {
        let operationID = !commandsClosed && !deletedRemotely && !isStopping && !isRestoringSession &&
            !isCompacting && snapshot?.showsThinkingIndicator == true ? snapshot?.operation?.id : nil
        guard operationID != thinkingOperationID else { return }
        thinkingDelayTask?.cancel()
        thinkingDelayTask = nil
        showsThinkingIndicator = false
        thinkingOperationID = operationID
        guard let operationID else { return }
        thinkingDelayTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard !Task.isCancelled, let self, self.thinkingOperationID == operationID else { return }
            self.thinkingDelayTask = nil
            self.showsThinkingIndicator = true
        }
    }
    var canEditDraft: Bool { !isRestoringSession }
    var canSelectWorkspace: Bool {
        canRequestCommands && !deletedRemotely && !busy && !isSaving && !hasUnsavedChanges &&
            !workspaceChosen && currentSessionID == nil && messages.isEmpty
    }
    private(set) var autoApproveTools: Bool
    private(set) var disabledTools: Set<String>
    var isSubagent: Bool { snapshot?.metadata.parent != nil }
    var canSelectTools: Bool {
        canRequestCommands && !isSubagent && !deletedRemotely && !deletionPending && !hasUnsavedChanges
    }
    private(set) var contextUsage: ContextUsage?
    private(set) var needsInitialWorkspaceSelection = false
    let tools = ToolApprovalState()
    var summary: SessionSummary? {
        guard var summary = snapshot.map(SessionSummary.init) else { return nil }
        if deletedRemotely {
            guard hasUnsentDraft else { return nil }
            summary.title = "Unsent draft"; summary.customTitle = nil
        }
        return summary
    }
    private static let observationLossMessage = "Lost connection to this conversation. Reopen it to reconnect; work may still be running."
    private static let deletedDraftMessage = "This conversation was deleted. Copy your unsent draft before closing it."

    /// A deleted remote conversation never resumes or resaves. Keep any local
    /// unsent draft available for copying rather than discarding another device's work.
    @discardableResult func markDeletedRemotely() -> Bool {
        guard !deletionPending, !hasUnsavedChanges,
              task == nil, compactionTask == nil, commandTask == nil, stopTask == nil, clearTask == nil, !isSaving, !isRestoringSession else { return false }
        closePresentation()
        deletedRemotely = true
        isSending = false; isCompacting = false; isStopping = false
        try? tools.apply(nil)
        messages = []
        queuedMessages = []
        // Confirmed deletion replaces only presentation warnings, never a real
        // operation/configuration failure. A stale remote `cancelling` snapshot
        // is not a local cancellation task and must not pin a removed child.
        if error == Self.observationLossMessage || error == Self.deletedDraftMessage { error = nil }
        if error == nil, hasUnsentDraft { error = Self.deletedDraftMessage }
        return true
    }
    var didCheckpoint: (() async throws -> Void)?
    /// Confirm against the catalog before exposing a read failure. A superseded
    /// read is not evidence of removal, even when its response omitted this session.
    enum CatalogPresence { case present, removed, superseded }
    var confirmPresence: (() async throws -> CatalogPresence)?
    var didFinish: (() -> Void)?
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var transcriptReader: AgentTranscriptReader?
    private var observerGeneration = UUID()
    private var resynchronizingGeneration: UUID?
    private var observationLost = false
    private var deletionPending = false
    private var settingsDirty = false
    private var configurationUncertain = false
    private var stopTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var pendingIDs: [String: UUID] = [:]
    private var imageCache: [UUID: ImageAttachment] = [:]
    private var failedImageIDs: Set<UUID> = []
    private var imageTask: Task<Void, Never>?
    private let sleepPrevention: SessionSleepPrevention
    private let observationSleep: @Sendable (Duration) async throws -> Void
    private var sleepActivity: NSObjectProtocol?

    init(provider: any ChatProvider, workspace: Workspace? = nil, defaultAutoApproveTools: Bool = true, disabledTools: Set<String> = [],
         sleepPrevention: SessionSleepPrevention = .system,
         observationSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.provider = provider
        self.workspace = workspace
        self.autoApproveTools = defaultAutoApproveTools
        self.disabledTools = disabledTools
        self.sleepPrevention = sleepPrevention
        self.observationSleep = observationSleep
        tools.resolve = { [weak self] operation, approval, approved in
            guard let self, let id = self.currentSessionID else { return }
            do {
                _ = try await self.api.request("POST", AgentAPI.path(id, "/approvals"), .object([
                    "operationID": .string(operation.uuidString.lowercased()), "approvalID": .string(approval.uuidString.lowercased()), "approved": .bool(approved)]))
            } catch {
                // The decision may have committed. Refresh even an unchanged approval
                // through a fresh authoritative reader; never resend the decision.
                try? await self.resynchronize(id)
                throw error
            }
        }
        tools.reportError = { [weak self] in self?.error = $0 }
    }

    func installModels(_ models: [ChatModel], cached: Bool = false) {
        guard !busy else { return }
        self.models = models
        if selectedModel.isEmpty { selectedModel = models.first?.id ?? "" }
    }
    func requestInitialWorkspaceSelection() { needsInitialWorkspaceSelection = workspace == nil }
    func consumeInitialWorkspaceSelection() { needsInitialWorkspaceSelection = false }
    func setInitialWorkspace(_ workspace: Workspace) throws {
        guard canSelectWorkspace else { throw ExecError("Choose a workspace in a new conversation.") }
        self.workspace = workspace
        workspaceChosen = true
        needsInitialWorkspaceSelection = false
    }
    func waitUntilIdle() async { _ = await compactionTask?.value; await task?.value; await clearTask?.value }
    func waitForPendingSave() async { await saveTask?.value }

    private var settings: AgentSettings {
        AgentSettings(systemPrompt: systemPrompt, autoApprove: autoApproveTools,
                      effort: selectedEffort, searchModel: effectiveSearchModel)
    }
    func setToolEnabled(_ name: String, _ enabled: Bool) {
        guard canSelectTools, SessionTool.names.contains(name), disabledTools.contains(name) == enabled else { return }
        // Keep the latest selection, not a queue of toggles. The existing configuration
        // drain persists it after the active operation and before the next command/turn.
        if enabled { disabledTools.remove(name) }
        else { disabledTools.insert(name) }
        scheduleSave()
    }
    var canSetAutoApproveTools: Bool {
        canRequestCommands && !deletedRemotely && !deletionPending && !hasUnsavedChanges &&
            !submitting && !isStopping && !isSaving && saveTask == nil && commandTask == nil && clearTask == nil
    }
    func setAutoApproveTools(_ enabled: Bool) {
        guard canSetAutoApproveTools, enabled != autoApproveTools else { return }
        guard let id = currentSessionID else {
            autoApproveTools = enabled
            scheduleSave()
            return
        }
        isSaving = true
        saveTask = Task {
            defer { isSaving = false; saveTask = nil; drainCommands() }
            do {
                _ = try await api.request("PUT", AgentAPI.path(id, "/auto-approve"), .object(["autoApprove": .bool(enabled)]))
            } catch {
                self.error = "Could not change Auto mode: \(error.localizedDescription)"
            }
            // The response (or a lost acknowledgement) never replaces live tool or
            // transcript state. Confirm by reading; never resend the mutation.
            guard !commandsClosed, !deletedRemotely, !deletionPending, !isStopping, !isRestoringSession,
                  currentSessionID == id else { return }
            do { try await resynchronize(id) }
            catch { self.error = self.error ?? "Could not confirm Auto mode: \(error.localizedDescription)" }
        }
    }
    private var canReconcileQueuedInput: Bool {
        canRequestCommands && !deletedRemotely && !deletionPending && !isStopping
    }
    var canCancelQueuedInput: Bool {
        canReconcileQueuedInput && !hasUnsavedChanges && !observationLost && resynchronizingGeneration != observerGeneration &&
            task == nil && compactionTask == nil && !isSaving && saveTask == nil && commandTask == nil && clearTask == nil &&
            currentSessionID != nil && snapshot?.operation != nil && !queuedMessages.isEmpty
    }
    func cancelQueuedInput(_ messageID: UUID) {
        guard canCancelQueuedInput, let id = currentSessionID, let operationID = snapshot?.operation?.id,
              queuedMessages.contains(where: { $0.id == messageID }) else { return }
        isSaving = true
        saveTask = Task {
            defer { isSaving = false; saveTask = nil; drainCommands() }
            guard canReconcileQueuedInput, currentSessionID == id, snapshot?.operation?.id == operationID,
                  queuedMessages.contains(where: { $0.id == messageID }) else { return }
            var cancellationError: String?
            do {
                let receipt = try await api.request("POST", AgentAPI.path(id, "/cancel-input"), .object([
                    "operationID": .string(operationID.uuidString.lowercased()), "messageID": .string(messageID.uuidString.lowercased())]))
                guard receipt["messageID"].string.flatMap(UUID.init(uuidString:)) == messageID else {
                    throw ExecError("The backend did not confirm the queued message ID.")
                }
            } catch {
                cancellationError = "Could not cancel queued message: \(error.localizedDescription)"
            }
            // The input may have been promoted, or the reply may have been lost
            // after cancellation. Only a snapshot changes the queue or transcript.
            guard canReconcileQueuedInput, currentSessionID == id else { return }
            if let cancellationError { error = cancellationError }
            do { try await resynchronize(id) }
            catch {
                if canReconcileQueuedInput, currentSessionID == id {
                    self.error = cancellationError ?? "Could not refresh queued messages: \(error.localizedDescription)"
                }
            }
        }
    }
    func scheduleSave(force: Bool = false) {
        settingsDirty = true
        commitInheritedWorkspace = commitInheritedWorkspace || force
        guard !busy, !providerRemovalPending, !isSaving, saveTask == nil, !commandsClosed else { return }
        saveTask = Task {
            defer { saveTask = nil; drainCommands() }
            do { try await saveIfIdle() }
            catch { self.error = error.localizedDescription }
        }
    }
    func saveIfIdle(force: Bool = false) async throws {
        guard !busy, !providerRemovalPending, !isSaving else { return }
        isSaving = true
        defer { isSaving = false; drainCommands() }
        try await persistConfiguration(allowInheritedWorkspace: force)
    }
    private func persistConfiguration(allowInheritedWorkspace: Bool = false) async throws {
        guard !deletedRemotely else { throw ExecError("This conversation was deleted.") }
        guard !configurationUncertain else { throw ExecError("The previous configuration request could not be confirmed. Reopen the conversation before making further changes.") }
        guard let workspace, !selectedModel.isEmpty else { return }
        // An inherited workspace can be saved before sending; the backend keeps it
        // editable until the first accepted input.
        guard currentSessionID != nil || workspaceChosen || commitInheritedWorkspace || allowInheritedWorkspace else { return }
        var desiredSettings = settings
        let desiredModel = selectedModel
        let desiredDisabledTools = disabledTools
        pauseObservation()
        transcriptReader = nil
        defer { observe() }
        do {
            if let id = currentSessionID {
                if snapshot?.model != desiredModel {
                    let value = try await api.request("PUT", AgentAPI.path(id, "/model"), .object(["model": .string(desiredModel)]))
                    try apply(value.decoded(AgentSnapshot.self), preserveSettings: true)
                }
                // Auto is not a queued local preference for an existing session.
                desiredSettings.autoApprove = autoApproveTools
                if snapshot?.configuration.settings != desiredSettings {
                    let value = try await api.send("PUT", AgentAPI.path(id, "/settings"), body: desiredSettings)
                    try apply(value.decoded(AgentSnapshot.self), preserveSettings: true)
                }
                if Set(snapshot?.metadata.disabledTools ?? []) != desiredDisabledTools {
                    let value = try await api.request("PATCH", AgentAPI.path(id), .object([
                        "disabledTools": .array(desiredDisabledTools.sorted().map { .string($0) })]))
                    try apply(value.decoded(AgentSnapshot.self), preserveSettings: true)
                }
            } else {
                struct Create: Encodable {
                    let model: String
                    let workspace: String
                    let settings: AgentSettings
                    let disabledTools: [String]
                }
                let value = try await api.send("POST", "/v1/conversations", body: Create(
                    model: desiredModel, workspace: workspace.root.path, settings: desiredSettings,
                    disabledTools: desiredDisabledTools.sorted()))
                try apply(value.decoded(AgentSnapshot.self), preserveSettings: true)
            }
            // Auto follows the acknowledgement, so it isn't a local edit to save again.
            desiredSettings.autoApprove = autoApproveTools
            settingsDirty = settings != desiredSettings || selectedModel != desiredModel || disabledTools != desiredDisabledTools
            hasUnsavedChanges = false
            if settingsDirty { try await persistConfiguration() }
        } catch {
            // Configuration/create may have committed. Do not retry an uncertain write.
            configurationUncertain = true
            pendingCommands.removeAll()
            hasUnsavedChanges = true
            throw error
        }
        try await didCheckpoint?()
    }

    func loadSession(_ id: UUID) async throws {
        isRestoringSession = true
        defer { isRestoringSession = false }
        pauseObservation()
        let reader = api.transcriptReader(id)
        let value = try await reader.read()
        try Task.checkCancellation()
        transcriptReader = reader
        settingsDirty = false
        configurationUncertain = false
        try apply(value)
        observe()
    }
    func reconnectIfNeeded() {
        guard !deletedRemotely, !deletionPending, observationLost || configurationUncertain, let id = currentSessionID, task == nil, compactionTask == nil else { return }
        task = Task {
            defer { task = nil }
            do { try await loadSession(id); error = snapshot?.storageError ?? snapshot?.operation?.error }
            catch { self.error = error.localizedDescription }
        }
    }
    private func pauseObservation() {
        observerGeneration = UUID()
        observer?.cancel()
        observer = nil
        // A cancelled consumer owns its old reader until it unwinds. Never let a
        // replacement observer share that reader's iterator/cancellation cleanup.
        transcriptReader = nil
    }
    private func resynchronize(_ id: UUID) async throws {
        pauseObservation()
        let generation = observerGeneration
        resynchronizingGeneration = generation
        defer {
            if resynchronizingGeneration == generation { resynchronizingGeneration = nil }
            if observerGeneration == generation { observe() }
        }
        let reader = api.transcriptReader(id)
        let value = try await reader.read()
        guard observerGeneration == generation, !Task.isCancelled else {
            await reader.close()
            return
        }
        transcriptReader = reader
        try apply(value)
    }
    func beginDeletion() {
        deletionPending = true
        pauseObservation()
    }
    func resumeAfterFailedDeletion() {
        deletionPending = false
        observe()
    }
    private func observe() {
        observer?.cancel()
        guard !commandsClosed, !deletedRemotely, !deletionPending, let id = currentSessionID else { return }
        let generation = UUID()
        observerGeneration = generation
        observationLost = false
        let reader = transcriptReader ?? api.transcriptReader(id)
        transcriptReader = reader
        let sleep = observationSleep
        observer = Task { [weak self] in
            var reader = reader
            var failures = 0
            var delay = 250
            // Retry only authoritative reads. A healthy changes connection cannot
            // recover a lost transcript lease by itself, so keep a bounded-backoff
            // recovery loop until reads succeed or this presentation is closed.
            while !Task.isCancelled {
                guard self?.observerGeneration == generation else { return }
                do {
                    while true {
                        let snapshot = try await reader.next()
                        guard let self, self.observerGeneration == generation, !Task.isCancelled else { return }
                        try self.apply(snapshot)
                        self.observationLost = false
                        if self.error == Self.observationLossMessage { self.error = nil }
                        failures = 0
                        delay = 250
                    }
                } catch {
                    await reader.close()
                    // Keep the last authoritative operation state during a read failure.
                }
                guard let self, self.observerGeneration == generation, !Task.isCancelled else { return }
                failures += 1
                if failures >= 2 {
                    if !self.observationLost {
                        let presence = (try? await self.confirmPresence?()) ?? .present
                        // Catalog reconciliation may close or replace this observer.
                        guard self.observerGeneration == generation, !Task.isCancelled else { return }
                        self.observationLost = true
                        if presence == .present, self.error == nil { self.error = Self.observationLossMessage }
                    }
                    do { try await sleep(.milliseconds(delay)) } catch { return }
                    delay = min(delay * 2, 8_000)
                }
                guard self.observerGeneration == generation, !Task.isCancelled else { return }
                // A stale cursor or rejected snapshot requires fresh authoritative
                // state. Neither reconnecting nor closing a lease replays a mutation.
                reader = self.api.transcriptReader(id)
                self.transcriptReader = reader
            }
        }
    }
    func apply(_ value: AgentSnapshot, preserveSettings: Bool = false) throws {
        if let id = currentSessionID, id != value.id { throw ExecError("The backend returned a different conversation.") }
        let wasActive = operationActive
        // Reproject on queue/row changes, not each presentation read or streamed text update.
        let queuedInputChanged = snapshot?.pendingInput != value.pendingInput ||
            (!value.pendingInput.isEmpty && (snapshot?.messages.count != value.messages.count ||
                                             snapshot?.messages.last?.id != value.messages.last?.id))
        snapshot = value
        if queuedInputChanged { updateQueuedMessages(from: value) }
        currentSessionID = value.id
        workspace = Workspace(root: URL(fileURLWithPath: value.workspace))
        if !preserveSettings && !settingsDirty {
            selectedModel = value.model
            selectedEffort = value.configuration.settings.effort
            systemPrompt = value.configuration.settings.systemPrompt
            searchModel = value.configuration.settings.searchModel ?? ""
            disabledTools = Set(value.metadata.disabledTools ?? [])
        }
        // Live policy follows authoritative state even while idle-only edits are queued.
        autoApproveTools = value.configuration.settings.autoApprove
        contextUsage = value.contextUsage
        hasUnsavedChanges = configurationUncertain || value.storageError != nil
        if let failure = value.storageError ?? value.operation?.error { error = failure }
        isStopping = stopTask != nil || value.operation?.state == "cancelling"
        isSending = value.operation?.active == true && !isCompacting
        if !operationActive { isCompacting = false }
        messages = try value.transcript(images: imageCache, pendingIDs: &pendingIDs)
        try tools.apply(value.approval)
        updateSleepActivity()
        loadImages()
        if !operationActive { drainCommands() }
        if wasActive && !operationActive {
            didFinish?()
            Task { [weak self] in
                do { try await self?.didCheckpoint?() }
                catch { self?.error = error.localizedDescription }
            }
        }
    }
    private func updateQueuedMessages(from snapshot: AgentSnapshot) {
        guard !deletedRemotely else { return }
        let next = snapshot.queuedMessages(images: imageCache)
        if next != queuedMessages { queuedMessages = next }
    }
    private func loadImages() {
        guard imageTask == nil, let snapshot,
              snapshot.imageReferences.contains(where: { imageCache[$0.id] == nil && !failedImageIDs.contains($0.id) }) else { return }
        imageTask = Task { [weak self] in
            guard let self else { return }
            defer { imageTask = nil }
            while let ref = self.snapshot?.imageReferences.first(where: { imageCache[$0.id] == nil && !failedImageIDs.contains($0.id) }) {
                do {
                    let value = try await api.get("/v1/images/\(ref.id.uuidString.lowercased())")
                    try Task.checkCancellation()
                    guard let base64 = value["base64"].string, let data = Data(base64Encoded: base64), data.count == ref.byteCount,
                          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == ref.sha256 else {
                        throw ExecError("The backend returned an invalid image.")
                    }
                    imageCache[ref.id] = ImageAttachment(id: ref.id, name: ref.name, mediaType: ref.mediaType, data: data)
                    if let snapshot = self.snapshot {
                        if snapshot.pendingInput.contains(where: { $0.images?.contains(where: { $0.id == ref.id }) == true }) {
                            updateQueuedMessages(from: snapshot)
                        }
                        let streamed = Dictionary(uniqueKeysWithValues: messages.filter { $0.status == .streaming }.map { ($0.id, $0.text) })
                        messages = try snapshot.transcript(images: imageCache, pendingIDs: &pendingIDs).map { row in
                            var row = row
                            if row.status == .streaming, let text = streamed[row.id] { row.text = text }
                            return row
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    failedImageIDs.insert(ref.id); self.error = error.localizedDescription
                }
            }
        }
    }
    @discardableResult func importAttachments(_ load: @escaping @MainActor () async throws -> AttachmentDrop.Batch) -> Task<Void, Never>? {
        guard !isImportingAttachments, canEditDraft else { return nil }
        isImportingAttachments = true
        return Task {
            defer { isImportingAttachments = false }
            do {
                let batch = try await load()
                guard draftImages.count + draftFiles.count + batch.images.count + batch.files.count <= 4 else {
                    throw ExecError("Attach up to four images or files per message.")
                }
                try ImageAttachment.validate(draftImages + batch.images)
                try FileAttachment.validate(draftFiles + batch.files)
                draftImages += batch.images
                draftFiles += batch.files
            } catch { self.error = error.localizedDescription }
        }
    }

    private var canPrepareSubmission: Bool { !isStopping && !commandsClosed && !providerRemovalPending && !hasUnsavedChanges && !Task.isCancelled }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingCompaction = compactionTask
        guard !text.isEmpty || !draftImages.isEmpty || !draftFiles.isEmpty, canEditDraft, !commandsClosed, !providerRemovalPending, !isStopping, !isImportingAttachments, !submitting, !isSaving, commandTask == nil || pendingCompaction != nil, clearTask == nil, hasUsableModel else { return }
        let steeringOperationID = operationActive ? snapshot?.operation?.id : nil
        let inputImages = draftImages
        let inputFiles = draftFiles
        let originalDraft = draft
        submitting = true
        if pendingCompaction == nil { acceptedOperationID = nil }
        error = nil
        task = Task {
            defer { submitting = false; task = nil; updateSleepActivity(); drainCommands() }
            // Preparation can be abandoned without consuming the draft. Once dispatched,
            // keep the single request alive for receipt reconciliation and exact-ID Stop.
            var requestDispatched = false
            do {
                await waitForPendingSave()
                guard canPrepareSubmission else { return }
                var steeringOperationID = steeringOperationID
                if let pendingCompaction {
                    // Wait only for acceptance, not completion. Bind this single send to
                    // that operation; a failed/uncertain compaction must not start a turn.
                    guard let operationID = await pendingCompaction.value,
                          canPrepareSubmission else { return }
                    steeringOperationID = operationID
                }
                if snapshot?.metadata.parent != nil, steeringOperationID == nil,
                   let id = currentSessionID {
                    // A child can be opened between creation and its first turn.
                    // Refresh before choosing a route; never submit a competing turn.
                    try await resynchronize(id)
                    guard canPrepareSubmission else { return }
                    guard operationActive, let operation = snapshot?.operation else {
                        throw ExecError("This sub-agent is no longer running. Send a new task in the parent session.")
                    }
                    steeringOperationID = operation.id
                }
                if steeringOperationID == nil {
                    try await persistConfiguration(allowInheritedWorkspace: true)
                    guard canPrepareSubmission else { return }
                }
                guard let id = currentSessionID else { throw ExecError("Choose a workspace and model before sending a message.") }
                // Select the local capture adapter, without granting screen or OS access.
                if steeringOperationID == nil, api.desktop.frontendID != nil, !api.desktop.enabled.contains(id) {
                    try await api.desktop.setEnabled(true, for: id)
                    guard canPrepareSubmission else { return }
                }
                var images: [AgentImage] = []
                for image in inputImages {
                    let value = try await api.request("POST", AgentAPI.path(id, "/images"), .object([
                        "name": .string(image.name), "base64": .string(image.data.base64EncodedString())]))
                    guard canPrepareSubmission else { return }
                    let ref = try value.decoded(AgentImage.self)
                    imageCache[ref.id] = ImageAttachment(id: ref.id, name: ref.name, mediaType: ref.mediaType, data: image.data)
                    images.append(ref)
                }
                var files: [String] = []
                for file in inputFiles {
                    let ref: AgentFile
                    if let uploaded = uploadedFiles[file.id], uploaded.session == id {
                        ref = uploaded.file
                    } else {
                        let value = try await api.request("POST", AgentAPI.path(id, "/files"), .object([
                            "name": .string(file.name), "base64": .string(file.data.base64EncodedString())]))
                        guard canPrepareSubmission else { return }
                        ref = try value.decoded(AgentFile.self)
                        guard ref.name == file.name, ref.byteCount == file.data.count,
                              ref.sha256.lowercased() == SHA256.hash(data: file.data).map({ String(format: "%02x", $0) }).joined() else {
                            throw ExecError("The backend returned an invalid file attachment.")
                        }
                        uploadedFiles[file.id] = (session: id, file: ref)
                    }
                    files.append(ref.id.uuidString.lowercased())
                }
                guard canPrepareSubmission else { return }
                requestDispatched = true
                if let steeringOperationID {
                    // Keep the original operation target even if it finishes during upload.
                    // A rejected/uncertain queue request must never become a new turn.
                    struct Steering: Encodable { let operationID: String; let text: String; let images: [AgentImage]; let files: [String] }
                    _ = try await api.send("POST", AgentAPI.path(id, "/steer"), body: Steering(
                        operationID: steeringOperationID.uuidString.lowercased(), text: text, images: images, files: files))
                } else {
                    struct Turn: Encodable { let text: String; let images: [AgentImage]; let files: [String] }
                    let receipt = try await api.send("POST", AgentAPI.path(id, "/turns"), body: Turn(text: text, images: images, files: files))
                    acceptedOperationID = receipt["operationID"].string.flatMap(UUID.init(uuidString:))
                    latestImmediateSendID = receipt["messageID"].string.flatMap(UUID.init(uuidString:))
                }
                if draft == originalDraft { draft = "" }
                if draftImages == inputImages { draftImages = [] }
                if draftFiles == inputFiles { draftFiles = [] }
                for file in inputFiles { uploadedFiles.removeValue(forKey: file.id) }
                // A full read reconciles even if the operation settled before HTTP acknowledgement.
                try await resynchronize(id)
                try await didCheckpoint?()
            } catch {
                self.error = error.localizedDescription
                // Never resubmit. A lost acknowledgement can follow accepted input or effects.
                if requestDispatched, let id = currentSessionID { try? await resynchronize(id) }
            }
        }
    }
    var canClear: Bool {
        canRequestCommands && !deletedRemotely && !deletionPending && clearTask == nil && commandTask == nil && !isSaving &&
            !hasUnsavedChanges && currentSessionID != nil
    }
    func clear() {
        guard canClear, let id = currentSessionID else { return }
        let originalDraft = draft
        // Let a single in-flight submission resolve before resetting, so a late
        // acknowledgement cannot create or restore work after the clear.
        let pendingSubmission = task
        let pendingStop = stopTask
        let clearBeforeSaving = operationActive || pendingSubmission != nil || pendingStop != nil
        clearTask = Task {
            defer { clearTask = nil; updateSleepActivity(); drainCommands() }
            do {
                await pendingSubmission?.value
                await pendingStop?.value
                await waitForPendingSave()
                if !clearBeforeSaving { try await persistConfiguration() }
                try Task.checkCancellation()
                pauseObservation()
                transcriptReader = nil
                defer { observe() }
                do {
                    let value = try await api.request("POST", AgentAPI.path(id, "/clear"), .object([:]))
                    try apply(value.decoded(AgentSnapshot.self), preserveSettings: clearBeforeSaving)
                } catch {
                    // The reset may have committed. Reconcile by reading, never repeat it.
                    configurationUncertain = true
                    hasUnsavedChanges = true
                    pendingCommands.removeAll()
                    throw error
                }
                acceptedOperationID = nil
                pendingIDs.removeAll()
                imageTask?.cancel()
                imageCache.removeAll()
                failedImageIDs.removeAll()
                uploadedFiles.removeAll()
                error = nil
                if clearBeforeSaving { try await persistConfiguration() }
                if draft == originalDraft, let command = ComposerCommand(originalDraft),
                   command.page == .clear || (command.page == nil && ComposerCommand.Page.clear.matches(command.query)) {
                    draft = ""
                }
                try await didCheckpoint?()
            } catch { self.error = error.localizedDescription }
        }
    }

    var canCompact: Bool {
        // Capability belongs to the backend's model, not a queued local selection.
        canRequestCommands && !messages.isEmpty && snapshot?.model == selectedModel &&
            snapshot?.supportsCompaction == true && snapshot?.pendingInput.isEmpty == true
    }
    func compact() {
        guard canCompact else { return }
        whenIdle("compact") { [weak self] in
            guard let self else { return }
            guard self.canCompact, self.snapshot?.pendingInput.isEmpty != false else {
                throw ExecError("Compaction is unavailable for the selected model or pending input.")
            }
            self.compactNow()
            _ = await self.compactionTask?.value
        }
    }
    private func compactNow() {
        guard !backendBusy, !isSaving, let id = currentSessionID else { return }
        acceptedOperationID = nil
        isCompacting = true
        compactionTask = Task {
            defer { compactionTask = nil; updateSleepActivity(); drainCommands() }
            do {
                let receipt = try await api.request("POST", AgentAPI.path(id, "/compact"), .object([:]))
                guard let operationID = receipt["operationID"].string.flatMap(UUID.init(uuidString:)) else {
                    throw ExecError("The backend did not confirm the compaction operation.")
                }
                acceptedOperationID = operationID
                try await resynchronize(id)
                return operationID
            } catch {
                self.error = error.localizedDescription
                isCompacting = operationActive
                return nil
            }
        }
    }
    func stop() {
        guard stopTask == nil, clearTask == nil else { return }
        pendingCommands.removeAll()
        commandTask?.cancel()
        // A submit may still be awaiting its receipt. Wait for its single request,
        // then target the operation actually accepted; never cancel by session alone.
        let pending = task
        let pendingCompaction = compactionTask
        let requestedID = operationActive ? snapshot?.operation?.id : nil
        isStopping = true
        stopTask = Task {
            _ = await pendingCompaction?.value
            await pending?.value
            defer { stopTask = nil; isStopping = operationActive && snapshot?.operation?.state == "cancelling"; updateSleepActivity(); drainCommands() }
            guard let id = currentSessionID else { return }
            pauseObservation()
            defer { observe() }
            do {
                let reader = api.transcriptReader(id)
                let current = try await reader.read()
                transcriptReader = reader
                try apply(current)
                guard let operation = current.operation, operation.active else { return }
                guard let target = requestedID ?? (pending != nil || pendingCompaction != nil ? acceptedOperationID : nil), operation.id == target else {
                    throw ExecError("The active operation changed or its acceptance could not be confirmed. Inspect the conversation before stopping it.")
                }
                _ = try await api.request("POST", AgentAPI.path(id, "/cancel"), .object(["operationID": .string(operation.id.uuidString.lowercased())]))
                // Explicit stop waits for cleanup even when the observer disconnected.
                while true {
                    let value = try await reader.read()
                    try apply(value)
                    if value.operation?.active != true || value.operation?.id != target { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                // The parent may save the interrupted result and remove its child
                // before this cleanup read. Only confirmed absence makes a 404
                // expected; cancellation/transport/storage failures remain actionable.
                if isSubagent, (error as? AgentHTTPError)?.status == 404,
                   (try? await confirmPresence?()) == .removed { return }
                self.error = error.localizedDescription
                isStopping = false
            }
        }
    }
    var canRequestFork: Bool { canFork }
    var canFork: Bool { canRequestCommands && !deletedRemotely && !isSaving && !hasUnsavedChanges && currentSessionID != nil }
    func copyConversation(from source: ChatStore) async throws {
        guard source.canFork, let id = source.currentSessionID else { throw ExecError("Cannot fork this conversation right now.") }
        let value = try await api.request("POST", AgentAPI.path(id, "/fork"), .object([:]))
        try apply(value.decoded(AgentSnapshot.self))
        observe()
    }
    private func updateSleepActivity() {
        if busy && sleepActivity == nil { sleepActivity = sleepPrevention.begin() }
        if !busy, let activity = sleepActivity { sleepPrevention.end(activity); sleepActivity = nil }
    }
    func closePresentation() {
        cancelPendingCommands()
        pauseObservation()
        transcriptReader = nil
        imageTask?.cancel(); imageTask = nil
        if let activity = sleepActivity { sleepPrevention.end(activity); sleepActivity = nil }
    }
}
