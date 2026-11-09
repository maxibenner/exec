import AppKit
@preconcurrency import ApplicationServices
import Carbon
import ImageIO

/// Injectable input boundary. Tests never post events or request system permissions.
@MainActor protocol ComputerInput {
    var ownProcessID: Int32 { get }
    var frontProcessID: Int32 { get }
    func desktop() -> ComputerController.Desktop
    func applicationName(_ pid: Int32) throws -> String
    func checkPermission() throws
    func activate(_ pid: Int32) throws
    func validateTarget(_ pid: Int32, point: CGPoint?) throws
    func click(at point: CGPoint, button: String) throws
    func scroll(at point: CGPoint, x: Int, y: Int) throws
    func type(_ scalar: Unicode.Scalar) throws
    func press(_ key: ComputerUseTool.Key) throws
}

@MainActor final class ComputerController {
    struct Desktop: Equatable {
        let displayID: UInt32
        let bounds: CGRect
        let frontPID: Int32
        let layout: String
    }
    struct Capture {
        let id: String
        let desktop: Desktop
        let size: CGSize
        let created: ContinuousClock.Instant
        let generation: UInt64

        func point(x: Int, y: Int) throws -> CGPoint {
            guard x >= 0, y >= 0, Double(x) < size.width, Double(y) < size.height,
                  size.width > 0, size.height > 0 else {
                throw ExecError("Coordinates are outside the desktop screenshot.")
            }
            return CGPoint(x: desktop.bounds.minX + CGFloat(x) * desktop.bounds.width / size.width,
                           y: desktop.bounds.minY + CGFloat(y) * desktop.bounds.height / size.height)
        }
    }
    /// All sessions share the real desktop, including observation while another action runs.
    final class Access {
        var busy = false
        var generation: UInt64 = 0
    }
    private static let sharedAccess = Access()
    private let input: any ComputerInput
    private let access: Access
    private let now: () -> ContinuousClock.Instant
    private(set) var capture: Capture?
    private var revision: UInt64 = 0

    init(input: any ComputerInput = NativeComputerInput(), access: Access? = nil,
         now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.input = input
        self.access = access ?? Self.sharedAccess
        self.now = now
    }

    func reset() {
        capture = nil
        revision &+= 1
    }

    func approvalSummary(_ request: ComputerUseTool.Request) throws -> String {
        guard request.process_id != input.ownProcessID else { throw ExecError("Computer control cannot target Exec itself.") }
        let name = try input.applicationName(request.process_id)
        return "Application: \(name) (\(request.process_id))\n\(request.summary)\nThis controls real applications outside the workspace. Input text is saved in this conversation. Stop revokes session control."
    }

    func observe(_ request: ScreenshotTool.Request,
                 captureImage: @MainActor (ScreenshotTool.Request) async throws -> ScreenshotTool.Output) async throws -> ScreenshotTool.Output {
        guard !access.busy else { throw ExecError("Another session is using the desktop. No capture was started.") }
        access.busy = true
        defer { access.busy = false }
        let revision = self.revision
        if request.target == .desktop { capture = nil }
        let before = input.desktop()
        var output = try await captureImage(request)
        try Task.checkCancellation()
        guard revision == self.revision else { throw CancellationError() }
        if request.target == .desktop {
            capture = nil
            if before == input.desktop(), let image = output.image,
               let source = CGImageSourceCreateWithData(image.data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 {
                let value = Capture(id: UUID().uuidString, desktop: before, size: CGSize(width: width, height: height),
                                    created: now(), generation: access.generation)
                capture = value
                output.text += "\nDesktop capture_id: \(value.id). Image: \(width)×\(height) pixels, origin top-left. Foreground process_id: \(before.frontPID). Valid for one input action within 120 seconds; use image pixel coordinates."
            } else {
                output.text += "\nDesktop changed during capture; no computer-use capture_id issued."
            }
        }
        return output
    }

    func execute(_ request: ComputerUseTool.Request, shouldStop: @MainActor () -> Bool = { false }) async throws -> String {
        try Task.checkCancellation()
        guard !shouldStop() else { throw ToolExecutor.InputArrived() }
        guard !access.busy else { throw ExecError("Another session is using the desktop. No input was sent.") }
        _ = try approvalSummary(request)
        try input.checkPermission()
        access.busy = true
        defer { access.busy = false }
        let revision = self.revision
        func check() throws {
            try Task.checkCancellation()
            guard revision == self.revision else { throw CancellationError() }
            guard !shouldStop() else { throw ExecError("New user input arrived. Computer input stopped; some input may already have been sent. Do not retry without a new user request.") }
        }

        if request.action == .activateApp {
            capture = nil
            access.generation &+= 1
            try input.activate(request.process_id)
            try await Task.sleep(for: .milliseconds(150))
            try check()
            guard input.frontProcessID == request.process_id else { throw ExecError("Application did not become foreground. No input was sent.") }
            return "Application activated. Take a fresh desktop screenshot before sending input."
        }

        guard let snapshot = capture, snapshot.id == request.capture_id,
              snapshot.generation == access.generation,
              snapshot.created.duration(to: now()) < .seconds(120),
              snapshot.desktop.frontPID == request.process_id else {
            throw ExecError("Missing, stale, or wrong-application capture_id. No input was sent. Take a fresh desktop screenshot.")
        }
        let point = request.action == .click || request.action == .scroll ? try snapshot.point(x: request.x, y: request.y) : nil
        // Consume before any effects, including activation. Never replay a partial action.
        capture = nil
        access.generation &+= 1
        let front = input.frontProcessID
        guard front == request.process_id || front == input.ownProcessID else {
            throw ExecError("Foreground application changed. No input was sent.")
        }
        if front == input.ownProcessID {
            try input.activate(request.process_id)
            try await Task.sleep(for: .milliseconds(150))
        }
        try check()
        guard input.desktop() == snapshot.desktop else {
            throw ExecError("Application focus, window layout, or display geometry changed. No input was sent. Take a fresh desktop screenshot.")
        }
        try input.validateTarget(request.process_id, point: point)
        switch request.action {
        case .click: try input.click(at: point!, button: request.button)
        case .scroll: try input.scroll(at: point!, x: request.scroll_x, y: request.scroll_y)
        case .pressKey: try input.press(ComputerUseTool.Key(request.text))
        case .typeText:
            for scalar in request.text.unicodeScalars {
                try check()
                try input.validateTarget(request.process_id, point: nil)
                try input.type(scalar)
                await Task.yield()
            }
        case .activateApp: break
        }
        try check()
        return "Input sent; application outcome is not verified. Take a fresh desktop screenshot to observe the result. Do not repeat the action merely because the screen has not updated."
    }
}

@MainActor final class NativeComputerInput: ComputerInput {
    var ownProcessID: Int32 { ProcessInfo.processInfo.processIdentifier }
    var frontProcessID: Int32 { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }

