import AppKit

@MainActor final class FakeComputerInput: ComputerInput {
    var ownProcessID: Int32 = 99
    var frontProcessID: Int32 = 42
    var bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
    var layout = "window-1"
    var permitted = true
    var visible = true
    var activationWorks = true
    var events: [String] = []
    var points: [CGPoint] = []
    var onType: (() -> Void)?
    func desktop() -> ComputerController.Desktop { .init(displayID: 1, bounds: bounds, frontPID: frontProcessID, layout: layout) }
    func applicationName(_ pid: Int32) throws -> String { "Test App" }
    func checkPermission() throws { if !permitted { throw ExecError("Accessibility denied") } }
    func activate(_ pid: Int32) throws { events.append("activate"); if activationWorks { frontProcessID = pid } }
    func validateTarget(_ pid: Int32, point: CGPoint?) throws {
        guard frontProcessID == pid && visible else { throw ExecError("Target changed") }
    }
    func click(at point: CGPoint, button: String) throws { points.append(point); events.append("click") }
    func scroll(at point: CGPoint, x: Int, y: Int) throws { points.append(point); events.append("scroll") }
    func type(_ scalar: Unicode.Scalar) throws { events.append(String(scalar)); onType?() }
    func press(_ key: ComputerUseTool.Key) throws { events.append("key") }
}

