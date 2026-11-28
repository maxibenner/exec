import Foundation
import UserNotifications

@MainActor struct SessionNotificationTests {
    private func summary(_ base: AgentJSON, _ state: String, id: UUID = UUID(), kind: String = "turn",
                         title: String? = nil, storageError: String? = nil) throws -> AgentJSON {
        guard case .object(var fields) = base, case .object(var metadata) = fields["metadata"] else {
            throw CheckFailure(description: "Invalid session fixture")
        }
        fields["operation"] = .object(["id": .string(id.uuidString), "state": .string(state), "kind": .string(kind)])
        fields["storageError"] = storageError.map(AgentJSON.string) ?? .null
        if let title { metadata["title"] = .string(title); fields["metadata"] = .object(metadata) }
        fields.removeValue(forKey: "messages")
        return .object(fields)
    }

    private func refresh(_ fixture: LifecycleFixture, _ rows: AgentJSON...) async throws {
        try await fixture.transport.responses.reply("/v1/conversations", .array(rows))
        try await fixture.library.refreshSharedState()
    }

    @MainActor private final class Activation { var isActive = false }

    func backgroundCatalogTransitions() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.close() }
        try await fixture.start()
        let oldDone = try summary(fixture.root, "completed")
        let oldApproval = try summary(fixture.other, "awaiting_approval")
        let oldFailure = try summary(fixture.child, "failed")
        try await refresh(fixture, oldDone, oldApproval, oldFailure)

        let activation = Activation()
        var requests: [UNNotificationRequest] = []
        let notifications = SessionNotifications(isActive: { activation.isActive }, post: { requests.append($0) })
        fixture.library.didApplyCatalog = notifications.catalogDidChange
        // The restored catalog is a silent baseline.
        try await refresh(fixture, oldDone, oldApproval, oldFailure)
        try expect(requests.isEmpty)

        let turn = UUID(), approvalTurn = UUID(), childTurn = UUID()
        let running = try summary(fixture.root, "running", id: turn)
        let done = try summary(fixture.root, "completed", id: turn, title: "Renamed parent")
        let approval = try summary(fixture.other, "awaiting_approval", id: approvalTurn)
        let childRunning = try summary(fixture.child, "running", id: childTurn)
        let childDone = try summary(fixture.child, "completed", id: childTurn)
        let failed = try summary(fixture.child, "failed")
        try await refresh(fixture, running, oldApproval, childRunning)
        try await refresh(fixture, running, oldApproval, childDone)
        try expect(requests.isEmpty) // Successful sub-agents are silent.
        // The selected session and sessions without resident views use the same path.
        try expect(fixture.library.currentSessionID == fixture.parentID)
        try await refresh(fixture, done, approval, failed)
        try await refresh(fixture, done, approval, failed)
        try expect(requests.map { "\($0.content.title): \($0.content.body)" } == [
            "Session finished: Renamed parent", "Session failed: Lifecycle child", "Approval needed: Other session"
        ])
        try expect(requests.allSatisfy { $0.trigger == nil })

        activation.isActive = true
        let foregroundDone = try summary(fixture.root, "completed")
        let resumed = try summary(fixture.other, "running", id: approvalTurn)
        try await refresh(fixture, foregroundDone, resumed, failed)
        activation.isActive = false
        // A foreground completion must not replay when Exec goes inactive.
        try await refresh(fixture, foregroundDone, resumed, failed)
        try expect(requests.count == 3)
        try await refresh(fixture, foregroundDone, approval, failed)
        try expect(requests.count == 4 && requests.last?.content.title == "Approval needed")
    }

    func storageErrorsAreNotCompletions() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.close() }
        try await fixture.start()
        var requests: [UNNotificationRequest] = []
        let notifications = SessionNotifications(isActive: { false }, post: { requests.append($0) })
        fixture.library.didApplyCatalog = notifications.catalogDidChange

        let turn = UUID()
        let running = try summary(fixture.root, "running", id: turn)
        let compacted = try summary(fixture.other, "completed", kind: "compaction")
        let stopped = try summary(fixture.child, "interrupted")
        try await refresh(fixture, running, compacted, stopped)
        try expect(requests.isEmpty)
        let blocked = try summary(fixture.root, "completed", id: turn, storageError: "Private error detail")
        try await refresh(fixture, blocked, compacted, stopped)
        try await refresh(fixture, blocked, compacted, stopped)
        try expect(requests.count == 1 && requests.first?.content.title == "Session failed" &&
                   requests.first?.content.body == "Lifecycle parent")
    }
}
