import SwiftUI
import ExecRemote

protocol RemoteTransport: Sendable {
    var isConnected: Bool { get async }
    func connect(_ host: PairedHost) async throws
    func disconnect() async
    func changes() async throws -> AsyncThrowingStream<RemoteChangeNotification, Error>?
    func stopChanges() async
    /// Command errors should carry RemoteFailure.kind when the transport can
    /// prove non-dispatch or API rejection. Unknown/cancelled delivery is uncertain.
    func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON
}
extension RemoteTransport {
    // Legacy/test transports explicitly opt out. Errors must never imply fallback.
    func changes() async throws -> AsyncThrowingStream<RemoteChangeNotification, Error>? { nil }
    func stopChanges() async {}
    func request(_ method: String, _ path: String) async throws -> RemoteJSON {
        try await request(method, path, body: nil)
    }
}
extension RelayClient: RemoteTransport {}

@MainActor @Observable final class RemoteStore {
    static let hostConnectionRequiredMessage = "Connect to the host first."

    var host: PairedHost?
    var connected = false
    private(set) var isConnecting = false
    private(set) var hasLoadedLibrary = false
    // This aggregate is for diagnostics/tests, never for admitting UI actions.
    var busy: Bool { isConnecting || hasPendingCommands }
    var error: String? { didSet { connectionError = false } }
    private var connectionError = false
    // Presentation is independent of action errors and survives admitted retries.
    private(set) var hasConnectionFailure = false
    var showsConnectionFailure: Bool { host != nil && hasConnectionFailure && !connected }
    var visibleError: String? { connectionError ? nil : error }
    private enum MutationScope: Hashable {
        case library, creation, conversation(String), request(String)
    }
    private var mutations: Set<MutationScope> = []
    private var sending: [String: UUID] = [:]
    private var acceptedOperations: [String: String] = [:]
    private var cancellingOperations: [String: String] = [:]
    private var uncertainSends: Set<String> = []
    private var conversationConnections: [String: Int] = [:]
    var hasPendingCommands: Bool { !mutations.isEmpty || !sending.isEmpty }
    var canReconnect: Bool { !isConnecting && !hasPendingCommands }
    var canForget: Bool { !hasPendingCommands }
    var isCreatingSession: Bool { mutations.contains(.creation) }
    var isSavingLibrary: Bool { mutations.contains(.library) }
    var canEditSharedSettings: Bool { connected && hasLoadedLibrary && !isSavingLibrary }
    func isUpdatingConversation(_ id: String) -> Bool { mutations.contains(.conversation(id)) }

