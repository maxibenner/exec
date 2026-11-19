import Foundation

/// Display-only input. Authoritative snapshots and operation IDs still control
/// execution; local rows never enter the recent-snapshot cache.
public struct RemoteOptimisticMessages {
    private struct Read {
        let snapshot: RemoteJSON
        let reset: Bool
    }
    private struct Pending {
        let id: String
        let text: String
        let previousMessageIDs: Set<String>
        let previousOperation: RemoteJSON
        var accepted = false
        var operationID: String?
        var messageID: String?
        // A read may arrive before the command acknowledgement. Remember it so
        // accepting a late reply cannot resurrect input already cleared by the host.
        var latestRead: Read?
    }
    private var pending: [Pending] = []
    private var rowIDs: [String: String] = [:]
    public var awaitingSnapshot: Bool { !pending.isEmpty }
    public init() {}

    @discardableResult
    public mutating func begin(text: String, snapshot: RemoteJSON, id: String = "local-\(UUID().uuidString)") -> String {
        pending.append(Pending(id: id, text: text,
                               previousMessageIDs: Set(Self.messages(snapshot).compactMap { $0["id"].string }),
                               previousOperation: snapshot["operation"]))
        return id
    }

    /// Returns whether the acknowledgement still needs an authoritative read.
    @discardableResult
    public mutating func accept(_ id: String, response: RemoteJSON) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        pending[index].accepted = true
        pending[index].operationID = response["operationID"].string
        pending[index].messageID = response["messageID"].string
        // Exact IDs remain useful if a reset omits the message and it is loaded later.
        if let message = pending[index].messageID { rowIDs[message] = id }
        let input = pending[index]
        if let read = input.latestRead,
           Self.resolve(input, snapshot: read.snapshot, reset: read.reset, rowIDs: &rowIDs) {
            pending.remove(at: index)
        }
        return input.latestRead == nil
    }

    public mutating func remove(_ id: String) { pending.removeAll { $0.id == id } }

    /// Cached snapshots can reconcile identity, but cannot prove that input was removed.
    public mutating func reconcile(_ snapshot: RemoteJSON) {
        pending.removeAll { Self.resolve($0, snapshot: snapshot, reset: nil, rowIDs: &rowIDs) }
    }

    /// Only a validated, current host refresh may retire missing accepted input.
    public mutating func reconcile(_ state: RemoteTranscriptSync) {
        for index in pending.indices {
            pending[index].latestRead = Read(snapshot: state.snapshot, reset: state.didReset)
        }
        pending.removeAll { Self.resolve($0, snapshot: state.snapshot, reset: state.didReset, rowIDs: &rowIDs) }
    }

    private static func resolve(_ input: Pending, snapshot: RemoteJSON, reset: Bool?, rowIDs: inout [String: String]) -> Bool {
        guard input.accepted else { return false }
        let messages = messages(snapshot)
        let operation = snapshot["operation"]["id"].string
        let previous = input.previousOperation["id"].string
        // A turn reply has no message ID. After an operation transition, require
        // continuity with the old history rather than borrowing identical text
        // from a replacement/cleared conversation.
        let hasContinuity = messages.contains { input.previousMessageIDs.contains($0["id"].string ?? "") }
        let canMatchTurn = input.operationID != nil && (operation == input.operationID
            || (operation != nil && operation != previous && hasContinuity))
        let match = messages.first { message in
            guard message["role"].string == "user", let id = message["id"].string else { return false }
            if let messageID = input.messageID { return id == messageID }
            return canMatchTurn && !input.previousMessageIDs.contains(id)
                && rowIDs[id] == nil && message["text"].string == input.text
        }
        if let message = match?["id"].string {
            rowIDs[message] = input.id
            return true
        }
        guard let reset else { return false }
        // Resets replace the entire loaded suffix, not necessarily the entire
        // history. Missing input belongs to the host, never to a permanent overlay.
        return reset || operation == nil
            || (operation != input.operationID && operation != previous)
            || (operation == input.operationID && !RemoteMessageSubmission.isActive(snapshot))
    }

    public func project(_ snapshot: RemoteJSON) -> RemoteJSON {
        guard case .object(var value) = snapshot else { return snapshot }
        for key in ["messages", "pendingInput"] {
            value[key] = .array(snapshot[key].array.map { message in
                guard let id = message["id"].string, let rowID = rowIDs[id],
                      case .object(var fields) = message else { return message }
                fields["id"] = .string(rowID)
                return .object(fields)
            })
        }
        value["pendingInput"] = .array((value["pendingInput"]?.array ?? []) + pending.map {
            .object(["id": .string($0.id), "role": .string("user"), "text": .string($0.text)])
        })
        // A spinner is only a bridge over the unchanged pre-send snapshot.
        // Never replace a canonical newer, terminal or cleared operation.
        if !RemoteMessageSubmission.isActive(snapshot), pending.contains(where: {
            $0.latestRead == nil && $0.previousOperation == snapshot["operation"]
                && ($0.operationID == nil || $0.operationID != snapshot["operation"]["id"].string)
        }) {
            value["operation"] = .object(["state": .string("running")])
        }
        return .object(value)
    }

    private static func messages(_ snapshot: RemoteJSON) -> [RemoteJSON] {
        snapshot["messages"].array + snapshot["pendingInput"].array
    }
}
