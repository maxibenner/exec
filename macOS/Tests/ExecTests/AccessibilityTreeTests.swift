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
            try AccessibilityTree.contains(target, in: window) { tree[$0, default: []].prefix($1).map { $0 } }
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
        let absent = try AccessibilityTree.contains(3, in: 0) { node, limit in
            reads += 1
            return Array(cyclic[node, default: []].prefix(limit))
        }
        try expect(!absent && reads == 3)
        let tooDeep = try AccessibilityTree.contains(4, in: 0, maximumDepth: 2) { node, _ in [node + 1] }
        try expect(!tooDeep)
        let tooWide = try AccessibilityTree.contains(50, in: 0, maximumElements: 4) { _, _ in Array(1...100) }
        try expect(!tooWide)
        let expired = try AccessibilityTree.contains(1, in: 0, timeLimit: .zero) { _, _ in
            throw CheckFailure(description: "Expired traversal must not read more elements")
        }
        try expect(!expired)
        let cancelled = Task {
            try AccessibilityTree.contains(1, in: 0) { _, _ in
                throw CheckFailure(description: "Cancelled traversal must not read elements")
            }
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Expected cancellation") }
        catch is CancellationError {}
    }
}
