import Foundation

@MainActor private final class FakeAccessibilityInput: AccessibilityInput {
    var ownProcessID: Int32 = 99
    var frontProcessID: Int32 = 42
    var events: [String] = []
    var permitted = true
    var failRead = false
    var failAction = false
    var delayRead = false
    var value = ""
    var afterAction: (() -> Void)?
    func resolve(_ name: String) throws -> AccessibilityController.App {
        .init(url: URL(fileURLWithPath: "/Test.app"), bundleID: "test.app", name: name)
    }
    func applicationName(_ pid: Int32) throws -> String { "Test App" }
    func checkPermission() throws { if !permitted { throw ExecError("Accessibility denied") } }
    func open(_ app: AccessibilityController.App) async throws -> Int32 { events.append("open"); return 42 }
    func activate(_ pid: Int32) throws { events.append("activate"); frontProcessID = pid }
    func inspect(_ pid: Int32) async throws -> String {
        events.append("inspect")
        if delayRead { try await Task.sleep(for: .seconds(20)) }
        if failRead { throw ExecError("No readable window") }
        return "e1 Text field, actions: focus, set_value; value: \(value)"
    }
    func act(_ request: AccessibilityTool.ActionRequest) throws {
        events.append(request.action.rawValue)
        if failAction { throw ExecError("Action failed and may have had effects") }
        if request.action == .setValue { value = request.value }
        afterAction?()
    }
    func clear() {}
}

@MainActor struct AccessibilityTests {
    private func call(_ name: String, _ arguments: [String: Any]) throws -> ToolCall {
        ToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
    }
    private func snapshotID(_ text: String) throws -> String {
        guard let start = text.range(of: "UI snapshot_id: ")?.upperBound,
              let end = text[start...].firstIndex(of: ";") else { throw CheckFailure(description: "No UI snapshot returned") }
        let id = String(text[start..<end])
        try expect(UUID(uuidString: id) != nil)
        return id
    }
    private func action(_ id: String, pid: Int32 = 42) throws -> ToolCall {
        try call("ui_action", ["process_id": pid, "snapshot_id": id, "element_id": "e1", "action": "set_value", "value": "hi"])
    }
    private func fails(_ body: () async throws -> Void) async throws {
        do { try await body() }
        catch is CheckFailure { throw CheckFailure(description: "Unexpected test assertion") }
        catch { return }
        throw CheckFailure(description: "Expected accessibility operation to fail")
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Accessibility test did not settle")
    }

    func validationAndRoundTrip() async throws {
        for name in ["", "/Applications/Test.app", "https://test", "Test\nApp"] {
            try expectFailure { _ = try AccessibilityTool.request(call("open_app", ["app": name])) }
        }
        try expectFailure { _ = try AccessibilityTool.request(call("inspect_ui", ["process_id": 0])) }
        try expectFailure { _ = try AccessibilityTool.request(action("old-token")) }
        let input = FakeAccessibilityInput()
        let controller = AccessibilityController(input: input, access: .init())
        let open = try controller.prepare(call("open_app", ["app": "Test"]))
        try expect(input.events.isEmpty && open.summary.contains("test.app"))
        let opened = try await controller.execute(open)
        try expect(input.events == ["open", "inspect"] && opened.contains("process_id: 42"))
        let request = try controller.prepare(action(snapshotID(opened)))
        input.frontProcessID = 99 // Approval brought Exec forward.
        let updated = try await controller.execute(request)
        try expect(input.events == ["open", "inspect", "activate", "set_value", "inspect"])
        try expect(updated.contains("value: hi") && updated.contains("not verify"))
        try expect(try snapshotID(updated) != snapshotID(opened))
        try await fails { _ = try await controller.execute(request) }
        try expect(input.events.filter { $0 == "set_value" }.count == 1)
        try expectFailure { _ = try controller.prepare(call("inspect_ui", ["process_id": 99])) }
    }

    func staleReferencesAndSharedAccess() async throws {
        let input = FakeAccessibilityInput()
        let access = ComputerController.Access()
        var now = ContinuousClock.now
        let controller = AccessibilityController(input: input, access: access, now: { now })
        let inspect = try controller.prepare(call("inspect_ui", ["process_id": 42]))
        for mode in ["expired", "other-action", "focus", "reset", "permission", "busy", "wrong-app"] {
            input.permitted = true; input.frontProcessID = 42
            let text = try await controller.execute(inspect)
            let request = try controller.prepare(action(snapshotID(text), pid: mode == "wrong-app" ? 43 : 42))
            input.events = []
            switch mode {
            case "expired": now = now.advanced(by: .seconds(121))
            case "other-action":
                // Real shared coordinator: a pixel-tool action invalidates semantic references.
                let pixel = ComputerController(input: FakeComputerInput(), access: access)
                let call = try ComputerUseTests().call(action: "activate_app", capture: "", x: 0, y: 0, button: "")
                _ = try await pixel.execute(ComputerUseTool.request(call))
            case "focus": input.frontProcessID = 43
            case "reset": controller.reset()
            case "permission": input.permitted = false
            case "busy": access.busy = true
            default: break
            }
            try await fails { _ = try await controller.execute(request) }
            try expect(input.events.isEmpty)
            access.busy = false
        }
    }

