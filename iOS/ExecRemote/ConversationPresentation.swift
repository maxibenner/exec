import ExecRemote

/// A destination keeps its own session content while the store changes selection
/// during a native navigation transition. Only matching snapshots can replace it.
struct ConversationPresentation {
    let conversationID: String
    private(set) var title: String
    private(set) var snapshot: RemoteJSON = .null

    init(conversationID: String, catalog: [RemoteJSON], snapshot: RemoteJSON) {
        self.conversationID = conversationID
        let row = catalog.first { $0["id"].string == conversationID } ?? .null
        title = row["metadata"]["title"].string ?? row["title"].string ?? "Chat"
        update(snapshot)
    }

    mutating func update(_ snapshot: RemoteJSON) {
        guard snapshot["id"].string == conversationID else { return }
        self.snapshot = snapshot
        title = snapshot["metadata"]["title"].string ?? snapshot["title"].string ?? title
    }
}
