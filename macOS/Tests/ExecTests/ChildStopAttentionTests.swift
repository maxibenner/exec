import Foundation

@MainActor struct ChildStopAttentionTests {
    private let assistantID = UUID()

    private func snapshot(_ fixture: LifecycleFixture, state: String) throws -> AgentJSON {
        guard case .object(var fields) = fixture.child else { throw CheckFailure(description: "Invalid child fixture") }
        fields["operation"] = .object(["id": fixture.child["operation"]["id"], "state": .string(state)])
        fields["messages"] = .array(fixture.child["messages"].array + [.object([
            "id": .string(assistantID.uuidString), "role": .string("assistant"), "text": .string("Partial answer"),
            "status": .string(state == "interrupted" ? "interrupted" : "streaming"), "calls": .array([])])])
        return .object(fields)
    }

    func intentionalStopNeverFlashesAttentionDuringChildCleanup() async throws {
        for cleanupBeforeTerminalRead in [false, true] {
            let fixture = try LifecycleFixture(running: true)
            try await fixture.start()
            defer { fixture.close() }
            let library = fixture.library, path = AgentAPI.path(fixture.childID)
            try await fixture.transport.responses.reply(path, snapshot(fixture, state: "running"))
            try await fixture.transport.responses.reply(path + "/cancel", .object(["accepted": .bool(true)]))
            library.openSession(fixture.childID)
            await library.waitForNavigation()
            let child = library.current
            try expect(child.isSubagent && child.messages.last?.status == .streaming)
            var attention = library.needsAttention(fixture.childID)
            library.stop(); library.stop()
            try await SessionLifecycleTests.wait("child cancellation request") {
                attention = attention || library.needsAttention(fixture.childID)
                return await fixture.transport.responses.requests.contains { $0.path == path + "/cancel" }
            }
            try expect(child.isStopping && !attention)
            if cleanupBeforeTerminalRead {
                // Parent persistence/deletion wins the race with stop's cleanup read.
                // Keep confirmation suspended so even a brief error is observable.
                await fixture.transport.holdCatalogReads(true)
                try await fixture.removeChild(failSync: false)
                await fixture.transport.responses.fail(path + "/sync", status: 404)
                try await SessionLifecycleTests.wait("stop removal confirmation") {
                    attention = attention || library.needsAttention(fixture.childID)
                    return await fixture.transport.pendingCatalogs > 0
                }
                let stillIncomplete = child.messages.last?.status == .streaming
                await fixture.transport.holdCatalogReads(false)
                try await fixture.transport.finishCatalog(.array([fixture.root, fixture.other]))
                try expect(stillIncomplete && !attention)
            } else {
                try await fixture.transport.responses.reply(path, snapshot(fixture, state: "interrupted"))
                try await SessionLifecycleTests.wait("interrupted child turn") {
                    attention = attention || library.needsAttention(fixture.childID)
                    return !child.busy && !child.isStopping
                }
                try expect(child.messages.last?.id == assistantID && child.messages.last?.status == .interrupted)
                try await fixture.removeChild()
                try await library.refreshSharedState()
            }
            try await SessionLifecycleTests.wait("automatic stopped-child removal") {
                attention = attention || library.needsAttention(fixture.childID)
                return child.deletedRemotely
            }
            try expect(!attention && child.error == nil && !library.needsAttention(fixture.childID))
            try expect(library.currentSessionID == fixture.parentID && library.childSessions(of: fixture.parentID).isEmpty)
            let writes = await fixture.transport.responses.requests.filter { $0.method != "GET" }
            try expect(writes.count == 1 && writes[0].path == path + "/cancel")
        }
    }

    func childStopKeepsRealFailuresStorageAndApprovalActionable() async throws {
        for failure in ["cancel", "present", "catalog", "superseded"] {
            let fixture = try LifecycleFixture(running: true)
            try await fixture.start()
            defer { fixture.close() }
            let library = fixture.library, path = AgentAPI.path(fixture.childID)
            try await fixture.transport.responses.reply(path + "/cancel", .object(["accepted": .bool(true)]))
            library.openSession(fixture.childID)
            await library.waitForNavigation()
            let child = library.current
            if failure == "cancel" { await fixture.transport.responses.fail(path + "/cancel", status: 409) }
            library.stop()
            try await SessionLifecycleTests.wait("single stop request") {
                await fixture.transport.responses.requests.contains { $0.path == path + "/cancel" }
            }
            if failure != "cancel" {
                if failure == "catalog" { await fixture.transport.responses.fail("/v1/conversations") }
                if failure == "superseded" { await fixture.transport.holdCatalogReads(true) }
                await fixture.transport.responses.fail(path + "/sync", status: 404)
                if failure == "superseded" {
                    try await SessionLifecycleTests.wait("held stop confirmation") { await fixture.transport.pendingCatalogs > 0 }
                    await fixture.transport.holdCatalogReads(false)
                    try await library.refreshSharedState() // Newer catalog still contains the child.
                    try await fixture.transport.finishCatalog(.array([fixture.root, fixture.other]))
                }
            }
            try await SessionLifecycleTests.wait("actionable stop failure") { child.error != nil }
            try expect(library.needsAttention(fixture.childID) && child.busy && !child.deletedRemotely)
            let cancellations = await fixture.transport.responses.requests.filter { $0.path == path + "/cancel" }
            try expect(cancellations.count == 1)
            if failure == "cancel" {
                guard case .object(var fields) = fixture.child else { throw CheckFailure(description: "Invalid child fixture") }
                fields["operation"] = .object(["id": fixture.child["operation"]["id"], "state": .string("cancelling")])
                fields["storageError"] = .string("Synthetic persistence failure")
                fields["approval"] = .object([
                    "id": .string(UUID().uuidString), "operationID": fixture.child["operation"]["id"],
                    "call": .object(["id": .string("write"), "name": .string("shell"),
                        "arguments": .object(["command": .string("true")])]),
                    "description": .string("Synthetic approval"), "workspace": .string("/tmp")])
                try child.apply(AgentJSON.object(fields).decoded(AgentSnapshot.self))
                child.error = nil // Dismissing the message must not hide unsaved state or approval.
                try expect(child.isStopping && child.hasUnsavedChanges && library.needsAttention(fixture.childID))
                try expect(library.needsApproval(fixture.childID))
                fields["storageError"] = .null; fields["approval"] = .null
                fields["operation"] = .object(["id": fixture.child["operation"]["id"], "state": .string("failed"),
                    "error": .string("Synthetic cancellation cleanup failure")])
                try child.apply(AgentJSON.object(fields).decoded(AgentSnapshot.self))
                try expect(child.error == "Synthetic cancellation cleanup failure" && library.needsAttention(fixture.childID))
            }
        }
    }
}
