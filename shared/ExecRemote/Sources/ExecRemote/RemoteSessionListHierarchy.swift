import Foundation

/// Groups by root-session activity, then places each family's descendants in
/// host catalog order. The flat day grouping remains available to other callers.
public struct RemoteSessionListDay: Identifiable {
    public let day: RemoteSessionDay
    public let rows: [Row]
    public var id: Date { day.id }

    public struct Row: Identifiable {
        public let conversation: RemoteJSON
        public let depth: Int
        public var id: String { conversation["id"].string ?? "" }
        // Orphans still retain their sub-agent presentation and deletion rules.
        public var isSubagent: Bool { conversation["metadata"]["parent"] != .null }
    }

    public static func group(_ conversations: [RemoteJSON], calendar: Calendar = .current) -> [Self] {
        let ids = Set(conversations.compactMap { $0["id"].string })
        var parents: [String: String] = [:]
        for conversation in conversations {
            guard let id = conversation["id"].string,
                  let parent = conversation["metadata"]["parent"]["sessionId"].string,
                  parent != id, ids.contains(parent) else { continue }
            parents[id] = parent
        }

        // Break one link per cycle, deterministically in catalog order. Missing
        // parents and self-links already act as roots, so no rows disappear.
        var resolved: Set<String> = []
        for conversation in conversations {
            var path: Set<String> = []
            var current = conversation["id"].string
            while let id = current, !resolved.contains(id) {
                guard path.insert(id).inserted else {
                    parents.removeValue(forKey: id)
                    break
                }
                current = parents[id]
            }
            resolved.formUnion(path)
        }

        var roots: [RemoteJSON] = []
        var children: [String: [RemoteJSON]] = [:]
        for conversation in conversations {
            if let id = conversation["id"].string, let parent = parents[id] {
                children[parent, default: []].append(conversation)
            } else {
                roots.append(conversation)
            }
        }

        return RemoteSessionDay.group(roots, calendar: calendar).map { day in
            var rows: [Row] = []
            for root in day.conversations {
                // Iterative preorder also handles deeply nested imported catalogs.
                var stack = [Row(conversation: root, depth: 0)]
                while let row = stack.popLast() {
                    rows.append(row)
                    for child in (children[row.id] ?? []).reversed() {
                        stack.append(Row(conversation: child, depth: row.depth + 1))
                    }
                }
            }
            return Self(day: day, rows: rows)
        }
    }
}