    struct PendingMessage: Identifiable {
        let id = UUID()
        let conversationID: String
        let text: String
        fileprivate var target: MessageTarget
        var rowID: String { "local-\(id.uuidString)" }
        // Transient transcript input only; never an authoritative snapshot.
        var transcriptMessage: RemoteJSON {
            .object(["id": .string(rowID), "role": .string("user"), "text": .string(text)])
        }
    }
    fileprivate enum MessageTarget: Equatable {
        case unresolved, newTurn, operation(String), afterSend(UUID)
    }
    private(set) var pendingMessage: PendingMessage?
    private var bufferTask: Task<Void, Never>?
    private var bufferTaskID: UUID?
    private var connectionNeedsReset = false
    private var bufferDeadline: Task<Void, Never>?
    private let bufferSleep: @Sendable () async throws -> Void
    var conversations: [RemoteJSON] = []
    private(set) var hasLoadedConversations = false
    var isLoadingConversations: Bool { !hasLoadedConversations && (busy || error == nil) }
    var models: [RemoteJSON] = []
    var library: RemoteJSON = .null
    var settings = RemoteSettingsDraft()
    private var settingsSaveTask: Task<Void, Never>?
    var selected: String? {
        didSet {
            guard selected != oldValue else { return }
            if pendingMessage?.conversationID != selected { cancelPendingMessage() }
            snapshot = selected.flatMap { recentConversations.visit($0) } ?? .null
            syncStates = syncStates.filter { recentConversations.contains($0.key) }
            transcriptViewStates = transcriptViewStates.filter { recentConversations.contains($0.key) }
        }
    }
    var snapshot: RemoteJSON = .null {
        didSet { recentConversations.update(snapshot) }
    }
    var drafts: [String:String] = [:]
    private var optimisticMessages: [String: RemoteOptimisticMessages] = [:]
    private var deletions = RemoteSessionDeletions()
    // A notice can be acknowledged while a DELETE defers a resident history or
    // a send loses its acknowledgement. Keep it dirty until a read applies or it leaves cache.
    private var deferredHistoryRefreshes: Set<String> = []
    // Invalidate reads spanning local sends/deletions so they cannot roll back UI state.
    private var snapshotGeneration = 0
    var displaySnapshot: RemoteJSON {
        guard let selected else { return snapshot }
        return optimisticMessages[selected]?.project(snapshot) ?? snapshot
    }
    var awaitingSendSnapshot: Bool { selected.flatMap { optimisticMessages[$0]?.awaitingSnapshot } ?? false }
    private var recentConversations = RecentConversationCache()
    @ObservationIgnored private var transcriptViewStates: [String: TranscriptViewState] = [:]
    private var syncStates: [String: RemoteTranscriptSync] = [:]
    private var readTickets: [String: Int] = [:]
    private var loadingEarlier: Set<String> = []
    var hasEarlierMessages: Bool { selected.flatMap { syncStates[$0]?.hasEarlier } ?? false }
    private var hostGeneration = 0
    private var connectionGeneration = 0
    private var catalogReadTicket = 0
    private(set) var observationGeneration = 0
    private var observationTask: Task<Void, Never>?
    private(set) var lastChangeNotification: RemoteChangeNotification?
    private(set) var reconnectDelay = 1.5
    private let sleep: @Sendable (Double) async throws -> Void
    private let client: any RemoteTransport
    private let saveHost: (PairedHost) throws -> Void
    private let forgetHost: () throws -> Void
    init(client: any RemoteTransport = RelayClient(),
         loadHost: () throws -> PairedHost? = { try DeviceStore.load() },
         saveHost: @escaping (PairedHost) throws -> Void = { try DeviceStore.save($0) },
         forgetHost: @escaping () throws -> Void = { try DeviceStore.forget() },
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         bufferSleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(30)) }) {
        self.client = client; self.saveHost = saveHost; self.forgetHost = forgetHost
        self.sleep = sleep; self.bufferSleep = bufferSleep
        do { host = try loadHost() } catch { self.error = error.localizedDescription }
    }
    var active: Bool { RemoteMessageSubmission.isActive(snapshot) || currentOperationID != nil }
    private var currentOperationID: String? {
        guard let id = selected else { return nil }
        if let accepted = acceptedOperations[id] { return accepted }
        return RemoteMessageSubmission.isActive(snapshot) ? snapshot["operation"]["id"].string : nil
    }
    private func isCancelling(_ id: String) -> Bool {
        let value = syncStates[id]?.snapshot ?? conversations.first(where: { $0.id == id }) ?? .null
        return cancellingOperations[id] != nil || value["operation"]["state"].string == "cancelling"
    }
    var canSend: Bool {
        guard host != nil, let id = selected, pendingMessage == nil,
              !(drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !isUpdatingConversation(id) && !isCancelling(id) && !uncertainSends.contains(id)
    }
    var canStop: Bool {
        guard connected, let id = selected, currentOperationID != nil, sending[id] == nil else { return false }
        return !isUpdatingConversation(id) && !isCancelling(id)
    }
    /// The immutable approval the user actually saw, never a lookup at task entry.
    struct ApprovalTarget: Equatable, Sendable {
        let conversationID: String
        let operationID: String
        let approvalID: String

        init?(snapshot: RemoteJSON) {
            guard let conversation = snapshot["id"].string, !conversation.isEmpty,
                  let operation = snapshot["approval"]["operationID"].string, !operation.isEmpty,
                  let approval = snapshot["approval"]["id"].string, !approval.isEmpty else { return nil }
            conversationID = conversation; operationID = operation; approvalID = approval
        }
    }
    var canApprove: Bool {
        ApprovalTarget(snapshot: snapshot).map { canApprove($0) } ?? false
    }
    func canApprove(_ target: ApprovalTarget) -> Bool {
        guard connected, selected == target.conversationID, sending[target.conversationID] == nil,
              ApprovalTarget(snapshot: snapshot) == target,
              snapshot["operation"]["id"].string == target.operationID,
              snapshot["operation"]["state"].string == "awaiting_approval" else { return false }
        return !isUpdatingConversation(target.conversationID) && !isCancelling(target.conversationID)
    }
    /// Remote deletion is explicit and immediate, even with running work or drafts.
    func canDeleteConversation(_ value: RemoteJSON) -> Bool {
        connected && !isUpdatingConversation(value.id) && sending[value.id] == nil
    }
    private func scope(for path: String) -> MutationScope {
        if path == "/v1/library" { return .library }
        if path == "/v1/conversations" { return .creation }
        let parts = path.split(separator: "/")
        if parts.count >= 3, parts[0] == "v1", parts[1] == "conversations" { return .conversation(String(parts[2])) }
        return .request(path)
    }
    private func showConnectionError(_ failure: Error) {
        guard !Task.isCancelled, !(failure is CancellationError) else { return }
        hasConnectionFailure = true
        // The banner must never hide an uncertain-delivery warning or other action error.
        guard error == nil || connectionError else { return }
        error = failure.localizedDescription
        connectionError = true
    }
    private func recordDisconnectedFailure(_ failure: Error, connection: Int) async {
        guard connection == connectionGeneration, !Task.isCancelled, !(failure is CancellationError) else { return }
        let transportConnected = await client.isConnected
        guard connection == connectionGeneration, !Task.isCancelled else { return }
        if !transportConnected { connected = false; showConnectionError(failure) }
    }

    func transcriptViewState(for id: String?) -> TranscriptViewState? {
        guard let id, recentConversations.contains(id) else { return nil }
        return transcriptViewStates[id] ?? TranscriptViewState(generation: hostGeneration)
    }
    func saveTranscriptViewState(_ value: TranscriptViewState, for id: String) {
        guard value.generation == hostGeneration, recentConversations.contains(id) else { return }
        transcriptViewStates[id] = value
    }
    func pair(_ text: String) async {
        guard !isConnecting, !hasPendingCommands else { return }
        do {
            let invitation = try PairingInvitation.parse(text)
            let host = PairedHost(invitation: invitation, deviceName: "iPhone")
            // Preserve the identity even when pairing acknowledgement is lost.
            try saveHost(host)
            clearConversationState()
            self.host = host
            await connect()
        } catch { self.error = error.localizedDescription }
    }
    func connect(resetBackoff: Bool = true) async {
        guard var host, canReconnect, !Task.isCancelled else { return }
        connectionGeneration += 1
        snapshotGeneration += 1
        let generation = connectionGeneration
        isConnecting = true; connected = false; connectionNeedsReset = false
        if connectionError { error = nil }
        defer { isConnecting = false }
        do {
            // Only reads may be interrupted here; pending commands gate reconnect.
            if await client.isConnected { await client.disconnect() }
            try await client.connect(host)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            hasConnectionFailure = false
            host.invitation.secret = nil
            try saveHost(host); self.host = host
            connected = true
            if connectionError { error = nil }
            let models = try await client.request("GET", "/v1/models").array
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            self.models = models
            try await refresh()
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            scheduleBufferedMessage()
            if resetBackoff { reconnectDelay = 1.5 }
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled, !(error is CancellationError) else { return }
            let transportConnected = await client.isConnected
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            connected = transportConnected
            if connected { self.error = error.localizedDescription }
            else { showConnectionError(error) }
            reconnectDelay = min(reconnectDelay * 2, 30)
        }
    }
    func suspend() async {
        cancelPendingMessage()
        observationGeneration += 1
        // Retain the teardown chain so a concurrent foreground owner awaits it.
        observationTask?.cancel()
        await disconnectConnection()
    }
    private func disconnectConnection() async {
        lastChangeNotification = nil
        connectionGeneration += 1
        snapshotGeneration += 1
        connected = false
        await client.disconnect()
    }
    func forget() async {
        guard canForget else { return }
        do {
            try forgetHost()
            clearConversationState()
            host = nil
            // Keep the foreground observer alive for a subsequent pairing.
            await disconnectConnection()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func browseFolders(_ path: String?, showHidden: Bool) async throws -> RemoteJSON {
        guard connected else { throw RemoteFailure(Self.hostConnectionRequiredMessage) }
        let connection = connectionGeneration
        do {
            return try await client.request("POST", "/v1/workspaces/browse", body: .object([
                "path": .optional(path), "showHidden": .bool(showHidden)
            ]))
        } catch {
            await recordDisconnectedFailure(error, connection: connection)
            throw error
        }
    }
    private func clearConversationState() {
        cancelPendingMessage()
        hasConnectionFailure = false
        hostGeneration += 1
        transcriptViewStates.removeAll()
        settings = RemoteSettingsDraft()
        recentConversations = RecentConversationCache()
        syncStates = [:]; readTickets = [:]; loadingEarlier = []
        conversationConnections = [:]; acceptedOperations = [:]; cancellingOperations = [:]; uncertainSends = []
        models = []; library = .null; hasLoadedLibrary = false
        optimisticMessages = [:]
        deletions = RemoteSessionDeletions(); deferredHistoryRefreshes = []
        snapshotGeneration += 1
        selected = nil; snapshot = .null; conversations = []; drafts = [:]
        hasLoadedConversations = false
    }
    func refresh() async throws {
        let generation = hostGeneration, connection = connectionGeneration, readGeneration = snapshotGeneration
        // Prioritize the visible turn on explicit/full refreshes.
        let visibleID = selected
        var readFailure: Error?
        if let id = visibleID {
            do { try await refreshConversation(id) }
            catch { readFailure = error }
        }
        guard generation == hostGeneration, connection == connectionGeneration,
              readGeneration == snapshotGeneration, !Task.isCancelled else { return }
        guard try await refreshCatalog() else { return }
        if selected == visibleID, let readFailure { throw readFailure }
    }
    @discardableResult private func refreshCatalog() async throws -> Bool {
        let generation = hostGeneration, readGeneration = snapshotGeneration, connection = connectionGeneration
        catalogReadTicket += 1
        let ticket = catalogReadTicket
        let list: [RemoteJSON], settings: RemoteJSON
        do {
            list = try await client.request("GET", "/v1/conversations").array
            guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
                  readGeneration == snapshotGeneration, ticket == catalogReadTicket else { return false }
            settings = try await client.request("GET", "/v1/library")
        } catch {
            guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
                  readGeneration == snapshotGeneration, ticket == catalogReadTicket else { return false }
            throw error
        }
        guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
              readGeneration == snapshotGeneration, ticket == catalogReadTicket else { return false }
        guard case .object = settings else { throw RemoteFailure("Invalid shared settings response. Refresh the library before editing.") }
        conversations = deletions.reconcile(list); library = settings
        hasLoadedConversations = true; hasLoadedLibrary = true
        let ids = Set(conversations.compactMap { $0["id"].string }).union(deletions.pendingIDs)
        recentConversations.retain(ids)
        deferredHistoryRefreshes = deferredHistoryRefreshes.filter { recentConversations.contains($0) }
        syncStates = syncStates.filter { recentConversations.contains($0.key) }
        transcriptViewStates = transcriptViewStates.filter { recentConversations.contains($0.key) }
        optimisticMessages = optimisticMessages.filter { ids.contains($0.key) }
        if let id = selected, !ids.contains(id) { selected = nil; snapshot = .null }
        return true
    }
    @discardableResult private func refreshConversation(_ id: String) async throws -> Bool {
        let generation = hostGeneration, readGeneration = snapshotGeneration, connection = connectionGeneration
        readTickets[id, default: 0] += 1
        let ticket = readTickets[id]
        let path = "/v1/conversations/\(id)/sync"
        let value: RemoteJSON
        do {
            value = try await client.request("GET", syncStates[id]?.refreshPath(path) ?? path)
        } catch {
            guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
                  readGeneration == snapshotGeneration, ticket == readTickets[id] else { return false }
            throw error
        }
        guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
              readGeneration == snapshotGeneration, ticket == readTickets[id] else { return false }
        guard recentConversations.contains(id) else { return true }
        let state = try syncStates[id].map { try $0.refreshed(value) } ?? RemoteTranscriptSync.initial(value)
        syncStates[id] = state
        conversationConnections[id] = connection
        uncertainSends.remove(id)
        deferredHistoryRefreshes.remove(id)
        acceptedOperations.removeValue(forKey: id)
        if sending[id] == nil {
            if cancellingOperations[id] != state.snapshot["operation"]["id"].string
                || !RemoteMessageSubmission.isActive(state.snapshot) {
                cancellingOperations.removeValue(forKey: id)
            }
        }
        recentConversations.update(state.snapshot)
        optimisticMessages[id]?.reconcile(state)
        // Transcript notices can arrive without a catalog revision. Keep the
        // row authoritative when returning to the session list.
        if let index = conversations.firstIndex(where: { $0.id == id }),
           case .object(var summary) = conversations[index] {
            summary["operation"] = state.snapshot["operation"]
            conversations[index] = .object(summary)
        }
        if selected == id { snapshot = state.snapshot }
        return true
    }
    func loadEarlier() async {
        guard connected, let id = selected, !loadingEarlier.contains(id),
              let state = syncStates[id], let path = state.earlierPath("/v1/conversations/\(id)/sync") else { return }
        loadingEarlier.insert(id)
        defer { loadingEarlier.remove(id) }
        let generation = hostGeneration, readGeneration = snapshotGeneration, connection = connectionGeneration
        let first = state.snapshot["messages"].array.first?["id"].string
        do {
            let value = try await client.request("GET", path)
            guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
                  readGeneration == snapshotGeneration,
                  selected == id, let current = syncStates[id],
                  current.snapshot["messages"].array.first?["id"].string == first else { return }
            let older = try current.prepending(value)
            syncStates[id] = older
            optimisticMessages[id]?.reconcile(older.snapshot)
            snapshot = older.snapshot
        } catch {
            guard generation == hostGeneration, connection == connectionGeneration,
                  readGeneration == snapshotGeneration, !Task.isCancelled, selected == id else { return }
            await reportReadFailure(error, connection: connection)
        }
    }
    func observe() async {
        guard !Task.isCancelled else { return }
        let predecessor = observationTask
        predecessor?.cancel()
        observationGeneration += 1
        let generation = observationGeneration
        let task = Task {
            // Task cancellation alone does not await AsyncStream.onTermination.
            // Chain owners, including replacements during subscription/read, and
            // explicitly release the transport consumer before the next can open.
            await predecessor?.value
            guard isObserving(generation) else { return }
            await runObservation(generation)
            await client.stopChanges()
        }
        observationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // A cancelled old scene task must not disconnect a newer observer.
        if generation == observationGeneration { await suspend() }
    }
    private func isObserving(_ generation: Int) -> Bool {
        generation == observationGeneration && !Task.isCancelled
    }
    private func runObservation(_ generation: Int) async {
        while isObserving(generation) {
            if host != nil, !isConnecting {
                if connectionNeedsReset, !hasPendingCommands {
                    await disconnectConnection()
                    connectionNeedsReset = false
                }
                let connection = connectionGeneration
                let transportConnected = await client.isConnected
                guard isObserving(generation) else { return }
                guard connection == connectionGeneration else { continue }
                if !transportConnected {
                    if connected { showConnectionError(RemoteFailure("Host connection lost.")) }
                    connected = false
                }
                if !connected { await connect(resetBackoff: false) }
                guard isObserving(generation) else { return }
                if connected {
                    let observedHost = hostGeneration, connection = connectionGeneration
                    do {
                        lastChangeNotification = nil
                        if let stream = try await client.changes() {
                            for try await notice in stream {
                                guard isObserving(generation) else { return }
                                guard observedHost == hostGeneration, connection == connectionGeneration else { break }
                                try await consume(notice, generation: generation)
                                guard isObserving(generation) else { return }
                                guard observedHost == hostGeneration, connection == connectionGeneration else { break }
                                lastChangeNotification = notice
                                reconnectDelay = 1.5
                            }
                            guard isObserving(generation) else { return }
                            throw RemoteFailure("Change notification stream ended.")
                        } else {
                            // Only an explicit unsupported capability/endpoint permits polling.
                            reconnectDelay = 1.5
                            while isObserving(generation), connected,
                                  observedHost == hostGeneration, connection == connectionGeneration {
                                await poll(reconnect: false)
                                guard isObserving(generation), connected,
                                      observedHost == hostGeneration, connection == connectionGeneration else { break }
                                try await sleep(active || awaitingSendSnapshot ? 0.5 : 1.5)
                            }
                        }
                    } catch {
                        guard isObserving(generation), !(error is CancellationError) else { return }
                        guard observedHost == hostGeneration, connection == connectionGeneration else { continue }
                        showConnectionError(error)
                        reconnectDelay = min(reconnectDelay * 2, 30)
                        connected = false; connectionNeedsReset = true
                        // Let an acknowledged/dispatched command finish before resetting reads.
                        if !hasPendingCommands {
                            await disconnectConnection()
                            connectionNeedsReset = false
                        }
                    }
                }
            }
            guard isObserving(generation) else { return }
            do { try await sleep(reconnectDelay) } catch { return }
        }
    }
    private func consume(_ notice: RemoteChangeNotification, generation: Int) async throws {
        guard !notice.epoch.isEmpty, !notice.catalog.isEmpty,
              notice.conversations.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
            throw RemoteFailure("Invalid change notification.")
        }
        let previous = lastChangeNotification
        let host = hostGeneration, connection = connectionGeneration
        let catchUp = previous == nil || previous?.epoch != notice.epoch
        // Do not acknowledge a revision whose read was invalidated by a send,
        // deletion or newer activation read. Catch up even if no further notice
        // arrives. Rejections/malformed pages throw into bounded reconnect backoff.
        while isObserving(generation), host == hostGeneration, connection == connectionGeneration {
            let readGeneration = snapshotGeneration
            if catchUp || previous?.catalog != notice.catalog {
                guard try await refreshCatalog() else { continue }
            }
            guard isObserving(generation), host == hostGeneration, connection == connectionGeneration else { return }
            var residents = Set(readTickets.keys.filter { recentConversations.contains($0) })
            if let selected { residents.insert(selected) }
            let ordered = residents.sorted { lhs, rhs in
                if lhs == selected { return rhs != selected }
                if rhs == selected { return false }
                return lhs < rhs
            }
            var applied = true
            deferredHistoryRefreshes = deferredHistoryRefreshes.intersection(residents)
            for id in ordered where catchUp || deferredHistoryRefreshes.contains(id) || notice.conversations[id] != previous?.conversations[id] {
                guard isObserving(generation), host == hostGeneration, connection == connectionGeneration else { return }
                // Don't race a pending DELETE with a history read that could
                // reject and disconnect its still-unacknowledged command.
                guard recentConversations.contains(id) else { continue }
                if deletions.pendingIDs.contains(id) {
                    deferredHistoryRefreshes.insert(id)
                    continue // no spinning/reads while DELETE is pending
                }
                if try await refreshConversation(id) {
                    deferredHistoryRefreshes.remove(id)
                } else { applied = false }
            }
            if applied, readGeneration == snapshotGeneration { return }
        }
    }
    // Legacy foreground recovery reads authoritative state, never commands.
    // A reconnect must re-probe changes(), rather than pinning fallback forever.
    func poll(reconnect: Bool = true) async {
        guard host != nil, !isConnecting, !Task.isCancelled else { return }
        let generation = connectionGeneration
        let transportConnected = await client.isConnected
        guard generation == connectionGeneration, !Task.isCancelled else { return }
        if !transportConnected {
            if connected { showConnectionError(RemoteFailure("Host connection lost.")) }
            connected = false
        }
        if !connected {
            if reconnect { await connect() }
            return
        }
        do {
            if let id = selected, active || awaitingSendSnapshot { try await refreshConversation(id) }
            else { try await refresh() }
        } catch {
            await reportReadFailure(error, connection: generation)
        }
    }
    @discardableResult func open(_ id: String) -> Task<Void, Never> {
        selected = id
        let generation = hostGeneration, connection = connectionGeneration
        // Store-owned reads can finish and warm the cache after navigation.
        // Cancelling a dispatched read only detaches its caller; the socket drains it.
        return Task {
            guard generation == hostGeneration, connection == connectionGeneration else { return }
            do {
                try await refreshConversation(id)
            } catch {
                if generation == hostGeneration, connection == connectionGeneration, selected == id {
                    await reportReadFailure(error, connection: connection)
                }
            }
        }
    }
    func refreshSettings(editing: Bool = false) {
        guard hasLoadedLibrary else { return }
        settings.refresh(library, editing: editing)
    }
    func showSettings() {
        refreshSettings()
        settings.isPresented = true
    }
    @discardableResult func finishSettings() -> Task<Void, Never>? {
        guard settings.isPresented else { return nil }
        guard hasLoadedLibrary, settings.hasUnsavedChanges else { settings.dismiss(); return nil }
        guard canEditSharedSettings, settingsSaveTask == nil else { return nil }
        let prompt = settings.prompt, generation = hostGeneration, connection = connectionGeneration
        let body: RemoteJSON = .object(["settings": .object(["systemPrompt": .string(prompt)])])
        mutations.insert(.library); error = nil; settings.error = nil
        settings.dismiss()
        let task = Task {
            do {
                let value = try await client.request("PATCH", "/v1/library", body: body)
                mutations.remove(.library); settingsSaveTask = nil
                guard generation == hostGeneration else { return }
                settings.accept(prompt)
                library = value
            } catch {
                mutations.remove(.library); settingsSaveTask = nil
                guard generation == hostGeneration else { return }
                settings.fail(error)
                await recordDisconnectedFailure(error, connection: connection)
                return
            }
            // Readback is independent of the acknowledged write's admission lock.
            do { try await refresh() }
            catch { if generation == hostGeneration { await reportReadFailure(error, connection: connection) } }
        }
        settingsSaveTask = task
        return task
    }
    func mutate(_ method: String, _ path: String, _ body: RemoteJSON, onSuccess: ((RemoteJSON) -> Void)? = nil) async {
        let scope = scope(for: path), generation = hostGeneration, connection = connectionGeneration
        guard connected, !mutations.contains(scope) else { return }
        if scope == .library, !canEditSharedSettings { return }
        if case .conversation(let id) = scope, sending[id] != nil { return }
        mutations.insert(scope); error = nil
        do {
            let value = try await client.request(method, path, body: body)
            mutations.remove(scope)
            guard generation == hostGeneration else { return }
            onSuccess?(value)
            scheduleBufferedMessage()
        } catch {
            mutations.remove(scope)
            guard generation == hostGeneration else { return }
            self.error = error.localizedDescription
            await recordDisconnectedFailure(error, connection: connection)
            scheduleBufferedMessage()
            return
        }
        do { try await refresh() }
        catch { if generation == hostGeneration { await reportReadFailure(error, connection: connection) } }
    }
    func deleteConversation(_ id: String) async {
        guard let conversation = conversations.first(where: { $0.id == id }), canDeleteConversation(conversation) else { return }
        mutations.insert(.conversation(id)); error = nil
        let generation = hostGeneration, connection = connectionGeneration
        snapshotGeneration += 1
        deletions.begin(conversation)
        withAnimation { conversations = deletions.project(conversations) }
        if selected == id { selected = nil }
        do {
            _ = try await client.request("DELETE", "/v1/conversations/\(id)")
            mutations.remove(.conversation(id))
            guard generation == hostGeneration else { return }
            snapshotGeneration += 1
            deletions.accept(id)
            recentConversations.remove(id)
            transcriptViewStates.removeValue(forKey: id)
            deferredHistoryRefreshes.remove(id)
            syncStates.removeValue(forKey: id)
            conversationConnections.removeValue(forKey: id)
            readTickets[id, default: 0] += 1
            optimisticMessages.removeValue(forKey: id)
            acceptedOperations.removeValue(forKey: id)
            cancellingOperations.removeValue(forKey: id)
            uncertainSends.remove(id)
            drafts.removeValue(forKey: id)
        } catch {
            mutations.remove(.conversation(id))
            guard generation == hostGeneration else { return }
            snapshotGeneration += 1
            if let restored = deletions.fail(id), !conversations.contains(where: { $0.id == id }) {
                withAnimation { conversations.append(restored) }
            }
            self.error = error.localizedDescription
            await recordDisconnectedFailure(error, connection: connection)
            return
        }
        // Acceptance is final. A later refresh error must not resurrect the row.
        do { try await refresh() }
        catch { if generation == hostGeneration { await reportReadFailure(error, connection: connection) } }
    }
    private func messageTarget(_ id: String) -> MessageTarget {
        if let flight = sending[id] { return .afterSend(flight) }
        if let operation = acceptedOperations[id] { return .operation(operation) }
        let value = syncStates[id]?.snapshot ?? conversations.first(where: { $0.id == id }) ?? .null
        guard value["id"].string == id else { return .unresolved }
        if RemoteMessageSubmission.isActive(value) {
            return value["operation"]["id"].string.map(MessageTarget.operation) ?? .unresolved
        }
        return .newTurn
    }
    func send() async {
        guard canSend, let id = selected, let text = drafts[id] else { return }
        let target = messageTarget(id)
        drafts[id] = ""
        if connected, conversationConnections[id] == connectionGeneration, sending[id] == nil, target != .unresolved {
            await performSend(id, text: text, target: target)
        } else {
            let message = PendingMessage(conversationID: id, text: text, target: target)
            pendingMessage = message
            bufferDeadline = Task { [weak self, bufferSleep] in
                do { try await bufferSleep() } catch { return }
                guard let self, pendingMessage?.id == message.id else { return }
                cancelPendingMessage()
            }
            scheduleBufferedMessage()
        }
    }
    private func performSend(_ id: String, text: String, target: MessageTarget,
                             rowID: String = "local-\(UUID().uuidString)") async {
        guard !Task.isCancelled, connected, sending[id] == nil, !isUpdatingConversation(id), !isCancelling(id) else {
            restoreDraft(text, for: id); return
        }
        let path: String, body: RemoteJSON
        switch target {
        case .newTurn:
            path = "/v1/conversations/\(id)/turns"; body = .object(["text": .string(text)])
        case .operation(let operation):
            path = "/v1/conversations/\(id)/steer"; body = .object(["operationID": .string(operation), "text": .string(text)])
        default: restoreDraft(text, for: id); return
        }
        let flight = UUID(), generation = hostGeneration, connection = connectionGeneration
        sending[id] = flight; error = nil; snapshotGeneration += 1
        let localID = optimisticMessages[id, default: RemoteOptimisticMessages()].begin(
            text: text, snapshot: syncStates[id]?.snapshot ?? snapshot, id: rowID)
        do {
            let response = try await client.request("POST", path, body: body)
            guard generation == hostGeneration else { return }
            let needsSnapshot = optimisticMessages[id]?.accept(localID, response: response) ?? false
            if let operation = response["operationID"].string {
                if needsSnapshot { acceptedOperations[id] = operation }
                else { acceptedOperations.removeValue(forKey: id) }
                if pendingMessage?.target == .afterSend(flight) { pendingMessage?.target = .operation(operation) }
            } else if pendingMessage?.target == .afterSend(flight) { cancelPendingMessage() }
            sending.removeValue(forKey: id)
            snapshotGeneration += 1
            scheduleBufferedMessage()
        } catch {
            guard generation == hostGeneration else { return }
            sending.removeValue(forKey: id)
            snapshotGeneration += 1
            optimisticMessages[id]?.remove(localID)
            // The dependent input is definitely unsent. Restore both drafts in
            // order, but never replay the command that crossed dispatch.
            if pendingMessage?.conversationID == id { cancelPendingMessage() }
            restoreDraft(text, for: id)
            let kind = (error as? RemoteFailure)?.kind ?? .uncertain
            switch kind {
            case .notDispatched, .rejected:
                self.error = "\(error.localizedDescription) Your message is back in the draft."
            case .uncertain:
                uncertainSends.insert(id)
                deferredHistoryRefreshes.insert(id)
                self.error = "Message delivery could not be confirmed. \(error.localizedDescription) Check the refreshed conversation before sending again."
            }
            await recordDisconnectedFailure(error, connection: connection)
            guard kind == .uncertain, generation == hostGeneration, connection == connectionGeneration,
                  connected, !Task.isCancelled else { return }
            // One read-only recovery attempt, even if the host emits no revision
            // after a lost reply. A failed read stays dirty for the next notice or
            // foreground catch-up; it must not replace the delivery warning.
            do { try await refreshConversation(id) }
            catch { await recordDisconnectedFailure(error, connection: connection) }
            return
        }
        do { try await refreshConversation(id) }
        catch { if generation == hostGeneration { await reportReadFailure(error, connection: connection) } }
    }
    private func restoreDraft(_ text: String, for id: String) {
        let newer = drafts[id] ?? ""
        drafts[id] = newer.isEmpty ? text : text + "\n\n" + newer
    }
    // Menus can outlive their row or its acceptance. Never cancel a replacement.
    func cancelPendingMessage(rowID: String) {
        guard pendingMessage?.rowID == rowID else { return }
        cancelPendingMessage()
    }
    func cancelPendingMessage() {
        guard let message = pendingMessage else { return }
        pendingMessage = nil
        bufferDeadline?.cancel(); bufferDeadline = nil
        bufferTask?.cancel(); bufferTask = nil; bufferTaskID = nil
        restoreDraft(message.text, for: message.conversationID)
    }
    private func scheduleBufferedMessage() {
        guard let message = pendingMessage, connected, bufferTask == nil,
              sending[message.conversationID] == nil, !isUpdatingConversation(message.conversationID) else { return }
        if case .afterSend = message.target { return }
        let token = UUID(), generation = hostGeneration, connection = connectionGeneration
        bufferTaskID = token
        bufferTask = Task {
            defer {
                if bufferTaskID == token {
                    bufferTask = nil; bufferTaskID = nil
                    // A replacement connection may finish while the old read drains.
                    if connection != connectionGeneration { scheduleBufferedMessage() }
                }
            }
            do {
                // Revalidate unsent intent, never retry a dispatched command.
                while pendingMessage?.id == message.id, connected, !Task.isCancelled {
                    guard try await refreshConversation(message.conversationID) else { await Task.yield(); continue }
                    guard generation == hostGeneration, !Task.isCancelled,
                          let pending = pendingMessage, pending.id == message.id,
                          selected == pending.conversationID,
                          let value = syncStates[pending.conversationID]?.snapshot else { return }
                    var target = pending.target
                    if target == .unresolved, !RemoteMessageSubmission.isActive(value) { target = .newTurn }
                    let valid: Bool
                    switch target {
                    case .newTurn: valid = !RemoteMessageSubmission.isActive(value)
                    case .operation(let operation):
                        valid = value["operation"]["id"].string == operation
                            && ["running", "awaiting_approval"].contains(value["operation"]["state"].string ?? "")
                    default: valid = false
                    }
                    guard valid, !isCancelling(pending.conversationID) else {
                        cancelPendingMessage()
                        error = "The conversation changed. The queued message was returned to your draft."
                        return
                    }
                    // Crossing this boundary commits one attempt. It is no longer cancellable or replayable.
                    pendingMessage = nil
                    bufferDeadline?.cancel(); bufferDeadline = nil
                    bufferTask = nil; bufferTaskID = nil
                    await performSend(pending.conversationID, text: pending.text, target: target, rowID: pending.rowID)
                    return
                }
            } catch {
                guard generation == hostGeneration, !Task.isCancelled, !(error is CancellationError),
                      pendingMessage?.id == message.id else { return }
                await recordDisconnectedFailure(error, connection: connection)
                guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
                      pendingMessage?.id == message.id else { return }
                if connected {
                    cancelPendingMessage()
                    self.error = "Could not verify the conversation. The queued message was returned to your draft."
                }
            }
        }
    }
    private func reportReadFailure(_ failure: Error, connection: Int) async {
        guard connection == connectionGeneration, !Task.isCancelled, !(failure is CancellationError) else { return }
        let transportConnected = await client.isConnected
        guard connection == connectionGeneration, !Task.isCancelled else { return }
        // An API rejection does not mean the WebSocket was lost.
        if !transportConnected { connected = false; showConnectionError(failure) }
        else { error = failure.localizedDescription }
    }
    func stop() async {
        guard canStop, let id = selected, let operation = currentOperationID else { return }
        if pendingMessage?.conversationID == id { cancelPendingMessage() }
        await mutate("POST", "/v1/conversations/\(id)/cancel", .object(["operationID": .string(operation)])) { _ in
            self.cancellingOperations[id] = operation
        }
    }
    func approve(_ target: ApprovalTarget, approved: Bool) async {
        guard canApprove(target) else { return }
        await mutate("POST", "/v1/conversations/\(target.conversationID)/approvals", .object([
            "approvalID": .string(target.approvalID), "operationID": .string(target.operationID), "approved": .bool(approved)
        ]))
    }
}

/// The settings draft and presentation outlive any individual sheet instance.
struct RemoteSettingsDraft {
    var prompt = ""
    var error: String?
    var isPresented = false
    private var savedPrompt: String?
    private var isDismissing = false
    private var reopenAfterDismissal = false
    var hasUnsavedChanges: Bool { savedPrompt.map { prompt != $0 } ?? false }
    var actionTitle: String { hasUnsavedChanges ? "Apply" : "Done" }

    mutating func refresh(_ library: RemoteJSON, editing: Bool = false) {
        // Reads must not replace a dirty draft, including an unfocused failed save.
        guard savedPrompt == nil || (!hasUnsavedChanges && !editing) else { return }
        prompt = library["settings"]["systemPrompt"].string ?? ""
        savedPrompt = prompt
    }
    mutating func accept(_ prompt: String) { savedPrompt = prompt }
    mutating func dismiss() {
        isDismissing = true
        isPresented = false
    }
    mutating func didDismiss() {
        isDismissing = false
        if reopenAfterDismissal {
            reopenAfterDismissal = false
            isPresented = true
        }
    }
    mutating func fail(_ failure: Error) {
        error = "Could not confirm settings were saved. \(failure.localizedDescription) Your edits are preserved; check the host before applying again."
        // A fast rejection can arrive during the sheet's dismissal animation.
        // Wait for the actual presentation owner to finish before reopening.
        if isDismissing { reopenAfterDismissal = true }
        else { isPresented = true }
    }
}

extension RemoteJSON { var id: String { self["id"].string ?? "" } }
