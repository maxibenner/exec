import Foundation

/// Prove current containment using exact references, not process IDs or AXWindow
/// attributes. Open/Save panels can expose controls backed by a different process.
enum AccessibilityTree {
    /// Search has a larger traversal budget than the rendered view. Unmatched
    /// sidebar/structural nodes do not consume the result budget. Paths let actions
    /// validate only their saved ancestry rather than repeat the entire search.
    @MainActor static func search<Element: Hashable>(
        in root: Element, maximumElements: Int = 1000, maximumDepth: Int = 12,
        maximumMatches: Int = 160, timeLimit: Duration = .seconds(2),
        matches: (Element) throws -> Bool,
        children: (Element, Int) throws -> [Element]
    ) async throws -> (paths: [[Element]], truncated: Bool) {
        let start = ContinuousClock.now
        var queue = [[root]]
        var visited = Set<Element>()
        var paths: [[Element]] = []
        var index = 0
        var truncated = false
        while index < queue.count {
            try Task.checkCancellation()
            guard start.duration(to: .now) < timeLimit else { truncated = true; break }
            let path = queue[index]
            index += 1
            guard let element = path.last, visited.insert(element).inserted else { continue }
            if try matches(element) {
                guard paths.count < maximumMatches else { truncated = true; break }
                paths.append(path)
            }
            let remaining = max(0, maximumElements - queue.count)
            // Read one extra child to detect truncation, without scheduling it.
            let next = try children(element, remaining + 1)
            if path.count > maximumDepth || remaining == 0 {
                if !next.isEmpty { truncated = true }
            } else {
                if next.count > remaining { truncated = true }
                queue += next.prefix(remaining).map { path + [$0] }
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        return (paths, truncated)
    }

    static func containsPath<Element: Hashable>(
        _ path: [Element], in root: Element,
        timeLimit: Duration = .seconds(2),
        children: (Element, Int) throws -> [Element]
    ) throws -> Bool {
        guard path.first == root, path.count <= 13, Set(path).count == path.count else { return false }
        let start = ContinuousClock.now
        for (parent, child) in zip(path, path.dropFirst()) {
            try Task.checkCancellation()
            guard start.duration(to: .now) < timeLimit,
                  try children(parent, 1000).contains(child) else { return false }
        }
        try Task.checkCancellation()
        return true
    }
}
