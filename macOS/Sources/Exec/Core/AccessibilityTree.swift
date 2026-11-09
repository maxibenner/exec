import Foundation

/// Prove current containment using exact references, not process IDs or AXWindow
/// attributes. Open/Save panels can expose controls backed by a different process.
enum AccessibilityTree {
    static func contains<Element: Hashable>(
        _ target: Element, in root: Element,
        maximumElements: Int = 160, maximumDepth: Int = 8,
        timeLimit: Duration = .seconds(2),
        children: (Element, Int) throws -> [Element]
    ) throws -> Bool {
        let start = ContinuousClock.now
        var queue: [(Element, Int)] = [(root, 0)]
        var visited = Set<Element>()
        var index = 0
        while index < queue.count, index < maximumElements {
            try Task.checkCancellation()
            guard start.duration(to: .now) < timeLimit else { return false }
            let (element, depth) = queue[index]
            index += 1
            guard visited.insert(element).inserted else { continue }
            if element == target { return true }
            let remaining = maximumElements - queue.count
            guard depth < maximumDepth, remaining > 0 else { continue }
            let next = try children(element, remaining)
            queue += next.prefix(remaining).map { ($0, depth + 1) }
        }
        return false
    }
}
