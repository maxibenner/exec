import Foundation

/// Display-only input. Authoritative snapshots and operation IDs still control
/// execution; local rows never enter the recent-snapshot cache.
public struct RemoteOptimisticMessages {
    private struct Pending {
        let id: String
        let text: String
        let previousMessageIDs: Set<String>
        let previousOperationID: String?
        var operationID: String?
        var messageID: String?
    }
    private var pending: [Pending] = []
    private var rowIDs: [String: String] = [:]
    public var awaitingSnapshot: Bool { !pending.isEmpty }
    public init() {}

    @discardableResult
    public mutating func begin(text: String, snapshot: RemoteJSON, id: String = "local-\(UUID().uuidString)") -> String {
        pending.append(Pending(id: id, text: text,
                               previousMessageIDs: Set(Self.messages(snapshot).compactMap { $0["id"].string }),
                               previousOperationID: snapshot["operation"]["id"].string))
        return id
    }

    public mutating func accept(_ id: String, response: RemoteJSON) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].operationID = response["operationID"].string
        pending[index].messageID = response["messageID"].string
    }

    public mutating func remove(_ id: String) { pending.removeAll { $0.id == id } }

    public mutating func reconcile(_ snapshot: RemoteJSON) {
        let messages = Self.messages(snapshot)
        pending.removeAll { input in
            guard input.operationID != nil else { return false }
            // Steering supplies an exact message ID. New turns supply only an
            // operation ID: match the first new user message after acceptance,
            // excluding old polls, even if another device has since begun a turn.
            let match = messages.first { message in
                guard message["role"].string == "user", let id = message["id"].string else { return false }
                if let messageID = input.messageID { return id == messageID }
                return snapshot["operation"]["id"].string != input.previousOperationID
                    && !input.previousMessageIDs.contains(id) && message["text"].string == input.text
            }
            guard let messageID = match?["id"].string else { return false }
            rowIDs[messageID] = input.id
            return true
        }
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
        // Don't infer completion from assistant text. A terminal host operation
        // wins once it acknowledges this input, even before row reconciliation.
        if pending.contains(where: { $0.operationID == nil || $0.operationID != snapshot["operation"]["id"].string }) {
            value["operation"] = .object(["state": .string("running")])
        }
        return .object(value)
    }

    private static func messages(_ snapshot: RemoteJSON) -> [RemoteJSON] {
        snapshot["messages"].array + snapshot["pendingInput"].array
    }
}
