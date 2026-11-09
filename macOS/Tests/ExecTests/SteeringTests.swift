import Foundation

@MainActor struct SteeringTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Steering operation did not settle")
    }

    func acceptsImmediatelyAndBatchesAtModelBoundary() async throws {
        let provider = FakeProvider()
        provider.holdOpen = true
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        store.draft = "First"; store.send()
        try await wait { provider.pending != nil }
        let image = ImageAttachment(name: "detail.png", mediaType: "image/png", data: Data([1]))
        store.draft = "Second"; store.draftImages = [image]; store.send()
        store.draft = "Third"; store.send()
        store.draft = "Still editing"
        try expect(store.messages.filter { $0.role == .user }.map(\.text) == ["First", "Second", "Third"])
        try expect(provider.inputs.count == 1 && store.draftImages.isEmpty)
        // Calls produced by the in-flight response must not execute on stale input.
        provider.pending?.yield(.toolCall(ToolCall(id: "stale", name: "list_files", arguments: #"{"path":"."}"#)))
        provider.holdOpen = false
        provider.pending?.yield(.completed); provider.pending?.finish()
        try await wait { !store.busy }
        try expect(provider.inputs.count == 2 && store.pendingInput.isEmpty)
        let input = provider.inputs[1]
        try expect(input.suffix(2).map(\.text) == ["Second", "Third"])
        try expect(input[input.count - 2].images == [image])
        try expect(input[input.count - 3].toolResult?.text == ToolExecutor.supersededByInput)
        try expect(store.draft == "Still editing" && store.error == nil)
    }

    func finishesCurrentToolAndSkipsRest() async throws {
        let provider = FakeProvider()
        let fetch = ToolCall(id: "running", name: "fetch_content", arguments: #"{"url":"https://example.com"}"#)
        let skipped = ToolCall(id: "later", name: "fetch_content", arguments: #"{"url":"https://example.org"}"#)
        provider.scripted = [[.toolCall(fetch), .toolCall(skipped), .completed], [.text("Reconsidered"), .completed]]
        var started = false
        var release = false
        var executions = 0
        let store = ChatStore(provider: provider, fetchContent: { _ in
            await MainActor.run { executions += 1; started = true }
            while await MainActor.run(body: { !release }) { try await Task.sleep(for: .milliseconds(5)) }
            return "Finished current fetch"
        })
        store.selectedModel = "test"
        store.draft = "Inspect"; store.send()
        try await wait { started }
        store.draft = "Change direction"; store.send()
        try expect(provider.inputs.count == 1 && store.busy)
        release = true
        try await wait { !store.busy }
        try expect(executions == 1 && provider.inputs.count == 2)
        let input = provider.inputs[1]
        let results = input.compactMap(\.toolResult)
        try expect(results.count == 2 && results[0].text.contains("Finished current fetch"))
        try expect(results[1].text == ToolExecutor.supersededByInput)
        try expect(input.last?.text == "Change direction" && store.error == nil)
    }

    func withdrawsApprovalWithoutExecuting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let shell = ToolCall(id: "approval", name: "shell", arguments: #"{"command":"touch must-not-exist"}"#)
        provider.scripted = [[.toolCall(shell), .completed], [.text("Changed plan"), .completed]]
        let store = ChatStore(provider: provider, newConversation: true, workspace: try Workspace.load(root))
        store.selectedModel = "test"
        store.setAutoApproveTools(false)
        store.draft = "Do work"; store.send()
        try await wait { store.tools.pendingApproval != nil }
        let staleID = store.tools.pendingApproval!.id
        store.draft = "Don't do that"; store.send()
        try expect(store.tools.pendingApproval == nil)
        store.tools.resolveApproval(id: staleID, approved: true)
        try await wait { !store.busy }
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist").path))
        try expect(provider.inputs.count == 2 && provider.inputs[1].last?.text == "Don't do that")
        try expect(provider.inputs[1].compactMap(\.toolResult).first?.text == ToolExecutor.supersededByInput)
    }

    func interruptionPreservesInputAcrossRestore() async throws {
        for cancel in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let sessions = SessionStore(directory: root)
            let provider = FakeProvider()
            provider.holdOpen = true
            let store = ChatStore(provider: provider, sessions: sessions)
            store.selectedModel = "test"
            store.draft = "First"; store.send()
            try await wait { provider.pending != nil }
            store.draft = "Keep this input"; store.send()
            if cancel { store.stop() }
            else { provider.pending?.finish(throwing: ExecError("Failed")) }
            try await wait { !store.busy }
            try expect(provider.inputs.count == 1 && store.pendingInput.map(\.text) == ["Keep this input"])
            let restoredProvider = FakeProvider()
            let restored = ChatStore(provider: restoredProvider, sessions: sessions)
            restored.restore()
            try await wait { !restored.busy }
            try expect(restoredProvider.inputs.isEmpty && restored.pendingInput.map(\.text) == ["Keep this input"])
            restored.draft = "Continue"; restored.send()
            try await wait { !restored.busy }
            try expect(restoredProvider.inputs.count == 1)
            try expect(restoredProvider.inputs[0].suffix(2).map(\.text) == ["Keep this input", "Continue"])
            try expect(restored.messages.filter { $0.text == "Keep this input" }.count == 1)
            provider.pending?.finish()
        }
    }

    func compactionAndSaveFailureDoNotRestartWork() async throws {
        for outcome in ["success", "failure", "cancel", "save failure"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let provider = FakeProvider()
            let store = ChatStore(provider: provider, sessions: SessionStore(directory: root))
            store.selectedModel = "test"
            store.draft = "First"; store.send()
            try await wait { !store.busy }
            var started = false
            var release = false
            provider.manualCompactionAction = { _ in
                started = true
                while !release { try await Task.sleep(for: .milliseconds(5)) }
                if outcome == "failure" { throw ExecError("Compaction failed") }
                if outcome == "save failure" {
                    try FileManager.default.removeItem(at: root)
                    try Data("Not a directory".utf8).write(to: root)
                }
            }
            store.compact()
            try await wait { started }
            store.draft = "Second"; store.send()
            store.draft = "Third"; store.send()
            try expect(store.messages.suffix(2).map(\.text) == ["Second", "Third"])
            if outcome == "cancel" { store.stop() }
            else { release = true }
            try await wait { !store.busy }
            if outcome == "success" {
                try expect(provider.inputs.count == 2 && provider.inputs[1].suffix(2).map(\.text) == ["Second", "Third"])
            } else {
                try expect(provider.inputs.count == 1 && store.pendingInput.map(\.text) == ["Second", "Third"])
                if outcome == "save failure" { try expect(store.hasUnsavedChanges) }
            }
        }
    }

    func toolFailureAndCheckpointFailurePreserveInput() async throws {
        for outcome in ["failure", "cancel", "save failure"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let provider = FakeProvider()
            let call = ToolCall(id: "running", name: "fetch_content", arguments: #"{"url":"https://example.com"}"#)
            provider.scripted = [[.toolCall(call), .completed]]
            var started = false
            var release = false
            var executions = 0
            let store = ChatStore(provider: provider, sessions: SessionStore(directory: root), fetchContent: { _ in
                await MainActor.run { executions += 1; started = true }
                while await MainActor.run(body: { !release }) { try await Task.sleep(for: .milliseconds(5)) }
                if outcome == "failure" { throw ExecError("Fetch failed") }
                return "Completed once"
            })
            store.selectedModel = "test"
            store.draft = "First"; store.send()
            try await wait { started }
            store.draft = "Preserve this"; store.send()
            if outcome == "cancel" { store.stop() }
            else {
                if outcome == "save failure" {
                    try FileManager.default.removeItem(at: root)
                    try Data("Not a directory".utf8).write(to: root)
                }
                release = true
            }
            try await wait { !store.busy }
            try expect(executions == 1)
            if outcome == "failure" {
                try expect(provider.inputs.count == 2 && store.pendingInput.isEmpty && store.error == nil)
                try expect(provider.inputs.last?.last?.text == "Preserve this")
                try expect(provider.inputs.last?.compactMap(\.toolResult).last?.text.hasPrefix("Tool error: Fetch failed") == true)
            } else {
                try expect(provider.inputs.count == 1)
                try expect(store.pendingInput.map(\.text) == ["Preserve this"])
            }
            try expect(store.messages.filter { $0.text == "Preserve this" }.count == 1)
            if outcome == "save failure" { try expect(store.hasUnsavedChanges) }
        }
    }

    func backgroundInputStaysWithConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")))
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(root)
        try await wait { !library.hasRunningOperations }
        let first = library.current
        let fake = provider.children[0]
        fake.holdOpen = true
        library.draft = "First"; library.send()
        try await wait { !library.navigating && fake.pending != nil }
        library.draft = "Stay here"; library.send()
        library.newConversation()
        try await wait { !library.navigating }
        let foreground = library.current
        library.draft = "Other draft"
        fake.holdOpen = false
        fake.pending?.yield(.completed); fake.pending?.finish()
        try await wait { !first.busy }
        try expect(fake.inputs.count == 2 && fake.inputs[1].last?.text == "Stay here")
        try expect(library.current === foreground && library.draft == "Other draft" && foreground.messages.isEmpty)
    }

    func progressFramesMatchPi() throws {
        try expect(String(WorkingFrames.frame(0)) == "█·······")
        try expect(String(WorkingFrames.frame(3)) == "░▒▓█····")
        try expect(String(WorkingFrames.frame(7)) == "····░▒▓█")
        try expect(String(WorkingFrames.frame(8)) == "······█▓")
        try expect(String(WorkingFrames.frame(13)) == "·█▓▒░···")
        try expect(WorkingFrames.frame(14) == WorkingFrames.frame(0))
    }
}
