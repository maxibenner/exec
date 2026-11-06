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
            else { provider.pending?.finish(throwing: ExecError("Failed")) }
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
        try expect(library.autoApproveTools)
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
        try expect(foreground !== first && library.autoApproveTools)
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

    func queuesDuringCompactionAndPausesOnFailure() async throws {
        for outcome in ["success", "failure", "cancel", "save failure"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let provider = FakeProvider()
            let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root))
            library.restore()
            try await wait { !library.hasRunningOperations }
            let conversation = library.current
            let panel = ChatPanel(library: library, conversation: conversation)
            let fake = provider.children[0]
            panel.draft = "First"; panel.send()
            try await wait { !library.hasRunningOperations }
            let transcript = conversation.messages
            var started = false
            var release = false
            var requests = 0
            fake.manualCompactionAction = { _ in
                requests += 1
                started = true
                while !release { try await Task.sleep(for: .milliseconds(5)) }
                if outcome == "failure" { throw ExecError("Compaction failed") }
                if outcome == "save failure" {
                    try FileManager.default.removeItem(at: root)
                    try Data("Not a directory".utf8).write(to: root)
                }
            }
            panel.compact()
            try await wait { started }
            try expect(panel.canEditDraft && conversation.isCompacting && !conversation.isSending)
            let image = ImageAttachment(name: "queued.png", mediaType: "image/png", data: Data([1]))
            guard let importing = conversation.importImages({ [image] }) else {
                throw CheckFailure(description: "Compaction blocked attachments")
            }
            await importing.value
            panel.draft = "Second"; panel.send()
            panel.draft = "Third"; panel.send()
            panel.draft = "Still editing"
            try expect(conversation.queuedMessages.map(\.text) == ["Second", "Third"])
            try expect(conversation.messages == transcript && fake.inputs.count == 1)
            // A window-local composer must keep targeting this runner after navigation.
            library.newConversation()
            try await wait { !library.navigating }
            library.draft = "Other session"
            if outcome == "cancel" { panel.stop() }
            else { release = true }
            try await wait { !library.hasRunningOperations }
            try expect(requests == 1 && !conversation.isCompacting && panel.canEditDraft)
            try expect(panel.draft == "Still editing" && library.draft == "Other session")
            if outcome == "success" {
                try expect(fake.inputs.map { $0.last!.text } == ["First", "Second", "Third"])
                try expect(fake.inputs[1].last?.images == [image])
                try expect(conversation.queuedMessages.isEmpty)
            } else {
                try expect(fake.inputs.count == 1 && conversation.messages == transcript)
                try expect(conversation.isQueuePaused && conversation.queuedMessages.map(\.text) == ["Second", "Third"])
                if outcome != "save failure" {
                    panel.resumeQueuedMessages()
                    try await wait { !library.hasRunningOperations }
                    try expect(fake.inputs.map { $0.last!.text } == ["First", "Second", "Third"])
                } else { try expect(conversation.hasUnsavedChanges) }
            }
            library.stopAll()
        }
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