@MainActor struct ComputerUseTests {
    func call(action: String = "click", capture: String = "capture", pid: Int32 = 42, x: Int = 10, y: Int = 20,
              text: String = "", button: String = "left", scrollY: Int = 0) throws -> ToolCall {
        let fields: [String: Any] = ["action": action, "process_id": pid, "capture_id": capture, "x": x, "y": y,
                                     "text": text, "button": button, "scroll_x": 0, "scroll_y": scrollY]
        return ToolCall(id: UUID().uuidString, name: "computer_use", arguments: String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self))
    }
    private func image() -> ImageAttachment {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return ImageAttachment(name: "Test.png", mediaType: "image/png", data: bitmap.representation(using: .png, properties: [:])!)
    }
    private func observe(_ controller: ComputerController) async throws -> String {
        let output = try await controller.observe(.init(target: .desktop, window_id: 0)) { _ in
            .init(text: "Captured", image: image())
        }
        try expect(output.text.contains("200×100"))
        return controller.capture!.id
    }
    private func fails(_ action: () async throws -> Void) async throws {
        do { try await action() }
        catch is CheckFailure { throw CheckFailure(description: "Unexpected test assertion") }
        catch { return }
        throw CheckFailure(description: "Expected computer action to fail")
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Computer-use test did not settle")
    }

    func validation() throws {
        _ = try ComputerUseTool.request(call())
        for bad in [try call(x: -1), try call(pid: 0), try call(capture: ""), try call(button: "middle"),
                    try call(action: "scroll", button: "", scrollY: 1001),
                    try call(action: "type_text", x: 0, y: 0, text: "secret\n", button: ""),
                    try call(action: "type_text", x: 0, y: 0, text: String(repeating: "a", count: 1001), button: ""),
                    try call(action: "press_key", x: 0, y: 0, text: "command+invalid", button: "") ] {
            try expectFailure { _ = try ComputerUseTool.request(bad) }
        }
        let key = try ComputerUseTool.Key("command+shift+l")
        try expect(key.code == 37 && key.modifiers == ["command", "shift"])
        try expectFailure { _ = try ComputerUseTool.Key("command+command+l") }
    }

    func permissions() async throws {
        let executor = ToolExecutor()
        executor.setAutoApproval(for: URL(fileURLWithPath: "/"))
        for always in [false, true] {
            let task = Task { try await executor.approveComputer(summary: "click Test App") }
            try await wait { executor.pendingApproval != nil }
            executor.setAutoApproval(for: URL(fileURLWithPath: "/"))
            try expect(executor.pendingApproval?.kind == .computer)
            executor.resolveApproval(id: UUID(), approved: true, allowComputerForSession: true)
            try expect(!executor.computerAllowedForSession)
            executor.resolveApproval(id: executor.pendingApproval!.id, approved: true, allowComputerForSession: always)
            let result = try await task.value
            try expect(result && executor.computerAllowedForSession == always && !executor.screenshotsAllowedForSession)
        }
        let allowed = try await executor.approveComputer(summary: "click")
        try expect(allowed)
        executor.resetScreenshotPermission()
        try expect(!executor.computerAllowedForSession)
        let denied = Task { try await executor.approveComputer(summary: "click") }
        try await wait { executor.pendingApproval != nil }
        executor.revokeComputerPermission()
        let deniedValue = try await denied.value
        try expect(!deniedValue)
        let cancelled = Task { try await executor.approveComputer(summary: "click") }
        try await wait { executor.pendingApproval != nil }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Expected cancellation") }
        catch is CancellationError {}
        try expect(executor.pendingApproval == nil)
    }

    func capturesAndFocus() async throws {
        let input = FakeComputerInput()
        var now = ContinuousClock.now
        let controller = ComputerController(input: input, access: .init(), now: { now })
        var id = try await observe(controller)
        let request = try ComputerUseTool.request(call(capture: id))
        input.frontProcessID = input.ownProcessID // Approval brought Exec forward.
        _ = try await controller.execute(request)
        try expect(input.events == ["activate", "click"] && input.points == [CGPoint(x: 50, y: 100)])
        try await fails { _ = try await controller.execute(request) } // Single-use token.
        input.events = []
        for mode in ["focus", "layout", "display", "permission", "occlusion", "expired", "bounds", "own"] {
            input.frontProcessID = 42; input.layout = "window-1"; input.bounds.size.width = 1000
            input.visible = true; input.permitted = true
            id = try await observe(controller)
            switch mode {
            case "focus": input.frontProcessID = 43
            case "layout": input.layout = "moved-window"
            case "display": input.bounds.size.width = 800
            case "permission": input.permitted = false
            case "occlusion": input.visible = false
            case "expired": now = now.advanced(by: .seconds(121))
            default: break
            }
            let invalid = try ComputerUseTool.request(call(capture: id, pid: mode == "own" ? 99 : 42, x: mode == "bounds" ? 200 : 10))
            try await fails { _ = try await controller.execute(invalid) }
            try expect(input.events.isEmpty)
        }
        controller.reset()
        try expect(controller.capture == nil)
    }

    func concurrencyAndInterruption() async throws {
        let input = FakeComputerInput()
        let access = ComputerController.Access()
        let first = ComputerController(input: input, access: access)
        let second = ComputerController(input: input, access: access)
        let firstID = try await observe(first)
        let secondID = try await observe(second)
        _ = try await second.execute(ComputerUseTool.request(call(capture: secondID)))
        try await fails { _ = try await first.execute(ComputerUseTool.request(call(capture: firstID))) }
        access.busy = true
        try await fails { _ = try await first.observe(.init(target: .desktop, window_id: 0)) { _ in
            throw CheckFailure(description: "Busy capture must not run")
        } }
        try await fails { _ = try await first.execute(ComputerUseTool.request(call(action: "activate_app", capture: "", x: 0, y: 0, button: ""))) }
        access.busy = false

        // Revocation after the first Unicode scalar stops the rest; a scalar isn't split.
        let id = try await observe(first)
        input.events = []
        input.onType = { first.reset() }
        let request = try ComputerUseTool.request(call(action: "type_text", capture: id, x: 0, y: 0, text: "😀abc", button: ""))
        try await fails { _ = try await first.execute(request) }
        try expect(input.events == ["😀"] && !access.busy && first.capture == nil)

        input.onType = nil
        let next = try await observe(first)
        var pending = false
        input.onType = { pending = true }
        let partial = try ComputerUseTool.request(call(action: "type_text", capture: next, x: 0, y: 0, text: "abc", button: ""))
        do { _ = try await first.execute(partial, shouldStop: { pending }); throw CheckFailure(description: "Expected partial interruption") }
        catch is ToolExecutor.InputArrived { throw CheckFailure(description: "Partial input must not be marked not executed") }
        catch let error as ExecError { try expect(error.localizedDescription.contains("some input may already")) }
        try expect(input.events == ["😀", "a"])

        // Failed observation invalidates the previous capture rather than keeping it usable.
        _ = try await observe(first)
        try await fails { _ = try await first.observe(.init(target: .desktop, window_id: 0)) { _ in throw ExecError("capture failed") } }
        try expect(first.capture == nil)
    }

    func orchestrationAndRecovery() async throws {
        let tool = try call(action: "activate_app", capture: "", x: 0, y: 0, button: "")
        for mode in ["allow", "deny", "fail", "cancel"] {
            let provider = FakeProvider()
            provider.scripted = [[.toolCall(tool), .completed], [.text("Done"), .completed]]
            let input = FakeComputerInput()
            input.permitted = mode != "fail"
            let store = ChatStore(provider: provider, newConversation: true,
                                  computer: ComputerController(input: input, access: .init()))
            store.selectedModel = "test"; store.draft = "Activate Test App"; store.send()
            try await wait { store.tools.pendingApproval != nil }
            try expect(input.events.isEmpty)
            store.tools.resolveApproval(id: store.tools.pendingApproval!.id, approved: mode != "deny", allowComputerForSession: true)
            if mode == "cancel" {
                try await wait { !input.events.isEmpty }
                store.stop()
            }
            await store.waitUntilIdle()
            try expect(input.events == (mode == "allow" || mode == "cancel" ? ["activate"] : []))
            let result = store.messages.compactMap(\.toolResult).last!
            if mode == "allow" { try expect(result.text.hasPrefix("Application activated")) }
            if mode == "fail" { try expect(result.text.contains("Accessibility denied") && provider.inputs.count == 2) }
            if mode == "cancel" { try expect(result.text == ComputerUseTool.interrupted && !store.tools.computerAllowedForSession) }
            if mode == "deny" { try expect(result.text.contains("denied") && provider.inputs.count == 1) }
            store.stop()
            try expect(!store.tools.computerAllowedForSession)
        }
        let message = Message(role: .assistant, text: "", toolCalls: [tool])
        var saved = SessionSnapshot(selectedModel: "test", messages: [message], history: [message], activeTurn: true, activeCallID: tool.id)
        try expect(saved.recoverInterruptedTurn())
        try expect(saved.history.last?.toolResult?.text == ComputerUseTool.interrupted)
        try expect(!saved.recoverInterruptedTurn())
    }
}
