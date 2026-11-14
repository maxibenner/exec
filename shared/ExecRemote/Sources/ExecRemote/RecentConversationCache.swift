import Foundation

/// In-memory, host-scoped snapshots for the three most recently viewed sessions.
/// Refreshes never change recency or resurrect an evicted/deleted session.
public struct RecentConversationCache {
    private var recent: [String] = []
    private var snapshots: [String: RemoteJSON] = [:]
    public init() {}

    public mutating func visit(_ id: String) -> RemoteJSON? {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 3 {
            let evicted = recent.removeLast()
            snapshots.removeValue(forKey: evicted)
        }
        return snapshots[id]
    }

    public func contains(_ id: String) -> Bool { recent.contains(id) }

    public mutating func update(_ snapshot: RemoteJSON) {
        guard let id = snapshot["id"].string, recent.contains(id) else { return }
        snapshots[id] = snapshot
    }

    public mutating func remove(_ id: String) {
        recent.removeAll { $0 == id }
        snapshots.removeValue(forKey: id)
    }

    public mutating func retain(_ ids: Set<String>) {
        recent.removeAll { !ids.contains($0) }
        snapshots = snapshots.filter { ids.contains($0.key) }
    }
}
