/// Stable, display-only rows. Partial and terminal results replace entered tools;
/// speculative calls are never presented as executed.
public struct RemoteTranscriptRow: Equatable, Sendable {
    public let id: String
    public let message: RemoteJSON
    public var call: RemoteJSON?
    public var awaitingApproval = false
    public var isRunning = false
    public var roundsTop = true
    public var roundsBottom = true
    public static func project(_ snapshot: RemoteJSON) -> [Self] {
        func identifier(_ value: RemoteJSON) -> String { value["id"].string ?? "" }
        let messages = snapshot["messages"].array
        var calls: [String: (call: RemoteJSON, rowID: String)] = [:]
        for message in messages where message["role"].string == "assistant" {
            for call in message["calls"].array where !identifier(call).isEmpty { calls[identifier(call)] = (call, "tool:\(identifier(message)):\(identifier(call))") }
        }
        // Row presence is not completion: a delegate may still own its executor.
        let represented = Set(messages.filter { $0["role"].string == "tool" }.compactMap { $0["callID"].string })
        let approval = snapshot["approval"]["call"]["id"].string
        let active = snapshot["activeToolCallID"].string
        let operationState = snapshot["operation"]["state"].string
        let operationCanRunTools = operationState == nil || operationState == "running" || operationState == "cancelling"
        var rows: [Self] = []
        for message in messages {
            if message["role"].string == "tool", let id = message["callID"].string, let source = calls[id] {
                rows.append(Self(id: source.rowID, message: message, call: source.call,
                                 isRunning: active == id || message["outcome"].string == "running"))
            } else {
                if message["role"].string != "assistant" || !(message["text"].string ?? "").isEmpty || !message["images"].array.isEmpty {
                    rows.append(Self(id: identifier(message), message: message))
                }
                for call in message["calls"].array where !represented.contains(identifier(call)) && (identifier(call) == approval || identifier(call) == active) {
                    if let source = calls[identifier(call)] {
                        rows.append(Self(id: source.rowID, message: .null, call: call,
                                         awaitingApproval: identifier(call) == approval,
                                         isRunning: identifier(call) == active && identifier(call) != approval && operationCanRunTools))
                    }
                }
            }
        }
        // Pending input belongs to the queue, not to delivered transcript rows.
        // Join only adjacent displayed tools. Keep each row's identity/disclosure,
        // and include boundaries in equality so existing neighbors reconfigure.
        for index in rows.indices where rows[index].call != nil {
            rows[index].roundsTop = index == 0 || rows[index - 1].call == nil
            rows[index].roundsBottom = index + 1 == rows.count || rows[index + 1].call == nil
        }
        return rows
    }
}
