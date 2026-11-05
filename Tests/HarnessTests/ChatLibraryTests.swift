import Foundation

@MainActor struct ChatLibraryTests {
    func concurrentTurnsKeepContextDraftsAndSelectionIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        let first = library.current
        let firstProvider = provider.children.last!
        firstProvider.holdOpen = true
        library.draft = "First request"
        library.send()
        try await wait { firstProvider.pending != nil }
        let firstID = library.currentSessionID!
        library.draft = "Unsent next request"

        library.newConversation()
        try await wait { !library.navigating }
        try expect(first.busy && first.draft == "Unsent next request")
        let second = library.current
        let secondProvider = provider.children.last!
        secondProvider.holdOpen = true
        library.draft = "Second request"
        library.send()
        try await wait { secondProvider.pending != nil }
        let secondID = library.currentSessionID!
        try expect(first.busy && second.busy && firstID != secondID)
        library.renameSession(firstID, title: "Renamed while running")
        try await wait { !library.navigating }
        try expect(first.busy && second.busy)
        try expect(library.sessionList.first(where: { $0.id == firstID })?.title == "Renamed while running")
        try expect(firstProvider.inputs[0].map(\.text) == ["First request"])
        try expect(secondProvider.inputs[0].map(\.text) == ["Second request"])
        library.disconnect() // Account-wide changes cannot invalidate either running turn.
        library.deleteSession(firstID)
        try expect(provider.account != nil && first.busy)
        let stillSaved = try await sessions.load(id: firstID)
        try expect(stillSaved != nil)

        let order = library.sessionList.map(\.id)
        library.openSession(firstID)
        try expect(library.sidebarSelectionID == firstID && library.currentSessionID == secondID)
        try await wait { !library.navigating }
        try expect(library.current === first && library.draft == "Unsent next request")
        try expect(library.sessionList.map(\.id) == order)
        library.stop()
        try await wait { !first.busy }
        try expect(second.busy && first.messages.last?.status == .interrupted)
        secondProvider.pending?.yield(.text(" — second completed"))
        secondProvider.pending?.yield(.completed)
        secondProvider.pending?.finish()
        try await wait { !second.busy }
        let selected = try await sessions.preferredID(identity: provider.conversationIdentity)
        try expect(selected == firstID && library.currentSessionID == firstID)
        let renamed = try await sessions.load(id: firstID)
        try expect(renamed?.title == "Renamed while running")
        try expect(firstProvider.inputs.count == 1 && secondProvider.inputs.count == 1)

        library.openSession(secondID)
        try await wait { !library.navigating }
        try expect(library.messages.last?.text == "Hello world — second completed")
        library.draft = "Continue second"
        library.send()
        try await wait { !library.hasRunningOperations }
        try expect(provider.children.last?.inputs.last?.map(\.text) == ["Second request", "Hello world — second completed", "Continue second"])
    }

    func backgroundApprovalsStayWithTheirConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")))
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(root)
        try await wait { !library.navigating }
        let first = library.current
        let firstID = library.currentSessionID!
        provider.children.last!.scripted = [[.toolCall(ToolCall(id: "a", name: "shell", arguments: #"{"command":"printf A >> effect-a"}"#)), .completed]]
        library.draft = "First command"
        library.send()
        try await wait { first.tools.pendingApproval != nil }
        let firstApproval = first.tools.pendingApproval!.id
        library.newConversation()
        try await wait { !library.navigating }
        let second = library.current
        provider.children.last!.scripted = [[.toolCall(ToolCall(id: "b", name: "shell", arguments: #"{"command":"printf B >> effect-b"}"#)), .completed]]
        library.draft = "Second command"
        library.send()
        try await wait { second.tools.pendingApproval != nil }
        library.tools.resolveApproval(id: firstApproval, approved: true)
        try expect(first.tools.pendingApproval != nil && second.tools.pendingApproval != nil)
        library.setAutoApproveTools(true)
        try await wait { !second.busy }
        try expect(try String(contentsOf: root.appendingPathComponent("effect-b"), encoding: .utf8) == "B")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect-a").path))
        library.openSession(firstID)
        try await wait { !library.navigating }
        try expect(!library.autoApproveTools && library.tools.pendingApproval?.id == firstApproval)
        library.stopAll()
        try await wait { !library.hasRunningOperations }
        try expect(first.tools.pendingApproval == nil)
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect-a").path))
        library.newConversation()
        try await wait { !library.navigating }
        try expect(!library.autoApproveTools)
        let lastProvider = provider.children.last!
        library.draft = "Cancel before starting"
        library.send()
        library.stopAll()
        try await wait { !library.hasRunningOperations }
        try expect(lastProvider.inputs.isEmpty && library.draft == "Cancel before starting")
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Conversation operation did not settle")
    }
}
