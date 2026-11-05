import Foundation

@MainActor struct MessageQueueTests {
    func fifoRemovalAndDraftIsolation() async throws {
        let provider = FakeProvider()
        provider.holdOpen = true
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        store.draft = "First"
        store.send()
        try await wait { provider.pending != nil }
        let image = ImageAttachment(name: "queued.png", mediaType: "image/png", data: Data([1]))
        store.draft = "Second"; store.draftImages = [image]; store.send()
        store.draft = "Remove me"; store.send()
        let removed = store.queuedMessages.last!.id
        store.draft = "Third"; store.send()
        store.removeQueuedMessage(removed)
        store.draft = "Still editing"
        try expect(store.queuedMessages.map(\.text) == ["Second", "Third"])
        try expect(store.messages.filter { $0.role == .user }.map(\.text) == ["First"])
        try expect(provider.inputs.count == 1 && store.draftImages.isEmpty)
        provider.holdOpen = false
        provider.pending?.yield(.completed); provider.pending?.finish()
        try await wait { !store.busy }
        try expect(provider.inputs.map { $0.last!.text } == ["First", "Second", "Third"])
        try expect(provider.inputs[1].last?.images == [image])
        try expect(store.queuedMessages.isEmpty && store.draft == "Still editing")
        try expect(store.messages.filter { $0.role == .user }.map(\.text) == ["First", "Second", "Third"])
    }

    func interruptionsPauseUntilExplicitResume() async throws {
        for cancel in [false, true] {
            let provider = FakeProvider()
            provider.holdOpen = true
            let store = ChatStore(provider: provider)
            store.selectedModel = "test"
            store.draft = "Interrupted"; store.send()
            try await wait { provider.pending != nil }
            store.draft = "Queued"; store.send()
            if cancel { store.stop() }
            else { provider.pending?.finish(throwing: HarnessError("Failed")) }
            try await wait { !store.busy }
            try expect(store.isQueuePaused && store.queuedMessages.map(\.text) == ["Queued"])
            try expect(provider.inputs.count == 1 && store.hasUnsentDraft)
            store.draft = "Keep this draft"
            provider.holdOpen = false
            store.resumeQueuedMessages()
            try await wait { !store.busy }
            try expect(provider.inputs.count == 2)
            try expect(provider.inputs.last?.filter { $0.role == .user }.map(\.text) == ["Queued"])
            try expect(store.draft == "Keep this draft" && store.queuedMessages.isEmpty)
        }
    }

    func backgroundQueueStaysWithConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")))
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(root)
        try await wait { !library.hasRunningOperations }
        try expect(!library.autoApproveTools)
        library.setAutoApproveTools(true)
        let first = library.current
        let firstProvider = provider.children[0]
        firstProvider.holdOpen = true
        library.draft = "First"; library.send()
        try await wait { !library.navigating && firstProvider.pending != nil }
        library.draft = "Background queued"; library.send()
        try expect(first.queuedMessages.count == 1)
        library.newConversation()
        try await wait { !library.navigating }
        let foreground = library.current
        try expect(foreground !== first && !library.autoApproveTools)
        library.draft = "Foreground draft"
        firstProvider.holdOpen = false
        firstProvider.pending?.yield(.completed); firstProvider.pending?.finish()
        try await wait { !first.busy }
        try expect(firstProvider.inputs.map { $0.last!.text } == ["First", "Background queued"])
        try expect(library.current === foreground && library.draft == "Foreground draft")
        try expect(foreground.messages.isEmpty && foreground.queuedMessages.isEmpty)
        library.stopAll()
    }

    func saveFailureDoesNotDrainQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        provider.holdOpen = true
        let store = ChatStore(provider: provider, sessions: SessionStore(directory: root))
        store.selectedModel = "test"
        store.draft = "First"; store.send()
        try await wait { provider.pending != nil }
        store.draft = "Must not send"; store.send()
        try FileManager.default.removeItem(at: root)
        try Data("Not a directory".utf8).write(to: root)
        provider.pending?.yield(.completed); provider.pending?.finish()
        try await wait { !store.busy }
        try expect(store.hasUnsavedChanges && store.isQueuePaused)
        try expect(provider.inputs.count == 1 && store.queuedMessages.count == 1)
    }

    func progressFramesMatchPi() throws {
        try expect(String(WorkingFrames.frame(0)) == "█·······")
        try expect(String(WorkingFrames.frame(3)) == "░▒▓█····")
        try expect(String(WorkingFrames.frame(7)) == "····░▒▓█")
        try expect(String(WorkingFrames.frame(8)) == "······█▓")
        try expect(String(WorkingFrames.frame(13)) == "·█▓▒░···")
        try expect(WorkingFrames.frame(14) == WorkingFrames.frame(0))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Queued operation did not settle")
    }
}
