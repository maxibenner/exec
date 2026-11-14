/// Keeps pending/acknowledged deletions out of stale list snapshots. A failed
/// request restores the latest known row; a failed refresh after success does not.
public struct RemoteSessionDeletions {
    private var pending: [String: RemoteJSON] = [:]
    private var confirmed: Set<String> = []
    public var pendingIDs: Set<String> { Set(pending.keys) }
    public init() {}

    public mutating func begin(_ conversation: RemoteJSON) {
        guard let id = conversation["id"].string else { return }
        pending[id] = conversation
    }
    public mutating func accept(_ id: String) {
        pending.removeValue(forKey: id)
        confirmed.insert(id)
    }
    public mutating func fail(_ id: String) -> RemoteJSON? {
        pending.removeValue(forKey: id)
    }
    public func project(_ conversations: [RemoteJSON]) -> [RemoteJSON] {
        conversations.filter { conversation in
            guard let id = conversation["id"].string else { return true }
            return pending[id] == nil && !confirmed.contains(id)
        }
    }
    public mutating func reconcile(_ conversations: [RemoteJSON]) -> [RemoteJSON] {
        for conversation in conversations {
            if let id = conversation["id"].string, pending[id] != nil { pending[id] = conversation }
        }
        // Only a post-acknowledgement list without this ID retires its tombstone.
        // The store rejects reads issued before the acknowledgement by generation.
        confirmed.formIntersection(conversations.compactMap { $0["id"].string })
        return project(conversations)
    }
}
