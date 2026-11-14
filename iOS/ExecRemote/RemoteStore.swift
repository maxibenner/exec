import SwiftUI
import ExecRemote

@MainActor @Observable final class RemoteStore {
    var host: PairedHost?
    var connected = false
    var busy = false
    var error: String?
    var conversations: [RemoteJSON] = []
    var models: [RemoteJSON] = []
    var library: RemoteJSON = .null
    var selected: String? {
        didSet {
            guard selected != oldValue else { return }
            snapshot = selected.flatMap { recentConversations.visit($0) } ?? .null
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
    // Invalidate reads issued before a local send so they cannot roll it back.
    private var snapshotGeneration = 0
    var displaySnapshot: RemoteJSON {
        guard let selected else { return snapshot }
        return optimisticMessages[selected]?.project(snapshot) ?? snapshot
    }
    var awaitingSendSnapshot: Bool { selected.flatMap { optimisticMessages[$0]?.awaitingSnapshot } ?? false }
    private var recentConversations = RecentConversationCache()
    private var hostGeneration = 0
    private let client = RelayClient()
    init() { do { host = try DeviceStore.load() } catch { self.error = error.localizedDescription } }
    var active: Bool { RemoteMessageSubmission.isActive(snapshot) }
    func pair(_ text: String) async {
        guard !busy else { return }
        do {
            let invitation = try PairingInvitation.parse(text)
            let host = PairedHost(invitation: invitation, deviceName: "iPhone")
            // Save before pairing. A lost acknowledgement must not lose the identity
            // that the host may already have registered.
            try DeviceStore.save(host)
            clearConversationState()
            self.host = host
            await connect()
        } catch { self.error = error.localizedDescription }
    }
    func connect() async {
        guard var host, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await client.connect(host)
            host.invitation.secret = nil
            try DeviceStore.save(host); self.host = host; connected = true
            models = try await client.request("GET", "/v1/models").array
            try await refresh()
        } catch { connected = false; self.error = error.localizedDescription }
    }
    func suspend() async { connected = false; await client.disconnect() }
    func forget() async {
        guard !busy else { return }
        do {
            try DeviceStore.forget()
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
        optimisticMessages = [:]
        snapshotGeneration += 1
        selected = nil; snapshot = .null; conversations = []; drafts = [:]
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
        conversations = list; library = settings
        let ids = Set(list.compactMap { $0["id"].string })
        recentConversations.retain(ids)
        optimisticMessages = optimisticMessages.filter { ids.contains($0.key) }
        if let id = selected, !ids.contains(id) { selected = nil; snapshot = .null }
        else if selected == visibleID, let readFailure { throw readFailure }
    }
    private func refreshConversation(_ id: String) async throws {
        let generation = hostGeneration, readGeneration = snapshotGeneration
        let value = try await client.request("GET", "/v1/conversations/\(id)")
        guard generation == hostGeneration, readGeneration == snapshotGeneration else { return }
        optimisticMessages[id]?.reconcile(value)
        recentConversations.update(value)
        if selected == id { snapshot = value }
    }
    func observe() async {
        if host != nil, !connected { await connect() }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(active || awaitingSendSnapshot ? 0.5 : 1.5))
                if connected && !busy {
                    if let id = selected, active || awaitingSendSnapshot { try await refreshConversation(id) }
                    else { try await refresh() }
                }
            } catch is CancellationError { break }
            catch { if !Task.isCancelled { connected = false; self.error = error.localizedDescription } }
        }
    }
    func open(_ id: String) async {
        selected = id
        let generation = hostGeneration
        do {
            try await refreshConversation(id)
        } catch {
            if generation == hostGeneration, selected == id { self.error = error.localizedDescription }
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
        await mutate("DELETE", "/v1/conversations/\(id)", .null) { _ in
            self.recentConversations.remove(id)
            self.optimisticMessages.removeValue(forKey: id)
            self.drafts.removeValue(forKey: id)
            if self.selected == id { self.selected = nil; self.snapshot = .null }
        }
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
