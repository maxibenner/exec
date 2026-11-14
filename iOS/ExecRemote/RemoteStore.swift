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
        didSet { recentConversations.update(snapshot) }
    }
    var drafts: [String:String] = [:]
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
        selected = nil; snapshot = .null; conversations = []; drafts = [:]
    }
    func refresh() async throws {
        let generation = hostGeneration
        let list = try await client.request("GET", "/v1/conversations").array
        let settings = try await client.request("GET", "/v1/library")
        guard generation == hostGeneration else { return }
        conversations = list; library = settings
        recentConversations.retain(Set(list.compactMap { $0["id"].string }))
        if let id = selected {
            if !list.contains(where: { $0["id"].string == id }) { selected = nil; snapshot = .null; return }
            let value = try await client.request("GET", "/v1/conversations/\(id)")
            guard generation == hostGeneration else { return }
            recentConversations.update(value)
            if selected == id { snapshot = value }
        }
    }
    func observe() async {
        if host != nil, !connected { await connect() }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1.5))
                if connected && !busy { try await refresh() }
            } catch is CancellationError { break }
            catch { if !Task.isCancelled { connected = false; self.error = error.localizedDescription } }
        }
    }
    func open(_ id: String) async {
        selected = id
        let generation = hostGeneration
        do {
            let value = try await client.request("GET", "/v1/conversations/\(id)")
            guard generation == hostGeneration else { return }
            recentConversations.update(value)
            if selected == id { snapshot = value }
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
            self.drafts.removeValue(forKey: id)
            if self.selected == id { self.selected = nil; self.snapshot = .null }
        }
    }
    func send() async {
        guard let id = selected, let text = drafts[id],
              let submission = RemoteMessageSubmission(conversationID: id, snapshot: snapshot, text: text) else { return }
        // Clear only after acceptance. An interrupted send preserves the draft but
        // is never automatically resubmitted, including queued steering input.
        await mutate("POST", submission.path, submission.body) { _ in
            if self.drafts[id] == text { self.drafts[id] = "" }
        }
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
