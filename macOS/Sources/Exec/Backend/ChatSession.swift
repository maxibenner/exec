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
    var model: ChatModel? { models.first { $0.id == selectedModel } }
    var effectiveEffort: String? { model?.efforts.contains { $0.id == selectedEffort } == true ? selectedEffort : nil }
    var account: String? { provider.account }
    var hasUsableModel: Bool { model != nil && provider.isModelAvailable(selectedModel) && !hasUnsavedChanges && !deletedRemotely }
    var requestModelID: String { selectedModel }
    private(set) var messages: [Message] = []
    private(set) var deletedRemotely = false
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
    private(set) var isRestoringSession = false
    private(set) var isSending = false
    private(set) var isCompacting = false
    private(set) var isStopping = false
    private(set) var isSaving = false
    private(set) var hasUnsavedChanges = false
    private var submitting = false
    private var acceptedOperationID: UUID?
    private var snapshot: AgentSnapshot?
    private var operationActive: Bool { snapshot?.operation?.active == true }
    private var backendBusy: Bool { isRestoringSession || submitting || operationActive || isStopping }
    var busy: Bool { !deletedRemotely && (backendBusy || commandTask != nil) }
    private var commandTask: Task<Void, Never>?
    private var pendingCommands: [(key: String, action: @MainActor () async throws -> Void)] = []
    private var commandsClosed = false
    var canRequestCommands: Bool { !commandsClosed && !isRestoringSession && !configurationUncertain }

    /// Coalesce repeat actions, bind them to this conversation, and never send an idle-only
    /// mutation against a running backend operation. Settings use their latest chosen value.
    func whenIdle(_ key: String, action: @escaping @MainActor () async throws -> Void) {
        guard canRequestCommands else { return }
        if let index = pendingCommands.firstIndex(where: { $0.key == key }) { pendingCommands[index].action = action }
        else { pendingCommands.append((key, action)) }
        drainCommands()
    }
    private func drainCommands() {
        guard !commandsClosed, !configurationUncertain, !backendBusy, !isSaving, commandTask == nil,
              currentSessionID != nil || workspaceChosen || !pendingCommands.isEmpty,
              settingsDirty || !pendingCommands.isEmpty else { return }
        commandTask = Task {
            defer { commandTask = nil; updateSleepActivity() }
            await saveTask?.value
            do {
                while !backendBusy && !commandsClosed {
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
    func cancelPendingCommands() {
        commandsClosed = true
        pendingCommands.removeAll()
        commandTask?.cancel()
    }
    var isWorking: Bool { busy }
    var canEditDraft: Bool { !isRestoringSession && !isStopping }
    var canSelectWorkspace: Bool { !busy && !isSaving && !workspaceChosen && currentSessionID == nil && messages.isEmpty }
    private(set) var autoApproveTools: Bool
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
    private static let deletedDraftMessage = "This conversation was deleted on another device. Copy your unsent draft before closing it."

    /// A deleted remote conversation never resumes or resaves. Keep any local
    /// unsent draft available for copying rather than discarding another device's work.
    @discardableResult func markDeletedRemotely() -> Bool {
        guard !deletionPending, !hasUnsavedChanges,
              task == nil, commandTask == nil, stopTask == nil, !isSaving, !isRestoringSession else { return false }
        closePresentation()
        deletedRemotely = true
        isSending = false; isCompacting = false; isStopping = false
        try? tools.apply(nil)
        messages = []
        // Confirmed deletion replaces only presentation warnings, never a real
        // operation/configuration failure. A stale remote `cancelling` snapshot
        // is not a local cancellation task and must not pin a removed child.
        if error == Self.observationLossMessage || error == Self.deletedDraftMessage { error = nil }
        if error == nil, hasUnsentDraft { error = Self.deletedDraftMessage }
        return true
    }
    var didCheckpoint: (() async throws -> Void)?
    /// Confirm against the catalog before exposing a read failure. False means
    /// absence was confirmed or a newer read superseded this one; a 404 alone
    /// is never evidence of deletion.
    var confirmObservationLoss: (() async -> Bool)?
    var didFinish: (() -> Void)?
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var transcriptReader: AgentTranscriptReader?
    private var observerGeneration = UUID()
    private var observationLost = false
    private var deletionPending = false
    private var settingsDirty = false
    private var configurationUncertain = false
    private var stopTask: Task<Void, Never>?
    private var pendingIDs: [String: UUID] = [:]
    private var imageCache: [UUID: ImageAttachment] = [:]
    private var failedImageIDs: Set<UUID> = []
    private var imageTask: Task<Void, Never>?
    private let sleepPrevention: SessionSleepPrevention
    private var sleepActivity: NSObjectProtocol?

    init(provider: any ChatProvider, workspace: Workspace? = nil, defaultAutoApproveTools: Bool = true,
         sleepPrevention: SessionSleepPrevention = .system) {
        self.provider = provider
        self.workspace = workspace
        self.autoApproveTools = defaultAutoApproveTools
        self.sleepPrevention = sleepPrevention
        tools.resolve = { [weak self] operation, approval, approved in
            guard let self, let id = self.currentSessionID else { return }
            _ = try await self.api.request("POST", AgentAPI.path(id, "/approvals"), .object([
                "operationID": .string(operation.uuidString.lowercased()), "approvalID": .string(approval.uuidString.lowercased()), "approved": .bool(approved)]))
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
    func waitUntilIdle() async { await task?.value }
    func waitForPendingSave() async { await saveTask?.value }

    private var settings: AgentSettings {
        AgentSettings(systemPrompt: systemPrompt, autoApprove: autoApproveTools,
                      effort: selectedEffort, searchModel: !searchModel.isEmpty && provider.providerID(for: searchModel) == provider.providerID(for: selectedModel) ? searchModel : nil)
    }
    func setAutoApproveTools(_ enabled: Bool) {
        guard canRequestCommands else { return }
        autoApproveTools = enabled
        scheduleSave()
    }
    func scheduleSave(force: Bool = false) {
        settingsDirty = true
        commitInheritedWorkspace = commitInheritedWorkspace || force
        guard !busy, !isSaving, saveTask == nil, !commandsClosed else { return }
        saveTask = Task {
            defer { saveTask = nil; drainCommands() }
            do { try await saveIfIdle() }
            catch { self.error = error.localizedDescription }
        }
    }
    func saveIfIdle(force: Bool = false) async throws {
        guard !busy, !isSaving else { return }
        isSaving = true
        defer { isSaving = false; drainCommands() }
        try await persistConfiguration(allowInheritedWorkspace: force)
    }
    private func persistConfiguration(allowInheritedWorkspace: Bool = false) async throws {
        guard !deletedRemotely else { throw ExecError("This conversation was deleted on another device.") }
        guard !configurationUncertain else { throw ExecError("The previous configuration request could not be confirmed. Reopen the conversation before making further changes.") }
        guard let workspace, !selectedModel.isEmpty else { return }
        // A newly inherited workspace is a suggestion, not an explicit choice. Do not
        // create an immutable Rust session until selection, sending, or leaving a draft.
        guard currentSessionID != nil || workspaceChosen || commitInheritedWorkspace || allowInheritedWorkspace else { return }
        let desiredSettings = settings
        let desiredModel = selectedModel
        pauseObservation()
        transcriptReader = nil
        defer { observe() }
        do {
            if let id = currentSessionID {
                if snapshot?.model != desiredModel {
                    let value = try await api.request("PUT", AgentAPI.path(id, "/model"), .object(["model": .string(desiredModel)]))
                    try apply(value.decoded(AgentSnapshot.self), preserveSettings: true)
                }
                if snapshot?.configuration.settings != desiredSettings {
                    let value = try await api.send("PUT", AgentAPI.path(id, "/settings"), body: desiredSettings)
                    try apply(value.decoded(AgentSnapshot.self), preserveSettings: true)
                }
            } else {
                struct Create: Encodable { let model: String; let workspace: String; let settings: AgentSettings }
                let value = try await api.send("POST", "/v1/conversations", body: Create(model: desiredModel, workspace: workspace.root.path, settings: desiredSettings))
                try apply(value.decoded(AgentSnapshot.self), preserveSettings: true)
            }
            settingsDirty = settings != desiredSettings || selectedModel != desiredModel
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
        guard !deletedRemotely, !deletionPending, observationLost || configurationUncertain, let id = currentSessionID, task == nil else { return }
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
    }
    private func resynchronize(_ id: UUID) async throws {
        pauseObservation()
        defer { observe() }
        let reader = api.transcriptReader(id)
        let value = try await reader.read()
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
        observer = Task { [weak self] in
            var reader = reader
            // Recover only the read-only cursor, once. Never replay a mutation.
            for attempt in 0..<2 {
                guard self?.observerGeneration == generation, !Task.isCancelled else { return }
                do {
                    while true {
                        let snapshot = try await reader.next()
                        guard let self, self.observerGeneration == generation, !Task.isCancelled else { return }
                        try self.apply(snapshot)
                    }
                } catch {
                    // Keep the last authoritative operation state during a read failure.
                }
                guard let self, self.observerGeneration == generation, !Task.isCancelled else { return }
                if attempt == 1 {
                    let reportLoss = await self.confirmObservationLoss?() ?? true
                    // Catalog reconciliation can close this presentation, or a
                    // new load/deletion can replace the observer while awaiting it.
                    guard self.observerGeneration == generation, !Task.isCancelled else { return }
                    self.observationLost = true
                    if reportLoss, self.error == nil {
                        self.error = Self.observationLossMessage
                    }
                    // Keep the last known operation ownership. Disconnection is not completion.
                } else {
                    // A stale cursor, partial page read, or rejected snapshot must
                    // recover from fresh authoritative state, not skip an unchanged page.
                    reader = self.api.transcriptReader(id)
                    self.transcriptReader = reader
                }
            }
        }
    }
    func apply(_ value: AgentSnapshot, preserveSettings: Bool = false) throws {
        if let id = currentSessionID, id != value.id { throw ExecError("The backend returned a different conversation.") }
        let wasActive = operationActive
        snapshot = value
        currentSessionID = value.id
        workspace = Workspace(root: URL(fileURLWithPath: value.workspace))
        if !preserveSettings && !settingsDirty {
            selectedModel = value.model
            selectedEffort = value.configuration.settings.effort
            systemPrompt = value.configuration.settings.systemPrompt
            searchModel = value.configuration.settings.searchModel ?? ""
            autoApproveTools = value.configuration.settings.autoApprove
        }
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
    private func loadImages() {
        guard imageTask == nil, let snapshot,
              snapshot.imageReferences.contains(where: { imageCache[$0.id] == nil && !failedImageIDs.contains($0.id) }) else { return }
        imageTask = Task { [weak self] in
            guard let self else { return }
            defer { imageTask = nil }
            while let ref = self.snapshot?.imageReferences.first(where: { imageCache[$0.id] == nil && !failedImageIDs.contains($0.id) }) {
                do {
                    let value = try await api.get("/v1/images/\(ref.id.uuidString.lowercased())")
                    guard let base64 = value["base64"].string, let data = Data(base64Encoded: base64), data.count == ref.byteCount,
                          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == ref.sha256 else {
                        throw ExecError("The backend returned an invalid image.")
                    }
                    imageCache[ref.id] = ImageAttachment(id: ref.id, name: ref.name, mediaType: ref.mediaType, data: data)
                    if let snapshot = self.snapshot {
                        let streamed = Dictionary(uniqueKeysWithValues: messages.filter { $0.status == .streaming }.map { ($0.id, $0.text) })
                        messages = try snapshot.transcript(images: imageCache, pendingIDs: &pendingIDs).map { row in
                            var row = row
                            if row.status == .streaming, let text = streamed[row.id] { row.text = text }
                            return row
                        }
                    }
                } catch { failedImageIDs.insert(ref.id); self.error = error.localizedDescription }
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

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftImages.isEmpty || !draftFiles.isEmpty, canEditDraft, !isImportingAttachments, !submitting, !isSaving, commandTask == nil, hasUsableModel else { return }
        if operationActive && isCompacting {
            error = "Wait for compaction to finish before sending a message."
            return
        }
        let steeringOperationID = operationActive ? snapshot?.operation?.id : nil
        let inputImages = draftImages
        let inputFiles = draftFiles
        let originalDraft = draft
        submitting = true
        acceptedOperationID = nil
        error = nil
        task = Task {
            defer { submitting = false; task = nil; updateSleepActivity(); drainCommands() }
            do {
                await waitForPendingSave()
                var steeringOperationID = steeringOperationID
                if snapshot?.metadata.parent != nil, steeringOperationID == nil,
                   let id = currentSessionID {
                    // A child can be opened between creation and its first turn.
                    // Refresh before choosing a route; never submit a competing turn.
                    try await resynchronize(id)
                    guard operationActive, let operation = snapshot?.operation else {
                        throw ExecError("This sub-agent is no longer running. Send a new task in the parent session.")
                    }
                    steeringOperationID = operation.id
                }
                if steeringOperationID == nil { try await persistConfiguration(allowInheritedWorkspace: true) }
                guard let id = currentSessionID else { throw ExecError("Choose a workspace and model before sending a message.") }
                // Select the local capture adapter, without granting screen or OS access.
                if steeringOperationID == nil, api.desktop.frontendID != nil, !api.desktop.enabled.contains(id) {
                    try await api.desktop.setEnabled(true, for: id)
                }
                var images: [AgentImage] = []
                for image in inputImages {
                    let value = try await api.request("POST", AgentAPI.path(id, "/images"), .object([
                        "name": .string(image.name), "base64": .string(image.data.base64EncodedString())]))
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
                        ref = try value.decoded(AgentFile.self)
                        guard ref.name == file.name, ref.byteCount == file.data.count,
                              ref.sha256.lowercased() == SHA256.hash(data: file.data).map({ String(format: "%02x", $0) }).joined() else {
                            throw ExecError("The backend returned an invalid file attachment.")
                        }
                        uploadedFiles[file.id] = (session: id, file: ref)
                    }
                    files.append(ref.id.uuidString.lowercased())
                }
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
                if let id = currentSessionID { try? await resynchronize(id) }
            }
        }
    }
    var canCompact: Bool { canRequestCommands && !messages.isEmpty && provider.providerID(for: selectedModel) == "openai" }
    func compact() {
        guard canCompact else { return }
        whenIdle("compact") { [weak self] in
            guard let self else { return }
            guard self.canCompact, self.snapshot?.pendingInput.isEmpty != false else {
                throw ExecError("Compaction is unavailable for the selected model or pending input.")
            }
            self.compactNow()
            await self.task?.value
        }
    }
    private func compactNow() {
        guard !backendBusy, !isSaving, let id = currentSessionID else { return }
        submitting = true
        acceptedOperationID = nil
        isCompacting = true
        task = Task {
            defer { submitting = false; task = nil; drainCommands() }
            do {
                let receipt = try await api.request("POST", AgentAPI.path(id, "/compact"), .object([:]))
                acceptedOperationID = receipt["operationID"].string.flatMap(UUID.init(uuidString:))
                try await resynchronize(id)
            } catch { self.error = error.localizedDescription; isCompacting = operationActive }
        }
    }
    func stop() {
        guard stopTask == nil else { return }
        pendingCommands.removeAll()
        commandTask?.cancel()
        // A submit may still be awaiting its receipt. Wait for its single request,
        // then target the operation actually accepted; never cancel by session alone.
        let pending = task
        let requestedID = operationActive ? snapshot?.operation?.id : nil
        isStopping = true
        stopTask = Task {
            await pending?.value
            defer { stopTask = nil; isStopping = operationActive && snapshot?.operation?.state == "cancelling"; updateSleepActivity(); drainCommands() }
            guard let id = currentSessionID else { return }
            do {
                pauseObservation()
                defer { observe() }
                let reader = api.transcriptReader(id)
                let current = try await reader.read()
                transcriptReader = reader
                try apply(current)
                guard let operation = current.operation, operation.active else { return }
                guard let target = requestedID ?? (pending != nil ? acceptedOperationID : nil), operation.id == target else {
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
            } catch { self.error = error.localizedDescription; isStopping = false }
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
        imageTask?.cancel(); imageTask = nil
        if let activity = sleepActivity { sleepPrevention.end(activity); sleepActivity = nil }
    }
}
