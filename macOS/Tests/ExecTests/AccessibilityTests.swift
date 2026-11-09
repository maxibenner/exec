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
    var running = true
    var filters: [AccessibilityTool.Filter] = []
    func isRunning(_ pid: Int32) -> Bool { running }
    var afterAction: (() -> Void)?
    func resolve(_ name: String) throws -> AccessibilityController.App {
        .init(url: URL(fileURLWithPath: "/Test.app"), bundleID: "test.app", name: name)
    }
    func applicationName(_ pid: Int32) throws -> String { "Test App" }
    func checkPermission() throws { if !permitted { throw ExecError("Accessibility denied") } }
    func open(_ app: AccessibilityController.App) async throws -> Int32 { events.append("open"); return 42 }
    func activate(_ pid: Int32) throws { events.append("activate"); frontProcessID = pid }
    func inspect(_ pid: Int32, filter: AccessibilityTool.Filter) async throws -> String {
        events.append("inspect")
        filters.append(filter)
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
    private func action(_ id: String, pid: Int32 = 42, kind: String = "set_value", value: String = "hi") throws -> ToolCall {
        try call("ui_action", ["process_id": pid, "snapshot_id": id, "element_id": "e1", "action": kind, "value": value])
    }

    func shortcutsObserveAndHandleExit() async throws {
        let input = FakeAccessibilityInput()
        let controller = AccessibilityController(input: input, access: .init())
        let inspect = try controller.prepare(call("inspect_ui", ["process_id": 42]))
        let initial = try await controller.execute(inspect)
        let save = try controller.prepare(action(snapshotID(initial), kind: "press_key", value: "command+s"))
        try expect(save.summary.contains("command+s") && !save.summary.contains("Replace"))
        input.frontProcessID = input.ownProcessID
        let saved = try await controller.execute(save)
        try expect(input.events == ["inspect", "activate", "press_key", "inspect"])
        try expect(saved.contains("Keyboard input sent") && saved.contains("UI snapshot_id:"))
        try await fails { _ = try await controller.execute(save) }
        let quit = try controller.prepare(action(snapshotID(saved), kind: "press_key", value: "command+q"))
        input.afterAction = { input.running = false }
        let exited = try await controller.execute(quit)
        try expect(exited.contains("has exited") && !exited.contains("UI snapshot_id:") && !exited.contains("failed"))
        try expect(input.events == ["inspect", "activate", "press_key", "inspect", "press_key"])
        try await fails { _ = try await controller.execute(quit) }
    }

    func filteredSelectionAndValidation() async throws {
        let input = FakeAccessibilityInput()
        let controller = AccessibilityController(input: input, access: .init())
        let inspect = try controller.prepare(call("inspect_ui", ["process_id": 42, "query": "hi.txt", "role": ""]))
        let initial = try await controller.execute(inspect)
        let select = try controller.prepare(action(snapshotID(initial), kind: "select", value: ""))
        let selected = try await controller.execute(select)
        try expect(input.events == ["inspect", "select", "inspect"])
        try expect(input.filters == [.init(query: "hi.txt"), .init(query: "hi.txt")])
        try expect(try snapshotID(initial) != snapshotID(selected))
        try await fails { _ = try await controller.execute(select) }
        for (kind, value) in [("press_key", "command+bogus"), ("press_key", ""), ("press_key", "command+command+s"), ("select", "hi")] {
            try expectFailure { _ = try controller.prepare(action(snapshotID(selected), kind: kind, value: value)) }
        }
        for args: [String: Any] in [
            ["process_id": 42, "query": String(repeating: "a", count: 201), "role": ""],
            ["process_id": 42, "query": "hi\n", "role": ""],
            ["process_id": 42, "query": "", "role": "Button"]
        ] { try expectFailure { _ = try controller.prepare(call("inspect_ui", args)) } }
        let filter = AccessibilityTool.Filter(query: "HI.txt", role: "AXStaticText")
        try expect(filter.matches(role: "AXStaticText", text: ["hi.txt"]))
        try expect(!filter.matches(role: "AXRow", text: ["hi.txt"]))
        try expect(!filter.matches(role: "AXStaticText", text: ["other.txt"]))
    }

    func shortcutFailureNeverReplays() async throws {
        let input = FakeAccessibilityInput()
        let controller = AccessibilityController(input: input, access: .init())
        let inspect = try controller.prepare(call("inspect_ui", ["process_id": 42]))
        for mode in ["read", "action", "interrupted"] {
            input.failRead = false; input.failAction = false; input.afterAction = nil
            let initial = try await controller.execute(inspect)
            let key = try controller.prepare(action(snapshotID(initial), kind: "press_key", value: "command+s"))
            var stop = false
            if mode == "read" { input.failRead = true }
            if mode == "action" { input.failAction = true }
            if mode == "interrupted" { input.afterAction = { stop = true } }
            input.events = []
            if mode == "read" {
                let result = try await controller.execute(key)
                try expect(result.contains("Keyboard input sent") && result.contains("Follow-up observation failed"))
            } else {
                try await fails { _ = try await controller.execute(key, shouldStop: { stop }) }
            }
            try await fails { _ = try await controller.execute(key) }
            try expect(input.events.filter { $0 == "press_key" }.count == 1)
        }
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
        for kind in ["set_value", "press_key", "select"] {
            for mode in ["expired", "other-action", "focus", "reset", "permission", "busy", "wrong-app"] {
                input.permitted = true; input.frontProcessID = 42
                let text = try await controller.execute(inspect)
                let request = try controller.prepare(action(snapshotID(text), pid: mode == "wrong-app" ? 43 : 42, kind: kind, value: kind == "select" ? "" : kind == "press_key" ? "command+s" : "hi"))
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
