import Foundation

/// Completion is a presentation boundary: callers may synchronously flush
/// SwiftUI or start another navigation. They must never see the old gate/task.
@MainActor struct NavigationCompletionTests {
    func successRunsAfterCleanupAndAllowsReentry() async throws {
        let fixture = try await SidebarCreationFixture(topLevelCount: 2)
        defer { fixture.close() }
        let library = fixture.library
        let targetID = try fixture.roots[1].decoded(AgentSnapshot.self).id
        var observations: [Bool] = []
        library.openSession(targetID) {
            observations.append(!library.navigating && library.openingSessionID == nil && library.currentSessionID == targetID)
            // Starting another asynchronous navigation here must not lose its
            // task to the first request's cleanup or disable its incoming editor.
            let source = library.current
            source.draft = "/fork"
            library.forkConversation(source) {
                observations.append(!library.navigating && library.openingSessionID == nil &&
                                    library.current !== source && source.draft.isEmpty)
            }
        }
        try expect(library.navigating && observations.isEmpty)
        await library.waitForNavigation()
        try await fixture.waitForCreation()
        try expect(observations == [true] && library.navigating)
        try await fixture.finishCreation()
        await library.waitForNavigation()
        try expect(observations == [true, true] && !library.navigating)
        // Resident opens keep their synchronous completion contract as well.
        library.openSession(targetID) {
            observations.append(!library.navigating && library.openingSessionID == nil && library.currentSessionID == targetID)
        }
        try expect(observations == [true, true, true])
        let requests = await fixture.transport.creationRequests
        try expect(requests == 1)
    }

    func failuresNeverPublishSuccess() async throws {
        let fixture = try await SidebarCreationFixture(topLevelCount: 2)
        defer { fixture.close() }
        let library = fixture.library, source = library.current
        let targetID = try fixture.roots[1].decoded(AgentSnapshot.self).id
        let loadPath = AgentAPI.path(targetID, "/sync")
        await fixture.transport.responses.fail(loadPath)
        var callbacks = 0
        library.openSession(targetID) { callbacks += 1 }
        await library.waitForNavigation()
        try expect(callbacks == 0 && !library.navigating && library.openingSessionID == nil)
        try expect(library.current === source && library.error != nil)
        library.error = nil
        source.draft = "/fork"
        library.forkConversation(source) { callbacks += 1 }
        try await fixture.waitForCreation()
        await fixture.transport.failCreation()
        await library.waitForNavigation()
        try expect(callbacks == 0 && !library.navigating && library.openingSessionID == nil)
        try expect(library.current === source && source.draft == "/fork" && source.error != nil)
        let requests = await fixture.transport.creationRequests
        let reads = await fixture.transport.responses.requests.filter {
            $0.method == "GET" && String($0.path.split(separator: "?", maxSplits: 1)[0]) == loadPath
        }
        try expect(requests == 1 && reads.count == 1) // No implicit retry.
    }

    func cancellationAndSupersessionNeverPublishSuccess() async throws {
        // stopAll is a shutdown boundary that closes command queues permanently;
        // use a fresh fixture for each cancellation timing, not a closed source.
        for afterDispatch in [false, true] {
            let fixture = try await SidebarCreationFixture()
            defer { fixture.close() }
            let library = fixture.library, source = library.current
            var callbacks = 0
            source.draft = "/fork"
            library.forkConversation(source) { callbacks += 1 }
            if afterDispatch { try await fixture.waitForCreation() }
            library.stopAll()
            // A fake server may finish after cancellation. It must not navigate,
            // consume the source draft, issue focus/reveal, or replay the fork.
            if afterDispatch { try await fixture.finishCreation() }
            await library.waitForNavigation()
            try expect(callbacks == 0 && !library.navigating && library.openingSessionID == nil)
            try expect(library.current === source && source.draft == "/fork")
            let requests = await fixture.transport.creationRequests
            try expect(requests == (afterDispatch ? 1 : 0))
        }
        let fixture = try await SidebarCreationFixture(topLevelCount: 3)
        defer { fixture.close() }
        let library = fixture.library
        let firstID = try fixture.roots[1].decoded(AgentSnapshot.self).id
        let secondID = try fixture.roots[2].decoded(AgentSnapshot.self).id
        var cancelledCallbacks = 0
        var opened: [Bool] = []
        // A newer open invalidates the old request before its task starts.
        library.openSession(firstID) { cancelledCallbacks += 1 }
        library.openSession(secondID) {
            opened.append(!library.navigating && library.openingSessionID == nil && library.currentSessionID == secondID)
        }
        await library.waitForNavigation()
        try expect(cancelledCallbacks == 0 && opened == [true] && !library.navigating)
        library.openSession(firstID) { cancelledCallbacks += 1 }
        library.stopAll()
        await library.waitForNavigation()
        try expect(cancelledCallbacks == 0 && !library.navigating && library.openingSessionID == nil && library.currentSessionID == secondID)
    }
}
