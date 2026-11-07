import Foundation

@MainActor struct MetadataCacheTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Metadata operation did not settle")
    }

    private func key(_ provider: FakeProvider) -> String {
        provider.displayName + ":" + provider.conversationIdentity!
    }

    func persistenceAndExpiry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountMetadataCache(directory: root)
        let now = Date()
        let model = ChatModel(id: "test", name: "Test", contextWindow: 1000,
                              efforts: [.init(id: "high", name: "High")], defaultEffort: "high")
        let usage = AccountUsage(windows: [.init(durationSeconds: 18000, usedPercent: 25,
                                               resetsAt: now.addingTimeInterval(100))])
        let observed = CachedAccountUsage(usage: usage, fetchedAt: now)
        await cache.saveModels([model], fetchedAt: now, key: "first")
        await cache.saveUsage(observed, key: "first")
        let restored = await AccountMetadataCache(directory: root).load(key: "first")
        try expect(restored.usableModels(at: now) == [model])
        try expect(restored.modelsFetchedAt == now && restored.usage?.current(at: now) == usage)
        try expect(restored.usableModels(at: now.addingTimeInterval(604_801)).isEmpty)
        try expect(restored.usableModels(at: now.addingTimeInterval(-1)).isEmpty)
        try expect(observed.current(at: now.addingTimeInterval(101)) == nil) // Reset is not replenishment.
        let old = CachedAccountUsage(usage: usage, fetchedAt: now.addingTimeInterval(-301))
        try expect(old.current(at: now) == nil)
        let other = await cache.load(key: "other")
        try expect(other.models.isEmpty && other.usage == nil)
        let file = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
        try Data("corrupt".utf8).write(to: file)
        let corrupt = await cache.load(key: "first")
        try expect(corrupt.models.isEmpty && corrupt.usage == nil)
        try JSONEncoder().encode(AccountMetadataCache.Snapshot(version: 99, models: [model])).write(to: file)
        let incompatible = await cache.load(key: "first")
        try expect(incompatible.models.isEmpty)
        await cache.remove(key: "first")
        try expect(!FileManager.default.fileExists(atPath: file.path))
        // Unwritable cache locations are harmless misses, not launch failures.
        try FileManager.default.removeItem(at: root)
        try Data().write(to: root)
        await cache.saveModels([model], fetchedAt: now, key: "first")
        let unavailable = await cache.load(key: "first")
        try expect(unavailable.models.isEmpty)
    }

    func cachedStartupAndLateResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let cache = AccountMetadataCache(directory: root.appendingPathComponent("cache"))
        let provider = FakeProvider()
        let accountKey = key(provider)
        let cached = [ChatModel(id: "older-model", name: "Cached Model")]
        let usage = AccountUsage(windows: [.init(durationSeconds: 18000, usedPercent: 25,
                                               resetsAt: Date().addingTimeInterval(3600))])
        await cache.saveModels(cached, fetchedAt: .now, key: accountKey)
        await cache.saveUsage(.init(usage: usage, fetchedAt: .now), key: accountKey)
        var ids: [UUID] = []
        for text in ["First saved conversation", "Second saved conversation"] {
            let messages = [Message(role: .user, text: text)]
            ids.append(try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity,
                selectedModel: "newer-model", messages: messages, history: messages,
                activeTurn: false, effort: "high"), id: UUID(), select: false))
        }
        try await sessions.select(ids[0])
        var modelRequest: CheckedContinuation<Void, Never>?
        var usageRequest: CheckedContinuation<AccountUsage?, Never>?
        var modelReturned = false
        var usageReturned = false
        provider.modelsAction = {
            await withCheckedContinuation { modelRequest = $0 }
            modelReturned = true
        }
        provider.usageAction = {
            let value = await withCheckedContinuation { usageRequest = $0 }
            usageReturned = true
            return value
        }
        let library = try ChatLibrary(provider: provider, sessions: sessions, metadataCache: cache)
        defer { modelRequest?.resume(); usageRequest?.resume(returning: nil); library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations && modelRequest != nil && usageRequest != nil }
        try expect(library.models == cached && library.accountUsage == usage)
        try expect(library.canNavigate && !library.busy && !library.current.isRestoringSession)
        try expect(library.currentSessionID == ids[0] && library.messages.first?.text == "First saved conversation")
        try expect(library.current.selectedModel == "newer-model" && library.current.selectedEffort == "high")
        library.draft = "An editable draft while offline"
        try expect(library.current.draft == "An editable draft while offline")
        library.openSession(ids[1])
        try await wait { !library.hasRunningOperations }
        try expect(library.currentSessionID == ids[1])
        try expect(library.current.selectedModel == "newer-model" && library.current.selectedEffort == "high")
        // A failed fresh measurement must not substitute cached allowance.
        provider.usageAction = { throw ExecError("Offline") }
        let measurement = await library.current.readAccountUsage?()
        try expect(measurement == nil && library.accountUsage == usage)
        var signout: CheckedContinuation<Void, Never>?
        provider.children.last!.disconnectAction = { await withCheckedContinuation { signout = $0 } }
        defer { signout?.resume() }
        library.disconnect()
        try await wait { signout != nil }
        library.stop() // Credentials were already removed; cancellation must still evict cached data.
        signout?.resume(); signout = nil
        try await wait { !library.hasRunningOperations && library.account == nil }
        try expect(library.sessionList.isEmpty)
        let removed = await cache.load(key: accountKey)
        try expect(removed.models.isEmpty && removed.usage == nil)
        modelRequest?.resume(); modelRequest = nil
        usageRequest?.resume(returning: usage); usageRequest = nil
        try await wait { modelReturned && usageReturned }
        await Task.yield()
        let afterLateResults = await cache.load(key: accountKey)
        try expect(library.models.isEmpty && library.accountUsage == nil)
        try expect(afterLateResults.models.isEmpty && afterLateResults.usage == nil)
    }

    func refreshDuringRunAndOfflineMiss() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountMetadataCache(directory: root.appendingPathComponent("cache"))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let provider = FakeProvider()
        let messages = [Message(role: .user, text: "Saved offline")]
        _ = try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity,
            selectedModel: "test", messages: messages, history: messages, activeTurn: false), id: UUID())
        await cache.saveModels(provider.availableModels, fetchedAt: .now, key: key(provider))
        var pending: CheckedContinuation<Void, Never>?
        provider.modelsAction = { await withCheckedContinuation { pending = $0 } }
        let library = try ChatLibrary(provider: provider, sessions: sessions, metadataCache: cache)
        defer { pending?.resume(); library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations && pending != nil }
        let runner = provider.children[0]
        runner.holdOpen = true
        library.draft = "Continue"
        library.send()
        try await wait { runner.pending != nil }
        provider.availableModels = [.init(id: "replacement", name: "Replacement")]
        pending?.resume(); pending = nil
        try await wait { library.models.first?.id == "replacement" }
        try expect(library.current.selectedModel == "test" && library.current.models.first?.id == "test")
        library.current.stop()
        runner.pending?.finish()
        try await wait { !library.hasRunningOperations }
        try expect(library.current.models.first?.id == "replacement")
        // No cache and no internet still restores the saved transcript and allows editing.
        let offline = FakeProvider()
        offline.modelsAction = { throw ExecError("Offline") }
        offline.usageAction = { throw ExecError("Offline") }
        let emptyCache = AccountMetadataCache(directory: root.appendingPathComponent("missing"))
        let reopened = try ChatLibrary(provider: offline, sessions: sessions, metadataCache: emptyCache)
        defer { reopened.stopAll() }
        reopened.restore()
        try await wait { !reopened.hasRunningOperations && reopened.error != nil }
        try expect(reopened.canNavigate && !reopened.messages.isEmpty)
        reopened.draft = "Still editable"
        try expect(reopened.current.draft == "Still editable")
        offline.modelsAction = nil
        reopened.refreshModels()
        try await wait { !reopened.models.isEmpty }
        // A successful explicit refresh clears its own metadata error, not run errors.
        try expect(reopened.canNavigate && reopened.error == nil)
    }
}
