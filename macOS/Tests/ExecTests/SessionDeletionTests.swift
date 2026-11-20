import AppKit

/// Captures the real native alert without presenting windows or touching live stores.
@MainActor private final class DeletionPrompt {
    private(set) var alerts: [NSAlert] = []
    private var decisions: [CheckedContinuation<NSApplication.ModalResponse, Never>] = []

    func present(_ alert: NSAlert, _ window: NSWindow?) async -> NSApplication.ModalResponse {
        alerts.append(alert)
        return await withCheckedContinuation { decisions.append($0) }
    }
    func waitUntilPresented() async throws {
        try await SessionLifecycleTests.wait("deletion prompt") { !self.decisions.isEmpty }
    }
    func finish(_ response: NSApplication.ModalResponse, in windows: SessionWindows) async throws {
        guard !decisions.isEmpty else { throw CheckFailure(description: "No deletion decision pending") }
        decisions.removeFirst().resume(returning: response)
        try await SessionLifecycleTests.wait("deletion decision") { !windows.isConfirmingDeletion }
        await windows.library.waitForNavigation()
    }
    func cancelAll() {
        for decision in decisions { decision.resume(returning: .alertSecondButtonReturn) }
        decisions = []
    }
}

@MainActor struct SessionDeletionTests {
    func draftWarningUsesCharacterCountAboveFifteen() async throws {
        for character in ["a", "👩🏽‍💻"] {
            for count in [15, 16] {
                let fixture = try LifecycleFixture()
                try await fixture.start()
                defer { fixture.close() }
                let library = fixture.library
                library.current.draft = String(repeating: character, count: count)
                let windows = SessionWindows(library: library)
                let prompt = DeletionPrompt()
                defer { prompt.cancelAll() }
                windows.confirmSessionDeletion = prompt.present
                try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.other]))

