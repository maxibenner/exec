import Foundation

@MainActor struct ScreenshotTests {
    private let call = ToolCall(id: "capture-1", name: "take_screenshot", arguments: #"{"target":"desktop","window_id":0}"#)

    func permissions() async throws {
        let request = try ScreenshotTool.request(call)
        let executor = ToolExecutor()
        let directory = URL(fileURLWithPath: "/test-workspace")
        executor.setAutoApproval(for: directory)
        let automatic = try await executor.approveScreenshot(request)
        try expect(automatic && executor.pendingApproval == nil && !executor.screenshotsAllowedForSession)
        executor.setAutoApproval(for: nil)
        for always in [false, true] {
            let task = Task { try await executor.approveScreenshot(request) }
            try await wait { executor.pendingApproval != nil }
            let approval = executor.pendingApproval!
            executor.resolveApproval(id: UUID(), approved: true, allowScreenshotsForSession: true)
            try expect(!executor.screenshotsAllowedForSession && executor.pendingApproval != nil)
            executor.resolveApproval(id: approval.id, approved: true, allowScreenshotsForSession: always)
            let approved = try await task.value
            try expect(approved && executor.screenshotsAllowedForSession == always)
        }
        let allowed = try await executor.approveScreenshot(request)
        try expect(allowed && executor.autoApprovedDirectory == nil)
        try expect(!ToolExecutor().screenshotsAllowedForSession)
        executor.resetScreenshotPermission()
        let denied = Task { try await executor.approveScreenshot(request) }
        try await wait { executor.pendingApproval != nil }
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: false, allowScreenshotsForSession: true)
        let deniedValue = try await denied.value
        try expect(!deniedValue && !executor.screenshotsAllowedForSession)
        let cancelled = Task { try await executor.approveScreenshot(request) }
        try await wait { executor.pendingApproval != nil }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Expected cancellation") }
        catch is CancellationError {}
        try expect(executor.pendingApproval == nil)
        let toggled = Task { try await executor.approveScreenshot(request) }
        try await wait { executor.pendingApproval != nil }
        executor.setAutoApproval(for: directory)
        let toggledValue = try await toggled.value
        try expect(toggledValue && !executor.screenshotsAllowedForSession)
    }

