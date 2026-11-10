import Foundation

@MainActor private final class SleepActivityRecorder {
    var active: Set<ObjectIdentifier> = []
    var begins = 0
    var ends = 0
    var prevention: SessionSleepPrevention {
        SessionSleepPrevention(begin: {
            let token = NSObject()
            self.active.insert(ObjectIdentifier(token))
            self.begins += 1
            return token
        }, end: { token in
            self.active.remove(ObjectIdentifier(token))
            self.ends += 1
        })
    }
}

@MainActor struct SessionSleepPreventionTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Session did not reach expected state")
    }

    func overlappingRunsReleaseIndependently() async throws {
        let activity = SleepActivityRecorder()
        let firstProvider = FakeProvider()
        let secondProvider = FakeProvider()
        firstProvider.holdOpen = true
        secondProvider.holdOpen = true
        let first = ChatStore(provider: firstProvider, sleepPrevention: activity.prevention)
        let second = ChatStore(provider: secondProvider, sleepPrevention: activity.prevention)
        defer { first.stop(); second.stop() }
        first.selectedModel = "test"
        second.selectedModel = "test"
        try expect(activity.begins == 0)
        first.draft = "First"; first.send()
        second.draft = "Second"; second.send()
        try expect(activity.active.count == 2) // Acquired before either task starts.
        try await wait { firstProvider.pending != nil && secondProvider.pending != nil }
        firstProvider.pending?.yield(.completed)
        firstProvider.pending?.finish()
        await first.waitUntilIdle()
        try expect(activity.active.count == 1 && activity.ends == 1)
        second.stop()
        try expect(activity.active.count == 1) // Cancellation must finish cleanup first.
        await second.waitUntilIdle()
        try expect(activity.active.isEmpty && activity.ends == 2)
    }

    func idleFailureAndCompactionLifecycle() async throws {
        let activity = SleepActivityRecorder()
        let provider = FakeProvider()
        let store = ChatStore(provider: provider, sleepPrevention: activity.prevention)
        store.restore()
        await store.waitUntilIdle()
        try expect(activity.begins == 0)
        store.send() // Empty input is not a run.
        try expect(activity.begins == 0)
        provider.shouldFail = true
        store.draft = "Fail"; store.send()
        await store.waitUntilIdle()
        try expect(store.error != nil && activity.active.isEmpty)
        try expect(activity.begins == 1 && activity.ends == 1)
        provider.shouldFail = false
        store.draft = "Succeed"; store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil && activity.active.isEmpty)
        var compacting = false
        provider.manualCompactionAction = { _ in
            compacting = true
            while true { try await Task.sleep(for: .milliseconds(5)) }
        }
        store.compact()
        defer { store.stop() }
        try await wait { compacting }
        try expect(activity.active.count == 1)
        store.stop()
        await store.waitUntilIdle()
        try expect(activity.active.isEmpty && activity.begins == 3 && activity.ends == 3)
    }

    func approvalWaitKeepsActivityUntilStopped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let activity = SleepActivityRecorder()
        let provider = FakeProvider()
        provider.scripted = [[.toolCall(ToolCall(id: "shell", name: "shell", arguments: #"{"command":"echo test"}"#)), .completed]]
        let store = ChatStore(provider: provider, workspace: try Workspace.load(root),
                              defaultAutoApproveTools: false, sleepPrevention: activity.prevention)
        defer { store.stop() }
        store.selectedModel = "test"
        store.draft = "Ask for approval"; store.send()
        try await wait { store.tools.pendingApproval != nil }
        try expect(activity.active.count == 1 && activity.ends == 0)
        store.stop()
        await store.waitUntilIdle()
        try expect(activity.active.isEmpty && activity.ends == 1)
    }
}
