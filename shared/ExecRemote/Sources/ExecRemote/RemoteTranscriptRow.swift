/// Stable, display-only rows. Completed results replace entered/pending tools;
/// speculative calls are never presented as executed.
public struct RemoteTranscriptRow: Equatable, Sendable {
    public let id: String
    public let message: RemoteJSON
    public var call: RemoteJSON?
    public var awaitingApproval = false
    public static func project(_ snapshot: RemoteJSON) -> [Self] {
        func identifier(_ value: RemoteJSON) -> String { value["id"].string ?? "" }
        let messages = snapshot["messages"].array
        var calls: [String: (call: RemoteJSON, rowID: String)] = [:]
        for message in messages where message["role"].string == "assistant" {
            for call in message["calls"].array where !identifier(call).isEmpty { calls[identifier(call)] = (call, "tool:\(identifier(message)):\(identifier(call))") }
        }
        let answered = Set(messages.filter { $0["role"].string == "tool" }.compactMap { $0["callID"].string })
        let approval = snapshot["approval"]["call"]["id"].string
        let active = snapshot["activeToolCallID"].string
        var rows: [Self] = []
        for message in messages {
            if message["role"].string == "tool", let id = message["callID"].string, let source = calls[id] {
                rows.append(Self(id: source.rowID, message: message, call: source.call))
            } else {
                if message["role"].string != "assistant" || !(message["text"].string ?? "").isEmpty || !message["images"].array.isEmpty {
                    rows.append(Self(id: identifier(message), message: message))
                }
                for call in message["calls"].array where !answered.contains(identifier(call)) && (identifier(call) == approval || identifier(call) == active) {
                    if let source = calls[identifier(call)] { rows.append(Self(id: source.rowID, message: .null, call: call, awaitingApproval: identifier(call) == approval)) }
                }
            }
        }
        return rows
    }
}