    func failedReadAndCancellationNeverReplay() async throws {
        let input = FakeAccessibilityInput()
        let access = ComputerController.Access()
        let controller = AccessibilityController(input: input, access: access)
        let inspect = try controller.prepare(call("inspect_ui", ["process_id": 42]))
        let text = try await controller.execute(inspect)
        let request = try controller.prepare(action(snapshotID(text)))
        input.failRead = true
        let result = try await controller.execute(request)
        try expect(result.contains("action accepted") && result.contains("Follow-up observation failed"))
        try await fails { _ = try await controller.execute(request) }
        try expect(input.events == ["inspect", "set_value", "inspect"])
        input.failRead = false
        let next = try await controller.execute(inspect)
        let failing = try controller.prepare(action(snapshotID(next)))
        input.failAction = true
        try await fails { _ = try await controller.execute(failing) }
        try await fails { _ = try await controller.execute(failing) }
        try expect(input.events.filter { $0 == "set_value" }.count == 2)
        input.failAction = false
        var newInput = false
        let beforeInput = try await controller.execute(inspect)
        let partial = try controller.prepare(action(snapshotID(beforeInput)))
        input.afterAction = { newInput = true }
        do { _ = try await controller.execute(partial, shouldStop: { newInput }); throw CheckFailure(description: "Expected partial interruption") }
        catch is ToolExecutor.InputArrived { throw CheckFailure(description: "An accepted action must not be marked not executed") }
        catch let error as ExecError { try expect(error.localizedDescription.contains("may already have occurred")) }
        input.afterAction = nil
        input.delayRead = true
        input.events = []
        let task = Task { try await controller.execute(inspect) }
        try await wait { input.events == ["inspect"] }
        controller.reset()
        task.cancel()
        do { _ = try await task.value; throw CheckFailure(description: "Expected cancellation") }
        catch is CancellationError {}
        try expect(!access.busy)
    }

    func approvalsAndRecovery() async throws {
        let open = try call("open_app", ["app": "Test"])
        let inspect = try call("inspect_ui", ["process_id": 42])
        for mode in ["allow", "deny", "cancel"] {
            let input = FakeAccessibilityInput()
            let provider = FakeProvider()
            // A second read uses session permission but does not implicitly permit screenshots.
            provider.scripted = [[.toolCall(open), .completed], [.toolCall(inspect), .completed], [.text("Done"), .completed]]
            let store = ChatStore(provider: provider, newConversation: true,
                                  computer: ComputerController(input: FakeComputerInput(), access: .init()), accessibilityInput: input)
            store.models = [ChatModel(id: "test", name: "Text only", contextWindow: 8000, efforts: [], acceptsImages: false)]
            store.selectedModel = "test"; store.draft = "Open Test"; store.send()
            try await wait { store.tools.pendingApproval != nil }
            try expect(input.events.isEmpty && store.tools.pendingApproval?.kind == .computer)
            try expect(store.tools.pendingApproval!.content.contains("Accessibility text"))
            store.tools.resolveApproval(id: store.tools.pendingApproval!.id, approved: mode != "deny", allowComputerForSession: true)
            if mode == "cancel" {
                try await wait { input.events.contains("open") }
                store.stop()
            }
            await store.waitUntilIdle()
            let result = store.messages.compactMap(\.toolResult).first!
            if mode == "allow" {
                try expect(input.events == ["open", "inspect", "inspect"] && provider.inputs.count == 3)
                try expect(result.text.contains("UI snapshot_id:") && !store.tools.screenshotsAllowedForSession)
            } else if mode == "deny" {
                try expect(input.events.isEmpty && provider.inputs.count == 1 && result.text.contains("denied"))
            } else {
                try expect(input.events == ["open"] && result.text == AccessibilityTool.interrupted)
            }
            store.stop()
            try expect(!store.tools.computerAllowedForSession)
        }
        let message = Message(role: .assistant, text: "", toolCalls: [open])
        var saved = SessionSnapshot(selectedModel: "test", messages: [message], history: [message], activeTurn: true, activeCallID: open.id)
        try expect(saved.recoverInterruptedTurn())
        try expect(saved.history.last?.toolResult?.text == AccessibilityTool.interrupted)
        try expect(!saved.recoverInterruptedTurn())
    }
}
