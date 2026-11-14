import SwiftUI
import ExecRemote

protocol RemoteTransport: Sendable {
    var isConnected: Bool { get async }
    func connect(_ host: PairedHost) async throws
    func disconnect() async
    func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON
}
extension RemoteTransport {
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
    private(set) var reconnectDelay = 1.5
    private let client: any RemoteTransport
    private let saveHost: (PairedHost) throws -> Void
    private let forgetHost: () throws -> Void
    init(client: any RemoteTransport = RelayClient(),
         loadHost: () throws -> PairedHost? = { try DeviceStore.load() },
         saveHost: @escaping (PairedHost) throws -> Void = { try DeviceStore.save($0) },
         forgetHost: @escaping () throws -> Void = { try DeviceStore.forget() }) {
        self.client = client; self.saveHost = saveHost; self.forgetHost = forgetHost
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
    func connect() async {
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
            self.models = models; connected = true; reconnectDelay = 1.5
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            connected = false; self.error = error.localizedDescription
            reconnectDelay = min(reconnectDelay * 2, 30)
        }
    }
    func suspend() async {
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
            await suspend()
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
        recentConversations = RecentConversationCache()
        syncStates = [:]; readTickets = [:]; loadingEarlier = []
        optimisticMessages = [:]
        deletions = RemoteSessionDeletions()
        snapshotGeneration += 1
        selected = nil; snapshot = .null; conversations = []; drafts = [:]
        hasLoadedConversations = false
    }
    func refresh() async throws {
        let generation = hostGeneration, readGeneration = snapshotGeneration
        // Prioritize the visible turn (including its terminal state) rather than
        // making it wait behind list and settings round trips.
        let visibleID = selected
        var readFailure: Error?
        if let id = visibleID {
            do { try await refreshConversation(id) }
            catch { readFailure = error }
        }
        let list = try await client.request("GET", "/v1/conversations").array
        let settings = try await client.request("GET", "/v1/library")
        guard generation == hostGeneration, readGeneration == snapshotGeneration else { return }
        conversations = deletions.reconcile(list); library = settings
        hasLoadedConversations = true
        let ids = Set(conversations.compactMap { $0["id"].string }).union(deletions.pendingIDs)
        recentConversations.retain(ids)
        syncStates = syncStates.filter { recentConversations.contains($0.key) }
        optimisticMessages = optimisticMessages.filter { ids.contains($0.key) }
        if let id = selected, !ids.contains(id) { selected = nil; snapshot = .null }
        else if selected == visibleID, let readFailure { throw readFailure }
    }
    private func refreshConversation(_ id: String) async throws {
        let generation = hostGeneration, readGeneration = snapshotGeneration
        readTickets[id, default: 0] += 1
        let ticket = readTickets[id]
        let path = "/v1/conversations/\(id)/sync"
        let value = try await client.request("GET", syncStates[id]?.refreshPath(path) ?? path)
        guard generation == hostGeneration, readGeneration == snapshotGeneration,
              ticket == readTickets[id] else { return }
        let state = try syncStates[id].map { try $0.refreshed(value) } ?? RemoteTranscriptSync.initial(value)
        guard recentConversations.contains(id) else { return }
        syncStates[id] = state
        recentConversations.update(state.snapshot)
        // Transcript polling is more frequent than list polling during a turn.
        // Keep the row authoritative when returning to the session list.
        if let index = conversations.firstIndex(where: { $0.id == id }),
           case .object(var summary) = conversations[index] {
            summary["operation"] = state.snapshot["operation"]
            conversations[index] = .object(summary)
        }
        if selected == id { snapshot = state.snapshot }
    }
    func loadEarlier() async {
        guard connected, let id = selected, !loadingEarlier.contains(id),
              let state = syncStates[id], let path = state.earlierPath("/v1/conversations/\(id)/sync") else { return }
        loadingEarlier.insert(id)
        defer { loadingEarlier.remove(id) }
        let generation = hostGeneration, readGeneration = snapshotGeneration
        let first = state.snapshot["messages"].array.first?["id"].string
        do {
            let value = try await client.request("GET", path)
            guard generation == hostGeneration, readGeneration == snapshotGeneration,
                  selected == id, let current = syncStates[id],
                  current.snapshot["messages"].array.first?["id"].string == first else { return }
            let older = try current.prepending(value)
            syncStates[id] = older
            snapshot = older.snapshot
        } catch {
            guard generation == hostGeneration, selected == id else { return }
            self.error = error.localizedDescription
        }
    }
    func observe() async {
        while !Task.isCancelled {
            await poll()
            do {
                let delay = connected ? (active || awaitingSendSnapshot ? 0.5 : 1.5) : reconnectDelay
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
        }
    }
    // Only the foreground observer calls this. Recovery opens a fresh channel
    // and reads authoritative state; it never queues or replays a command.
    func poll() async {
        guard host != nil, !busy, !Task.isCancelled else { return }
        let generation = connectionGeneration
        let transportConnected = await client.isConnected
        guard generation == connectionGeneration, !Task.isCancelled else { return }
        if !transportConnected { connected = false }
        if !connected { await connect(); return }
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
extension RemoteJSON { var id: String { self["id"].string ?? "" } }
