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
    var selected: String?
    var snapshot: RemoteJSON = .null
    var drafts: [String:String] = [:]
    private let client = RelayClient()
    init() { do { host = try DeviceStore.load() } catch { self.error = error.localizedDescription } }
    var active: Bool { ["running", "awaiting_approval", "cancelling"].contains(snapshot["operation"]["state"].string ?? "") }
    func pair(_ text: String) async {
        guard !busy else { return }
        do {
            let invitation = try PairingInvitation.parse(text)
            let host = PairedHost(invitation: invitation, deviceName: "iPhone")
            // Save before pairing. A lost acknowledgement must not lose the identity
            // that the host may already have registered.
            try DeviceStore.save(host); self.host = host
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
            try DeviceStore.forget(); await suspend(); host = nil; selected = nil
            conversations = []; snapshot = .null; drafts = [:]; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async throws {
        let list = try await client.request("GET", "/v1/conversations").array
        let settings = try await client.request("GET", "/v1/library")
        conversations = list; library = settings
        if let id = selected {
            if !list.contains(where: { $0["id"].string == id }) { selected = nil; snapshot = .null; return }
            let value = try await client.request("GET", "/v1/conversations/\(id)")
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
        selected = id; snapshot = .null
        do {
            let value = try await client.request("GET", "/v1/conversations/\(id)")
            if selected == id { snapshot = value }
        } catch { self.error = error.localizedDescription }
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
    func send() async {
        guard let id = selected, !active, snapshot["id"].string == id, let text = drafts[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Clear only after acceptance. An interrupted send preserves the draft but
        // is never automatically resubmitted.
        await mutate("POST", "/v1/conversations/\(id)/turns", .object(["text":.string(text)])) { _ in
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
