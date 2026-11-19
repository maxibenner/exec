import SwiftUI
import ExecRemote

protocol RemoteTransport: Sendable {
    var isConnected: Bool { get async }
    func connect(_ host: PairedHost) async throws
    func disconnect() async
    func changes() async throws -> AsyncThrowingStream<RemoteChangeNotification, Error>?
    func stopChanges() async
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
    var host: PairedHost?
    var connected = false
    var busy = false
    var error: String?
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
            snapshot = selected.flatMap { recentConversations.visit($0) } ?? .null
            syncStates = syncStates.filter { recentConversations.contains($0.key) }
        }
    }
    var snapshot: RemoteJSON = .null {
        didSet {
            recentConversations.update(snapshot)
            if let id = snapshot["id"].string { optimisticMessages[id]?.reconcile(snapshot) }
        }
    }
    var drafts: [String:String] = [:]
    private var optimisticMessages: [String: RemoteOptimisticMessages] = [:]
    private var deletions = RemoteSessionDeletions()
    // A notice can be acknowledged globally while a pending DELETE defers a
    // resident history. Keep that history dirty until a read applies or it leaves cache.
    private var deferredHistoryRefreshes: Set<String> = []
    // Invalidate reads spanning local sends/deletions so they cannot roll back UI state.
    private var snapshotGeneration = 0
    var displaySnapshot: RemoteJSON {
        guard let selected else { return snapshot }
        return optimisticMessages[selected]?.project(snapshot) ?? snapshot
    }
    var awaitingSendSnapshot: Bool { selected.flatMap { optimisticMessages[$0]?.awaitingSnapshot } ?? false }
    private var recentConversations = RecentConversationCache()
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
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.client = client; self.saveHost = saveHost; self.forgetHost = forgetHost
        self.sleep = sleep
        do { host = try loadHost() } catch { self.error = error.localizedDescription }
    }
    var active: Bool { RemoteMessageSubmission.isActive(snapshot) }
    func pair(_ text: String) async {
        guard !busy else { return }
        do {
            let invitation = try PairingInvitation.parse(text)
            let host = PairedHost(invitation: invitation, deviceName: "iPhone")
            // Save before pairing. A lost acknowledgement must not lose the identity
            // that the host may already have registered.
            try saveHost(host)
            clearConversationState()
            self.host = host
            await connect()
        } catch { self.error = error.localizedDescription }
    }
    func connect(resetBackoff: Bool = true) async {
        guard var host, !busy, !Task.isCancelled else { return }
        let generation = connectionGeneration
        busy = true; connected = false; error = nil
        defer { busy = false }
        do {
            try await client.connect(host)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            host.invitation.secret = nil
            try saveHost(host); self.host = host
            let models = try await client.request("GET", "/v1/models").array
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            try await refresh()
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            self.models = models; connected = true
            if resetBackoff { reconnectDelay = 1.5 }
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            connected = false; self.error = error.localizedDescription
            reconnectDelay = min(reconnectDelay * 2, 30)
        }
    }
    func suspend() async {
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
        guard !busy else { return }
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
        guard connected else { throw RemoteFailure("Connect to the agent first.") }
        return try await client.request("POST", "/v1/workspaces/browse", body: .object([
            "path": .optional(path), "showHidden": .bool(showHidden)
        ]))
    }
    private func clearConversationState() {
        hostGeneration += 1
        settings = RemoteSettingsDraft()
        recentConversations = RecentConversationCache()
        syncStates = [:]; readTickets = [:]; loadingEarlier = []
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
        let list = try await client.request("GET", "/v1/conversations").array
        guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
              readGeneration == snapshotGeneration, ticket == catalogReadTicket else { return false }
        let settings = try await client.request("GET", "/v1/library")
        guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
              readGeneration == snapshotGeneration, ticket == catalogReadTicket else { return false }
        conversations = deletions.reconcile(list); library = settings
        hasLoadedConversations = true
        let ids = Set(conversations.compactMap { $0["id"].string }).union(deletions.pendingIDs)
        recentConversations.retain(ids)
        deferredHistoryRefreshes = deferredHistoryRefreshes.filter { recentConversations.contains($0) }
        syncStates = syncStates.filter { recentConversations.contains($0.key) }
        optimisticMessages = optimisticMessages.filter { ids.contains($0.key) }
        if let id = selected, !ids.contains(id) { selected = nil; snapshot = .null }
        return true
    }
    @discardableResult private func refreshConversation(_ id: String) async throws -> Bool {
        let generation = hostGeneration, readGeneration = snapshotGeneration, connection = connectionGeneration
        readTickets[id, default: 0] += 1
        let ticket = readTickets[id]
        let path = "/v1/conversations/\(id)/sync"
        let value = try await client.request("GET", syncStates[id]?.refreshPath(path) ?? path)
        guard generation == hostGeneration, connection == connectionGeneration, !Task.isCancelled,
              readGeneration == snapshotGeneration, ticket == readTickets[id] else { return false }
        guard recentConversations.contains(id) else { return true }
        let state = try syncStates[id].map { try $0.refreshed(value) } ?? RemoteTranscriptSync.initial(value)
        syncStates[id] = state
        recentConversations.update(state.snapshot)
        optimisticMessages[id]?.reconcile(state.snapshot)
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
            snapshot = older.snapshot
        } catch {
            guard generation == hostGeneration, connection == connectionGeneration,
                  !Task.isCancelled, selected == id else { return }
            self.error = error.localizedDescription
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
            if host != nil, !busy {
                if !(await client.isConnected) { connected = false }
                guard isObserving(generation) else { return }
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
                        guard isObserving(generation) else { return }
                        guard observedHost == hostGeneration, connection == connectionGeneration else { continue }
                        self.error = error.localizedDescription
                        reconnectDelay = min(reconnectDelay * 2, 30)
                        await disconnectConnection()
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
        guard host != nil, !busy, !Task.isCancelled else { return }
        let generation = connectionGeneration
        let transportConnected = await client.isConnected
        guard generation == connectionGeneration, !Task.isCancelled else { return }
        if !transportConnected { connected = false }
        if !connected {
            if reconnect { await connect() }
            return
        }
        do {
            if let id = selected, active || awaitingSendSnapshot { try await refreshConversation(id) }
            else { try await refresh() }
        } catch {
            let transportConnected = await client.isConnected
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            // An API rejection does not mean the WebSocket was lost.
            if !transportConnected { connected = false }
            self.error = error.localizedDescription
        }
    }
    @discardableResult func open(_ id: String) -> Task<Void, Never> {
        selected = id
        let generation = hostGeneration, connection = connectionGeneration
        // This read belongs to the store, not the conversation view. Cancelling
        // a view-owned in-flight read would close the shared ordered WebSocket
        // when navigating back to All Sessions. Finish it and cache the result;
        // refreshConversation only displays it if the same session is selected.
        return Task {
            guard generation == hostGeneration, connection == connectionGeneration else { return }
            do {
                try await refreshConversation(id)
            } catch {
                if generation == hostGeneration, connection == connectionGeneration, selected == id {
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func showSettings() {
        settings.refresh(library)
        settings.isPresented = true
    }
    @discardableResult func finishSettings() -> Task<Void, Never>? {
        // Claim ownership before scheduling work: a second tap must not enqueue
        // another PATCH, even before the first task gets actor time.
        guard settings.isPresented else { return nil }
        guard settings.hasUnsavedChanges else { settings.dismiss(); return nil }
        guard connected, !busy, settingsSaveTask == nil else { return nil }
        let prompt = settings.prompt, generation = hostGeneration
        let body: RemoteJSON = .object(["settings": .object(["systemPrompt": .string(prompt)])])
        busy = true; error = nil; settings.error = nil
        settings.dismiss()
        // Owned by the store, not a SwiftUI .task or a captured dismiss action.
        // Dismissing/recreating the sheet must not cancel or replay this write.
        let task = Task {
            defer { busy = false; settingsSaveTask = nil }
            do {
                let value = try await client.request("PATCH", "/v1/library", body: body)
                guard generation == hostGeneration else { return }
                settings.accept(prompt)
                library = value
            } catch {
                guard generation == hostGeneration else { return }
                settings.fail(error)
                return
            }
            // Acceptance is final; a failed follow-up read is not a failed save.
            do { try await refresh() }
            catch { if generation == hostGeneration { self.error = error.localizedDescription } }
        }
        settingsSaveTask = task
        return task
    }
    func mutate(_ method: String, _ path: String, _ body: RemoteJSON, onSuccess: ((RemoteJSON) -> Void)? = nil) async {
        guard connected, !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await client.request(method, path, body: body)
            onSuccess?(value)
            try await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func deleteConversation(_ id: String) async {
        guard connected, !busy, let conversation = conversations.first(where: { $0.id == id }),
              !RemoteMessageSubmission.isActive(conversation) else { return }
        busy = true; error = nil
        let generation = hostGeneration
        snapshotGeneration += 1
        deletions.begin(conversation)
        withAnimation { conversations = deletions.project(conversations) }
        if selected == id { selected = nil }
        defer { busy = false }
        do {
            _ = try await client.request("DELETE", "/v1/conversations/\(id)")
            guard generation == hostGeneration else { return }
            snapshotGeneration += 1
            deletions.accept(id)
            recentConversations.remove(id)
            deferredHistoryRefreshes.remove(id)
            syncStates.removeValue(forKey: id)
            readTickets[id, default: 0] += 1
            optimisticMessages.removeValue(forKey: id)
            drafts.removeValue(forKey: id)
        } catch {
            guard generation == hostGeneration else { return }
            snapshotGeneration += 1
            if let restored = deletions.fail(id), !conversations.contains(where: { $0.id == id }) {
                withAnimation { conversations.append(restored) }
            }
            self.error = error.localizedDescription
            return
        }
        // Acceptance is final. A later refresh error must not resurrect the row.
        do { try await refresh() }
        catch { if generation == hostGeneration { self.error = error.localizedDescription } }
    }
    func send() async {
        guard connected, !busy, !awaitingSendSnapshot,
              let id = selected, let text = drafts[id],
              let submission = RemoteMessageSubmission(conversationID: id, snapshot: snapshot, text: text) else { return }
        busy = true; error = nil
        snapshotGeneration += 1
        let generation = hostGeneration
        let localID = optimisticMessages[id, default: RemoteOptimisticMessages()].begin(text: text, snapshot: snapshot)
        drafts[id] = ""
        defer { busy = false }
        do {
            let response = try await client.request("POST", submission.path, body: submission.body)
            guard generation == hostGeneration else { return }
            optimisticMessages[id]?.accept(localID, response: response)
        } catch {
            guard generation == hostGeneration else { return }
            optimisticMessages[id]?.remove(localID)
            // Preserve anything typed while the request was in flight. Never
            // automatically resubmit a request whose acknowledgement was lost.
            let newerDraft = drafts[id] ?? ""
            drafts[id] = newerDraft.isEmpty ? text : text + "\n\n" + newerDraft
            self.error = error.localizedDescription + " Check the refreshed conversation before sending again."
            return
        }
        // A failed read after acceptance is not a failed send. Keep its local
        // row until a later snapshot confirms it, without restoring the draft.
        do { try await refreshConversation(id) }
        catch { self.error = error.localizedDescription }
    }
    func stop() async {
        guard let id = selected, let operation = snapshot["operation"]["id"].string else { return }
        await mutate("POST", "/v1/conversations/\(id)/cancel", .object(["operationID":.string(operation)]))
    }
    func approve(_ approved: Bool) async {
        guard let id = selected, let approval = snapshot["approval"]["id"].string,
              let operation = snapshot["approval"]["operationID"].string else { return }
        await mutate("POST", "/v1/conversations/\(id)/approvals", .object(["approvalID":.string(approval), "operationID":.string(operation), "approved":.bool(approved)]))
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