                windows.requestSessionDeletion(fixture.parentID)
                if count > 15 {
                    try expect(windows.isConfirmingDeletion && !library.navigating)
                    try await prompt.waitUntilPresented()
                    try expect(prompt.alerts[0].messageText == "Delete session?")
                    try expect(prompt.alerts[0].informativeText == "Its unsent message will be discarded.")
                    let requests = await fixture.transport.responses.requests
                    try expect(!requests.contains { $0.method == "DELETE" })
                    try await prompt.finish(.alertFirstButtonReturn, in: windows)
                } else {
                    try expect(library.navigating && !windows.isConfirmingDeletion)
                    await library.waitForNavigation()
                    try expect(prompt.alerts.isEmpty)
                }
                let deleted = await fixture.transport.responses.requests.filter { $0.method == "DELETE" }.map(\.path)
                try expect(deleted == [AgentAPI.path(fixture.parentID)])
                try expect(library.currentSessionID == fixture.otherID)
            }
        }
    }

    func draftWarningUsesOnlyTargetRegularSession() async throws {
        for targetHasLongDraft in [false, true] {
            let fixture = try LifecycleFixture()
            try await fixture.start()
            defer { fixture.close() }
            let library = fixture.library
            let target = library.current
            target.draft = String(repeating: "t", count: targetHasLongDraft ? 16 : 15)
            library.openSession(fixture.otherID)
            await library.waitForNavigation()
            let current = library.current
            let currentDraft = String(repeating: "c", count: targetHasLongDraft ? 15 : 16)
            current.draft = currentDraft
            let windows = SessionWindows(library: library)
            let prompt = DeletionPrompt()
            defer { prompt.cancelAll() }
            windows.confirmSessionDeletion = prompt.present
            try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.other]))

            windows.requestSessionDeletion(fixture.parentID)
            if targetHasLongDraft {
                windows.requestSessionDeletion(fixture.parentID)
                windows.requestSessionDeletion(fixture.otherID)
                try await prompt.waitUntilPresented()
                try expect(prompt.alerts.count == 1 && !library.navigating)
                try expect(prompt.alerts[0].informativeText == "Its unsent message will be discarded.")
                try await prompt.finish(.alertFirstButtonReturn, in: windows)
            } else {
                try expect(!windows.isConfirmingDeletion && library.navigating)
                await library.waitForNavigation()
                try expect(prompt.alerts.isEmpty)
            }
            let deleted = await fixture.transport.responses.requests.filter { $0.method == "DELETE" }.map(\.path)
            try expect(deleted == [AgentAPI.path(fixture.parentID)])
            try expect(library.current === current && current.draft == currentDraft)
            try expect(!library.sessionList.contains { $0.id == fixture.parentID })
        }
    }

    func subagentDraftsNeverTriggerWarnings() async throws {
        for deleteParent in [false, true] {
            let fixture = try LifecycleFixture()
            try await fixture.start()
            defer { fixture.close() }
            let library = fixture.library
            library.current.draft = String(repeating: "p", count: deleteParent ? 15 : 16)
            library.openSession(fixture.childID)
            await library.waitForNavigation()
            let child = library.current
            child.draft = "A long unsent subagent message"
            if !deleteParent { library.openSession(fixture.parentID) }
            await library.waitForNavigation()
            let windows = SessionWindows(library: library)
            var prompts = 0
            windows.confirmSessionDeletion = { _, _ in prompts += 1; return .alertSecondButtonReturn }
            let remaining = deleteParent ? [fixture.other] : [fixture.root, fixture.other]
            try await fixture.transport.responses.reply("/v1/conversations", .array(remaining))

            let id = deleteParent ? fixture.parentID : fixture.childID
            windows.requestSessionDeletion(id)
            try expect(library.navigating && !windows.isConfirmingDeletion)
            await library.waitForNavigation()
            let deleted = await fixture.transport.responses.requests.filter { $0.method == "DELETE" }.map(\.path)
            try expect(prompts == 0 && deleted == [AgentAPI.path(id)])
            try expect(!library.openConversations.contains { $0 === child })
        }
    }

    func combinedWarningCancellationLeavesSessionFamilyUntouched() async throws {
        let fixture = try LifecycleFixture(running: true)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let parent = library.current
        parent.draft = "Keep this unsent parent input"
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        let child = library.current
        child.draft = "Keep this unsent child input"
        let sessions = library.sessionList
        let residents = library.openConversations.map(ObjectIdentifier.init)
        let messages = [parent.messages.map(\.id), child.messages.map(\.id)]
        let writesBefore = await fixture.transport.responses.requests.filter { $0.method != "GET" }.count
        let windows = SessionWindows(library: library)
        let prompt = DeletionPrompt()
        defer { prompt.cancelAll() }
        windows.confirmSessionDeletion = prompt.present

        windows.requestSessionDeletion(fixture.parentID)
        try await prompt.waitUntilPresented()
        try expect(prompt.alerts.count == 1 && !library.navigating && child.busy)
        try expect(prompt.alerts[0].messageText == "Delete running session?")
        try expect(prompt.alerts[0].informativeText == "This will stop its work.\n\nIts unsent message will be discarded.")
        try await prompt.finish(.alertSecondButtonReturn, in: windows)
        try expect(library.current === child && child.busy && library.sessionList == sessions)
        try expect(library.openConversations.map(ObjectIdentifier.init) == residents)
        try expect([parent.messages.map(\.id), child.messages.map(\.id)] == messages)
        try expect(parent.draft == "Keep this unsent parent input" && child.draft == "Keep this unsent child input")
        let writesAfter = await fixture.transport.responses.requests.filter { $0.method != "GET" }.count
        try expect(writesAfter == writesBefore)
    }

    func automaticCleanupNeverPromptsForLongDrafts() async throws {
        let fixture = try LifecycleFixture()
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let parent = library.current
        parent.draft = "Keep this unsent parent input"
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        let child = library.current
        child.draft = "Keep this unsent child input"
        let windows = SessionWindows(library: library)
        var prompts = 0
        windows.confirmSessionDeletion = { _, _ in prompts += 1; return .alertSecondButtonReturn }

        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.other]))
        try await library.refreshSharedState()
        try expect(parent.deletedRemotely && child.deletedRemotely)
        try expect(parent.draft == "Keep this unsent parent input" && child.draft == "Keep this unsent child input")
        try expect(prompts == 0 && !windows.isConfirmingDeletion)
        let requests = await fixture.transport.responses.requests
        try expect(!requests.contains { $0.method == "DELETE" || $0.method == "POST" })
    }

    func cancellationLeavesRunningWorkUntouched() async throws {
        let fixture = try LifecycleFixture(running: true)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        let child = library.current
        child.draft = "Keep this pending input"
        let summary = child.summary
        let messages = child.messages.map(\.id)
        let windows = SessionWindows(library: library)
        let prompt = DeletionPrompt()
        defer { prompt.cancelAll() }
        windows.confirmSessionDeletion = prompt.present

        windows.requestSessionDeletion(fixture.childID)
        try expect(windows.isConfirmingDeletion && !library.navigating && child.busy)
        try await prompt.waitUntilPresented()
        let alert = prompt.alerts[0]
        try expect(alert.messageText == "Delete running session?" && alert.informativeText == "This will stop its work.")
        try expect(alert.buttons.map(\.title) == ["Delete", "Cancel"])
        try expect(alert.buttons[0].hasDestructiveAction && alert.buttons[0].keyEquivalent.isEmpty)
        try expect(!alert.buttons[1].hasDestructiveAction && alert.buttons[1].keyEquivalent == "\r")
        try await prompt.finish(.alertSecondButtonReturn, in: windows)
        try expect(library.current === child && child.busy && child.summary == summary)
        try expect(child.draft == "Keep this pending input" && child.messages.map(\.id) == messages)
        let requests = await fixture.transport.responses.requests
        try expect(!requests.contains { $0.method == "DELETE" || $0.method == "POST" })
    }

    func confirmationKeepsOriginalIDAndIgnoresDuplicateRequests() async throws {
        let fixture = try LifecycleFixture(running: true)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let windows = SessionWindows(library: library)
        let prompt = DeletionPrompt()
        defer { prompt.cancelAll() }
        windows.confirmSessionDeletion = prompt.present

        windows.requestSessionDeletion(fixture.childID)
        windows.requestSessionDeletion(fixture.childID)
        windows.requestSessionDeletion(fixture.otherID)
        try await prompt.waitUntilPresented()
        library.openSession(fixture.otherID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == fixture.otherID)
        windows.requestSessionDeletion(fixture.parentID)
        try expect(prompt.alerts.count == 1 && !library.navigating)
        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, fixture.other]))
        try await prompt.finish(.alertFirstButtonReturn, in: windows)
        windows.requestSessionDeletion(fixture.childID)
        let deleted = await fixture.transport.responses.requests.filter { $0.method == "DELETE" }.map(\.path)
        try expect(deleted == [AgentAPI.path(fixture.childID)])
        try expect(library.sessionList.contains { $0.id == fixture.otherID })
        try expect(!library.sessionList.contains { $0.id == fixture.childID })
        try expect(prompt.alerts.count == 1)
    }

    func runningFamilyIncludesNestedAndNonresidentWork() async throws {
        let fixture = try LifecycleFixture()
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        guard case .object(var activeParent) = fixture.root else {
            throw CheckFailure(description: "Invalid parent fixture")
        }
        for state in ["running", "awaiting_approval", "cancelling"] {
            activeParent["operation"] = .object(["id": fixture.root["operation"]["id"], "state": .string(state)])
            try library.current.apply(AgentJSON.object(activeParent).decoded(AgentSnapshot.self))
            try expect(SessionDeletionConfirmation(for: fixture.parentID, in: library).isRequired)
            // A running ancestor is not part of an idle child's deletion family.
            try expect(!SessionDeletionConfirmation(for: fixture.childID, in: library).isRequired)
        }
        try library.current.apply(fixture.root.decoded(AgentSnapshot.self))
        guard case .object(var fields) = fixture.child,
              case .object(var metadata) = fields["metadata"],
              case .object(var parent) = metadata["parent"] else {
            throw CheckFailure(description: "Invalid descendant fixture")
        }
        let descendantID = UUID()
        fields["id"] = .string(descendantID.uuidString)
        fields["operation"] = .object(["id": .string(UUID().uuidString), "state": .string("running")])
        parent["sessionId"] = .string(fixture.childID.uuidString)
        metadata["parent"] = .object(parent)
        fields["metadata"] = .object(metadata)
        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, fixture.child, fixture.other, .object(fields)]))
        try await library.refreshSharedState()
        try expect(!library.isSessionRunning(fixture.parentID) && !library.isSessionRunning(fixture.childID))
        try expect(!library.openConversations.contains { $0.currentSessionID == descendantID })
        try expect(!SessionDeletionConfirmation(for: fixture.otherID, in: library).isRequired)
        let windows = SessionWindows(library: library)
        var prompts = 0
        windows.confirmSessionDeletion = { _, _ in prompts += 1; return .alertSecondButtonReturn }
        for id in [fixture.parentID, fixture.childID, descendantID] {
            windows.requestSessionDeletion(id)
            try expect(windows.isConfirmingDeletion)
            try await SessionLifecycleTests.wait("family confirmation") { !windows.isConfirmingDeletion }
        }
        try expect(prompts == 3)
        let deletes = await fixture.transport.responses.requests.filter { $0.method == "DELETE" }
        try expect(deletes.isEmpty)
    }

    func idleDeletionIsImmediateAndSingleShot() async throws {
        let fixture = try LifecycleFixture()
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let windows = SessionWindows(library: library)
        var prompts = 0
        windows.confirmSessionDeletion = { _, _ in prompts += 1; return .alertSecondButtonReturn }
        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, fixture.other]))
        windows.requestSessionDeletion(fixture.childID)
        try expect(library.navigating && !windows.isConfirmingDeletion)
        windows.requestSessionDeletion(fixture.childID)
        await library.waitForNavigation()
        windows.requestSessionDeletion(UUID())
        let deleted = await fixture.transport.responses.requests.filter { $0.method == "DELETE" }.map(\.path)
        try expect(prompts == 0 && deleted == [AgentAPI.path(fixture.childID)])
    }

    func automaticCleanupWhileConfirmingDoesNotDeleteAnotherSession() async throws {
        let fixture = try LifecycleFixture(running: true)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let windows = SessionWindows(library: library)
        let prompt = DeletionPrompt()
        defer { prompt.cancelAll() }
        windows.confirmSessionDeletion = prompt.present
        windows.requestSessionDeletion(fixture.childID)
        try await prompt.waitUntilPresented()
        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, fixture.other]))
        try await library.refreshSharedState()
        try expect(!library.sessionList.contains { $0.id == fixture.childID })
        try await prompt.finish(.alertFirstButtonReturn, in: windows)
        let deleted = await fixture.transport.responses.requests.filter { $0.method == "DELETE" }
        try expect(deleted.isEmpty && library.currentSessionID == fixture.parentID)
        try expect(prompt.alerts.count == 1)
    }

    func detachedWindowCommandUsesTheSameConfirmation() async throws {
        let fixture = try LifecycleFixture(running: true)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        var detached: ChatStore?
        // Exercise detached ownership without creating or showing an app window.
        library.detachSession(fixture.childID) { detached = $0 }
        await library.waitForNavigation()
        guard let detached else { throw CheckFailure(description: "Missing detached session") }
        let windows = SessionWindows(library: library)
        let actions = SessionCommandScope(windows: windows, conversation: detached).actions
        let prompt = DeletionPrompt()
        defer { prompt.cancelAll() }
        windows.confirmSessionDeletion = prompt.present
        try expect(actions.delete != nil)
        actions.delete?()
        try await prompt.waitUntilPresented()
        library.openSession(fixture.otherID)
        await library.waitForNavigation()
        try await prompt.finish(.alertSecondButtonReturn, in: windows)
        try expect(library.detachedSessionIDs.contains(fixture.childID) && detached.busy)
        try expect(library.currentSessionID == fixture.otherID)
        actions.delete?()
        try await prompt.waitUntilPresented()
        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, fixture.other]))
        try await prompt.finish(.alertFirstButtonReturn, in: windows)
        let deleted = await fixture.transport.responses.requests.filter { $0.method == "DELETE" }.map(\.path)
        try expect(deleted == [AgentAPI.path(fixture.childID)] && !library.detachedSessionIDs.contains(fixture.childID))
        try expect(prompt.alerts.count == 2)
    }
}
