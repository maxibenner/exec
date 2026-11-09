import Foundation

@MainActor struct AccessibilityTreeTests {
    private struct Reference: Hashable {
        let id: Int
        let processID: Int
    }

    func verifiesRemotePanelMembership() throws {
        let window = Reference(id: 1, processID: 42)
        let remotePanel = Reference(id: 2, processID: 80)
        let button = Reference(id: 3, processID: 80)
        let unrelated = Reference(id: 4, processID: 42)
        var tree: [Reference: [Reference]] = [window: [remotePanel], remotePanel: [button]]
        func contains(_ target: Reference) throws -> Bool {
            let path = target == window ? [window] : target == button ? [window, remotePanel, button] : [window, target]
            return try AccessibilityTree.containsPath(path, in: window) { tree[$0, default: []].prefix($1).map { $0 } }
        }
        // Membership works across process boundaries and needs no AXWindow attribute.
        try expect(try contains(button))
        try expect(try contains(window))
        // Sharing the host PID is not sufficient proof of containment.
        try expect(try !contains(unrelated))
        // A saved reference that was once in this tree must still be reachable now.
        tree[remotePanel] = []
        try expect(try !contains(button))
        // Another control in the same service cannot substitute for the saved reference.
        tree[remotePanel] = [Reference(id: 5, processID: 80)]
        try expect(try !contains(button))
    }

    func boundsTraversalAndHonorsCancellation() async throws {
        let cyclic = [0: [1], 1: [0, 2], 2: [1]]
        var reads = 0
        let absent = try await AccessibilityTree.search(in: 0, matches: { $0 == 3 }) { node, limit in
            reads += 1
            return Array(cyclic[node, default: []].prefix(limit))
        }
        try expect(absent.paths.isEmpty && !absent.truncated && reads == 3)
        let tooDeep = try await AccessibilityTree.search(in: 0, maximumDepth: 2, matches: { $0 == 4 }) { node, _ in [node + 1] }
        try expect(tooDeep.paths.isEmpty && tooDeep.truncated)
        let tooWide = try await AccessibilityTree.search(in: 0, maximumElements: 4, matches: { $0 == 50 }) { _, _ in Array(1...100) }
        try expect(tooWide.paths.isEmpty && tooWide.truncated)
        let expired = try await AccessibilityTree.search(in: 0, timeLimit: .zero, matches: { _ in true }) { _, _ in
            throw CheckFailure(description: "Expired traversal must not read more elements")
        }
        try expect(expired.paths.isEmpty && expired.truncated)
        let cancelled = Task {
            try await AccessibilityTree.search(in: 0, matches: { _ in true }) { _, _ in
                throw CheckFailure(description: "Cancelled traversal must not read elements")
            }
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Expected cancellation") }
        catch is CancellationError {}
        try expect(try !AccessibilityTree.containsPath([0, 1], in: 0, timeLimit: .zero) { _, _ in [1] })
        try expect(try !AccessibilityTree.containsPath([0, 1, 0], in: 0) { _, _ in [0, 1] })
        try expect(try !AccessibilityTree.containsPath(Array(0...13), in: 0) { node, _ in [node + 1] })
    }

    func findsFileBeyondSidebarAndValidatesAncestry() async throws {
        // Hundreds of sidebar nodes precede an unlabeled file row and its label.
        var tree = [0: [1, 2], 1: Array(10...250), 2: [3], 3: [4]]
        let found = try await AccessibilityTree.search(in: 0, matches: { $0 == 4 }) { node, limit in
            Array(tree[node, default: []].prefix(limit))
        }
        try expect(found.paths == [[0, 2, 3, 4]] && !found.truncated)
        let path = found.paths[0]
        var reads: [Int] = []
        let valid = try AccessibilityTree.containsPath(path, in: 0) { node, limit in
            reads.append(node)
            return Array(tree[node, default: []].prefix(limit))
        }
        try expect(valid && reads == [0, 2, 3]) // No second sidebar traversal.
        tree[2] = [] // Same reference under a detached row is not valid.
        try expect(try !AccessibilityTree.containsPath(path, in: 0) { node, limit in Array(tree[node, default: []].prefix(limit)) })
        let limited = try await AccessibilityTree.search(in: 0, maximumMatches: 1, matches: { _ in true }) { node, limit in
            Array(tree[node, default: []].prefix(limit))
        }
        try expect(limited.paths.count == 1 && limited.truncated)
    }
}