    func capturesPersistAndEncode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        provider.scripted = [[.toolCall(call), .completed], [.text("Inspected screenshot"), .completed]]
        let image = ImageAttachment(name: "Screenshot.png", mediaType: "image/png", data: Data([1, 2, 3]))
        var captures = 0
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true, captureScreenshot: { request in
            captures += 1
            try expect(request.target == .desktop)
            return .init(text: "Captured main display", image: image)
        })
        store.selectedModel = "test"
        store.draft = "Inspect the desktop"
        store.send()
        try await wait { store.tools.pendingApproval != nil }
        try expect(captures == 0)
        store.tools.resolveApproval(id: store.tools.pendingApproval!.id, approved: true, allowScreenshotsForSession: true)
        await store.waitUntilIdle()
        try expect(captures == 1 && store.error == nil && provider.inputs.count == 2)
        let saved = try await sessions.load(id: store.currentSessionID)!
        let result = saved.history.compactMap(\.toolResult).first!
        try expect(result.screenshot == image)
        let restoredResult = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result))
        try expect(restoredResult == result)
        let input = try CodexConversationState().input(saved.history)
        let content = input.compactMap { $0["content"] as? [[String: String]] }.flatMap { $0 }
        try expect(content.contains { $0["type"] == "input_image" && $0["image_url"] == "data:image/png;base64,AQID" })
        try expect(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == call.id })
        let presentation = ToolPresentation(result)
        try expect(presentation.title == "Screenshot" && presentation.summary == "Main display")
        let restored = ChatStore(provider: FakeProvider(), sessions: sessions, newConversation: true, captureScreenshot: { _ in
            throw CheckFailure(description: "Must not replay a capture")
        })
        restored.openSession(store.currentSessionID!, loadModels: false)
        await restored.waitUntilIdle()
        try expect(restored.error == nil && !restored.tools.screenshotsAllowedForSession)
        try expect(restored.messages.compactMap(\.toolResult).first?.screenshot == image)
    }

    func failuresContinueButDenialAndCancellationStop() async throws {
        for mode in ["deny", "fail", "cancel"] {
            let provider = FakeProvider()
            provider.scripted = [[.toolCall(call), .completed]]
            var captures = 0
            let store = ChatStore(provider: provider, newConversation: true, captureScreenshot: { _ in
                captures += 1
                if mode == "cancel" { try await Task.sleep(for: .seconds(20)) }
                throw ExecError("Capture unavailable")
            })
            store.selectedModel = "test"
            store.draft = "Inspect"
            store.send()
            try await wait { store.tools.pendingApproval != nil }
            store.tools.resolveApproval(id: store.tools.pendingApproval!.id, approved: mode != "deny")
            if mode == "cancel" {
                try await wait { captures == 1 }
                store.stop()
            }
            await store.waitUntilIdle()
            try expect(captures == (mode == "deny" ? 0 : 1))
            try expect(provider.inputs.count == (mode == "fail" ? 2 : 1))
            let result = store.messages.compactMap(\.toolResult).last!
            if mode == "fail" {
                try expect(result.text.hasPrefix("Tool error: Capture unavailable"))
                try expect(provider.inputs.last?.compactMap(\.toolResult).last == result)
                try expect(store.messages.last?.role == .assistant)
            } else {
                let detail = "Screenshot denied. Do not retry without a new user request."
                let expected = ScreenshotTool.interrupted + (mode == "cancel" ? "" : "\nTool error: \(detail)\nThe turn was stopped. Do not retry without a new user request.")
                try expect(store.messages.last?.text == expected)
            }
            try expect((store.error != nil) == (mode == "deny"))
            try expect(store.messages.compactMap(\.toolResult).allSatisfy { $0.screenshot == nil })
        }
        for arguments in [#"{"target":"window","window_id":0}"#, #"{"target":"desktop","window_id":9}"#,
                          #"{"target":"window","window_id":-1}"#, #"{"target":"other","window_id":0}"#] {
            try expectFailure { _ = try ScreenshotTool.request(ToolCall(id: "bad", name: call.name, arguments: arguments)) }
        }
        let window = try ScreenshotTool.request(ToolCall(id: "window", name: call.name, arguments: #"{"target":"window","window_id":42}"#))
        try expect(window.summary == "Window 42")
    }

    func fitsCaptureAndKeepsPresentationMinimal() throws {
        for pixelScale: CGFloat in [1, 2] {
            let config = try ScreenshotCapture.configuration(contentSize: CGSize(width: 1000, height: 750), pointPixelScale: pixelScale)
            try expect(config.width == Int(1000 * pixelScale) && config.height == Int(750 * pixelScale))
            try expect(config.scalesToFit && config.ignoreShadowsSingleWindow)
        }
        let large = try ScreenshotCapture.configuration(contentSize: CGSize(width: 3000, height: 1500), pointPixelScale: 2)
        try expect(large.width == 2048 && large.height == 1024)
        try expectFailure { _ = try ScreenshotCapture.configuration(contentSize: .zero, pointPixelScale: 2) }
        for text in ["Captured main display", ScreenshotTool.interrupted, "Tool error: unavailable"] {
            let result = ToolResult(call: call, text: text)
            let presentation = ToolPresentation(result)
            try expect(presentation.summary == "Main display" && presentation.detail == nil)
            try expect(presentation.inputs.isEmpty && presentation.outputTitle == nil)
            try expect(presentation.output == text) // Failures remain readable when no image exists.
        }
        let list = ToolCall(id: "list", name: call.name, arguments: #"{"target":"list_windows","window_id":0}"#)
        let listing = ToolPresentation(ToolResult(call: list, text: "Window 42: Exec"))
        try expect(listing.summary == "Visible windows" && listing.inputs.isEmpty && listing.outputTitle == nil)
        try expect(listing.output == "Window 42: Exec")
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Screenshot test did not settle")
    }
}
