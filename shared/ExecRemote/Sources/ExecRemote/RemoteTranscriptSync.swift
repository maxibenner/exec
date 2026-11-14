import Foundation

/// A bounded host page plus the loaded suffix of a conversation. The host's
/// prefix proof detects changes before the overlap message on the next poll.
public struct RemoteTranscriptSync {
    public let snapshot: RemoteJSON
    public let offset: Int
    public let total: Int
    private let prefix: String?

    public var hasEarlier: Bool { offset > 0 }

    public static func initial(_ response: RemoteJSON) throws -> Self {
        let page = try Page(response)
        guard page.reset, page.offset + page.messages.count == page.total else { throw RemoteFailure("Invalid conversation page.") }
        return Self(snapshot: page.snapshot, offset: page.offset, total: page.total, prefix: page.prefix)
    }

    public func refreshed(_ response: RemoteJSON) throws -> Self {
        let page = try Page(response)
        if page.reset { return try Self.initial(response) }
        let messages = snapshot["messages"].array
        guard let last = messages.last, page.messages.first?["id"].string == last["id"].string,
              page.offset == offset + messages.count - 1,
              page.offset + page.messages.count == page.total,
              page.snapshot["id"] == snapshot["id"] else { throw RemoteFailure("Conversation updates are out of order. Refresh the conversation.") }
        return Self(snapshot: page.snapshot.withMessages(Array(messages.dropLast()) + page.messages),
                    offset: offset, total: page.total, prefix: page.prefix)
    }

    public func prepending(_ response: RemoteJSON) throws -> Self {
        let page = try Page(response)
        guard !page.reset, page.snapshot["id"] == snapshot["id"],
              page.offset + page.messages.count == offset, page.total >= total,
              !page.messages.isEmpty else { throw RemoteFailure("Conversation history changed. Refresh the conversation.") }
        return Self(snapshot: snapshot.withMessages(page.messages + snapshot["messages"].array),
                    offset: page.offset, total: total, prefix: prefix)
    }

    public func refreshPath(_ base: String) -> String {
        guard let last = snapshot["messages"].array.last?["id"].string, let prefix else { return base }
        return "\(base)?after=\(last)&prefix=\(prefix)"
    }

    public func earlierPath(_ base: String) -> String? {
        guard hasEarlier, let first = snapshot["messages"].array.first?["id"].string else { return nil }
        return "\(base)?before=\(first)"
    }

    private struct Page {
        let snapshot: RemoteJSON
        let messages: [RemoteJSON]
        let offset: Int
        let total: Int
        let reset: Bool
        let prefix: String?
        init(_ response: RemoteJSON) throws {
            guard case .object = response, case .object = response["snapshot"],
                  case .array(let messages) = response["snapshot"]["messages"],
                  response["snapshot"]["id"].string != nil,
                  let offset = response["offset"].integer, let total = response["total"].integer,
                  let reset = response["reset"].boolean,
                  offset <= total, messages.count <= total - offset,
                  (total == 0 && response["prefix"] == .null) ||
                  (total > 0 && response["prefix"].string?.utf8.count == 64),
                  messages.allSatisfy({ $0["id"].string != nil }) else { throw RemoteFailure("Invalid conversation page.") }
            self.snapshot = response["snapshot"]; self.messages = messages
            self.offset = offset; self.total = total; self.reset = reset
            self.prefix = response["prefix"].string
        }
    }
}

private extension RemoteJSON {
    var integer: Int? {
        guard let number, number >= 0, number < Double(Int.max), number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }
    var boolean: Bool? { if case .bool(let value) = self { return value }; return nil }
    func withMessages(_ messages: [RemoteJSON]) -> Self {
        guard case .object(var value) = self else { return self }
        value["messages"] = .array(messages)
        return .object(value)
    }
}