    private func windows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }
    private func frame(_ row: [String: Any]) -> CGRect? {
        guard let bounds = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
    func desktop() -> ComputerController.Desktop {
        let pid = frontProcessID
        let layout = windows().filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { row in
            "\(row[kCGWindowNumber as String] ?? ""):\(frame(row)?.debugDescription ?? "")"
        }.joined(separator: ";")
        // Launch date guards against a PID being recycled after an app exits.
        let launch = NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 ?? 0
        return .init(displayID: CGMainDisplayID(), bounds: CGDisplayBounds(CGMainDisplayID()), frontPID: pid,
                     layout: "\(launch):\(CGDisplayPixelsWide(CGMainDisplayID())): \(CGDisplayPixelsHigh(CGMainDisplayID())):\(layout)")
    }
    func applicationName(_ pid: Int32) throws -> String {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular, let name = app.localizedName else {
            throw ExecError("The target application is not available.")
        }
        return name
    }
    func checkPermission() throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            // Request only after the user has approved computer control. Never retry the action.
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw ExecError("Allow Exec in System Settings → Privacy & Security → Accessibility, then make a new request. No input was sent.")
        }
    }
    func activate(_ pid: Int32) throws {
        _ = try applicationName(pid)
        guard NSRunningApplication(processIdentifier: pid)?.activate() == true else {
            throw ExecError("Could not activate the target application.")
        }
    }
    func validateTarget(_ pid: Int32, point: CGPoint?) throws {
        guard frontProcessID == pid else { throw ExecError("Foreground application changed; further input stopped.") }
        guard !IsSecureEventInputEnabled() else { throw ExecError("Secure input is active. Computer input is not allowed.") }
        if point == nil {
            // Keyboard input must target a window visible on the captured main display.
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                throw ExecError("Cannot verify the focused window. No keyboard input was sent.")
            }
            let window = unsafeDowncast(focused, to: AXUIElement.self)
            var position: CFTypeRef?
            var dimensions: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &dimensions) == .success,
                  let position, let dimensions,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else {
                throw ExecError("Cannot verify focused-window geometry. No keyboard input was sent.")
            }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
                  AXValueGetValue(unsafeDowncast(dimensions, to: AXValue.self), .cgSize, &size),
                  size.width > 0, size.height > 0,
                  CGDisplayBounds(CGMainDisplayID()).contains(CGRect(origin: origin, size: size)) else {
                throw ExecError("The focused window must be fully on the main display. No keyboard input was sent.")
            }
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
            throw ExecError("A modifier key is held; no further input was sent.")
        }
        guard let point else { return }
        guard CGDisplayBounds(CGMainDisplayID()).contains(point),
              let top = windows().first(where: { frame($0)?.contains(point) == true }),
              top[kCGWindowOwnerPID as String] as? Int32 == pid else {
            throw ExecError("The click/scroll location is not visibly owned by the target application. No input was sent.")
        }
    }
    private func pair(_ down: CGEvent?, _ up: CGEvent?) throws {
        guard let down, let up else { throw ExecError("Could not construct computer input events.") }
        // No suspension/cancellation between down and up: never leave a key/button held.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
    func click(at point: CGPoint, button: String) throws {
        let right = button == "right"
        let mouse: CGMouseButton = right ? .right : .left
        for count in 1...(button == "double" ? 2 : 1) {
            let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: mouse)
            let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: mouse)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            down?.flags = []; up?.flags = []
            try pair(down, up)
        }
    }
    func scroll(at point: CGPoint, x: Int, y: Int) throws {
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else {
            throw ExecError("Could not construct scroll events.")
        }
        move.flags = []; scroll.flags = []; scroll.location = point
        move.post(tap: .cghidEventTap)
        scroll.post(tap: .cghidEventTap)
    }
    func type(_ scalar: Unicode.Scalar) throws {
        let text = Array(String(scalar).utf16)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        text.withUnsafeBufferPointer { buffer in
            down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        down?.flags = []; up?.flags = []
        try pair(down, up)
    }
    func press(_ key: ComputerUseTool.Key) throws {
        var flags: CGEventFlags = []
        for (name, flag) in [("command", CGEventFlags.maskCommand), ("shift", .maskShift), ("option", .maskAlternate), ("control", .maskControl)] where key.modifiers.contains(name) {
            flags.insert(flag)
        }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: false)
        down?.flags = flags; up?.flags = []
        try pair(down, up)
    }
}
