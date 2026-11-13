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
    var hasUsableModel: Bool { model != nil && provider.isModelAvailable(selectedModel) && !hasUnsavedChanges }
    var requestModelID: String { selectedModel }
    private(set) var messages: [Message] = []
    var draft = ""
    var draftImages: [ImageAttachment] = []
    private(set) var isImportingImages = false
    var hasUnsentDraft: Bool { !draft.isEmpty || !draftImages.isEmpty || isImportingImages || snapshot?.pendingInput.isEmpty == false }
    var error: String?
    private(set) var currentSessionID: UUID?
    private(set) var workspace: Workspace?
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
    var busy: Bool { isRestoringSession || submitting || operationActive || isStopping }
    var isWorking: Bool { busy }
    var canEditDraft: Bool { !isRestoringSession && !isStopping }
    var canSelectWorkspace: Bool { !busy && currentSessionID == nil && messages.isEmpty }
    private(set) var autoApproveTools: Bool
    private(set) var contextUsage: ContextUsage?
    private(set) var needsInitialWorkspaceSelection = false
    let tools = ToolApprovalState()
    var summary: SessionSummary? { snapshot.map(SessionSummary.init) }
    var didCheckpoint: (() async throws -> Void)?
    var didFinish: (() -> Void)?
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var observerGeneration = UUID()
    private var observationLost = false
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
        needsInitialWorkspaceSelection = false
    }
    func waitUntilIdle() async { await task?.value }
    func waitForPendingSave() async { await saveTask?.value }

    private var settings: AgentSettings {
        AgentSettings(systemPrompt: systemPrompt, autoApprove: autoApproveTools,
                      effort: selectedEffort, searchModel: !searchModel.isEmpty && provider.providerID(for: searchModel) == provider.providerID(for: selectedModel) ? searchModel : nil)
    }
    func setAutoApproveTools(_ enabled: Bool) {
        guard !busy else { return } // Rust settings changes are idle-only; never resolve a live approval implicitly.
        autoApproveTools = enabled
        scheduleSave()
    }
    func scheduleSave() {
        settingsDirty = true
        guard !busy, saveTask == nil else { return }
        saveTask = Task {
            defer { saveTask = nil }
            do { try await saveIfIdle() }
            catch { self.error = error.localizedDescription }
        }
    }
    func saveIfIdle(force: Bool = false) async throws {
        guard !busy else { return }
        isSaving = true
        defer { isSaving = false }
        try await persistConfiguration()
    }
    private func persistConfiguration() async throws {
        guard !configurationUncertain else { throw ExecError("The previous configuration request could not be confirmed. Reopen the conversation before making further changes.") }
        guard let workspace, !selectedModel.isEmpty else { return }
        let desiredSettings = settings
        let desiredModel = selectedModel
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
                observe()
            }
            settingsDirty = settings != desiredSettings || selectedModel != desiredModel
            hasUnsavedChanges = false
            if settingsDirty { try await persistConfiguration() }
        } catch {
            // Configuration/create may have committed. Do not retry an uncertain write.
            configurationUncertain = true
            hasUnsavedChanges = true
            throw error
        }
        try await didCheckpoint?()
    }

    func loadSession(_ id: UUID) async throws {
        isRestoringSession = true
        defer { isRestoringSession = false }
        let value = try await api.snapshot(id)
        try Task.checkCancellation()
        settingsDirty = false
        configurationUncertain = false
        try apply(value)
        observe()
    }
    func reconnectIfNeeded() {
        guard observationLost || configurationUncertain, let id = currentSessionID, task == nil else { return }
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
        try apply(await api.snapshot(id))
    }
    private func observe() {
        observer?.cancel()
        guard let id = currentSessionID else { return }
        let generation = UUID()
        observerGeneration = generation
        observationLost = false
        let stream = api.stream(id)
        observer = Task { [weak self] in
            do {
                for try await data in stream {
                    guard let self, self.observerGeneration == generation, !Task.isCancelled else { return }
                    let frame = try JSONDecoder().decode(AgentEvent.self, from: data)
                    if let snapshot = frame.snapshot { try self.apply(snapshot) }
                    else if let event = frame.event, event.type == "text", event.conversationID == id,
                            event.operationID == self.snapshot?.operation?.id,
                            let messageID = event.messageID, let delta = event.delta,
                            let index = self.messages.firstIndex(where: { $0.id == messageID && $0.status == .streaming }) {
                        self.messages[index].text += delta
                    }
                }
            } catch {
                guard let self, self.observerGeneration == generation, !Task.isCancelled else { return }
                self.observationLost = true
                self.error = error.localizedDescription
                // Keep the last known operation ownership. Disconnection is not completion.
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
    @discardableResult func importImages(_ load: @escaping @MainActor () async throws -> [ImageAttachment]) -> Task<Void, Never>? {
        guard !isImportingImages, canEditDraft else { return nil }
        isImportingImages = true
        return Task {
            defer { isImportingImages = false }
            do { let images = try await load(); try ImageAttachment.validate(draftImages + images); draftImages += images }
            catch { self.error = error.localizedDescription }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftImages.isEmpty, canEditDraft, !isImportingImages, !submitting, hasUsableModel else { return }
        if operationActive && (!draftImages.isEmpty || isCompacting) {
            error = isCompacting ? "Wait for compaction to finish before sending a message." : "Images cannot be sent while a response is running. Stop or wait for the response to finish."
            return
        }
        let inputImages = draftImages
        let originalDraft = draft
        submitting = true
        acceptedOperationID = nil
        error = nil
        task = Task {
            defer { submitting = false; task = nil; updateSleepActivity() }
            do {
                await waitForPendingSave()
                if !operationActive { try await persistConfiguration() }
                guard let id = currentSessionID else { throw ExecError("Choose a workspace and model before sending a message.") }
                if operationActive, let operation = snapshot?.operation {
                    _ = try await api.request("POST", AgentAPI.path(id, "/steer"), .object([
                        "operationID": .string(operation.id.uuidString.lowercased()), "text": .string(text)]))
                } else {
                    var images: [AgentImage] = []
                    for image in inputImages {
                        let value = try await api.request("POST", AgentAPI.path(id, "/images"), .object([
                            "name": .string(image.name), "base64": .string(image.data.base64EncodedString())]))
                        let ref = try value.decoded(AgentImage.self)
                        imageCache[ref.id] = ImageAttachment(id: ref.id, name: ref.name, mediaType: ref.mediaType, data: image.data)
                        images.append(ref)
                    }
                    struct Turn: Encodable { let text: String; let images: [AgentImage] }
                    let receipt = try await api.send("POST", AgentAPI.path(id, "/turns"), body: Turn(text: text, images: images))
                    acceptedOperationID = receipt["operationID"].string.flatMap(UUID.init(uuidString:))
                }
                if draft == originalDraft { draft = "" }
                if draftImages == inputImages { draftImages = [] }
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
    var canCompact: Bool { !busy && !isSaving && snapshot?.pendingInput.isEmpty != false && !messages.isEmpty && provider.providerID(for: selectedModel) == "openai" }
    func compact() {
        guard canCompact, let id = currentSessionID else { return }
        submitting = true
        acceptedOperationID = nil
        isCompacting = true
        task = Task {
            defer { submitting = false; task = nil }
            do {
                let receipt = try await api.request("POST", AgentAPI.path(id, "/compact"), .object([:]))
                acceptedOperationID = receipt["operationID"].string.flatMap(UUID.init(uuidString:))
                try await resynchronize(id)
            } catch { self.error = error.localizedDescription; isCompacting = operationActive }
        }
    }
    func stop() {
        guard stopTask == nil else { return }
        // A submit may still be awaiting its receipt. Wait for its single request,
        // then target the operation actually accepted; never cancel by session alone.
        let pending = task
        let requestedID = operationActive ? snapshot?.operation?.id : nil
        isStopping = true
        stopTask = Task {
            await pending?.value
            defer { stopTask = nil; isStopping = operationActive && snapshot?.operation?.state == "cancelling"; updateSleepActivity() }
            guard let id = currentSessionID else { return }
            do {
                pauseObservation()
                defer { observe() }
                let current = try await api.snapshot(id)
                try apply(current)
                guard let operation = current.operation, operation.active else { return }
                guard let target = requestedID ?? (pending != nil ? acceptedOperationID : nil), operation.id == target else {
                    throw ExecError("The active operation changed or its acceptance could not be confirmed. Inspect the conversation before stopping it.")
                }
                _ = try await api.request("POST", AgentAPI.path(id, "/cancel"), .object(["operationID": .string(operation.id.uuidString.lowercased())]))
                // Explicit stop waits for cleanup even when the observer disconnected.
                while true {
                    let value = try await api.snapshot(id)
                    try apply(value)
                    if value.operation?.active != true || value.operation?.id != target { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch { self.error = error.localizedDescription; isStopping = false }
        }
    }
    var canFork: Bool { !busy && !isSaving && !hasUnsavedChanges && snapshot?.pendingInput.isEmpty != false && currentSessionID != nil }
    func copyConversation(from source: ChatStore) async throws {
        guard source.canFork, let id = source.currentSessionID else { throw ExecError("Wait for the conversation to finish before forking it.") }
        let value = try await api.request("POST", AgentAPI.path(id, "/fork"), .object([:]))
        try apply(value.decoded(AgentSnapshot.self))
        observe()
    }
    private func updateSleepActivity() {
        if busy && sleepActivity == nil { sleepActivity = sleepPrevention.begin() }
        if !busy, let activity = sleepActivity { sleepPrevention.end(activity); sleepActivity = nil }
    }
    func closePresentation() {
        pauseObservation()
        imageTask?.cancel(); imageTask = nil
        if let activity = sleepActivity { sleepPrevention.end(activity); sleepActivity = nil }
    }
}
