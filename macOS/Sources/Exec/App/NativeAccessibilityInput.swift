import AppKit
@preconcurrency import ApplicationServices
import Carbon

/// Native AX references stay in memory and never enter model context or persisted history.
@MainActor final class NativeAccessibilityInput: AccessibilityInput {
    private struct Node: Equatable {
        let role: String
        let subrole: String
        let title: String
        let description: String
        let enabled: Bool
        let secure: Bool
        let value: String?
        let actions: [String]
    }
    private struct Element {
        let reference: AXUIElement
        let node: Node
    }
    private var elements: [String: Element] = [:]
    private var window: AXUIElement?
    private var processID: Int32?
    private var launchDate: Date?
    private let native = NativeComputerInput()
    var ownProcessID: Int32 { native.ownProcessID }
    var frontProcessID: Int32 { native.frontProcessID }

    func clear() { elements = [:]; window = nil; processID = nil; launchDate = nil }
    func applicationName(_ pid: Int32) throws -> String { try native.applicationName(pid) }
    func activate(_ pid: Int32) throws { try native.activate(pid) }
    func checkPermission() throws {
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw ExecError("Allow Exec in System Settings → Privacy & Security → Accessibility, then make a new request. No accessibility action was sent.")
        }
    }

    func resolve(_ name: String) throws -> AccessibilityController.App {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return try app(at: url) }
        let wanted = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        let directories = ["/System/Applications", "/System/Applications/Utilities", "/Applications", "/Applications/Utilities",
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var candidates: Set<URL> = []
        for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for url in entries where url.pathExtension == "app" && url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(wanted) == .orderedSame {
                candidates.insert(url.resolvingSymlinksInPath())
            }
        }
        for running in NSWorkspace.shared.runningApplications where running.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame {
            if let url = running.bundleURL { candidates.insert(url.resolvingSymlinksInPath()) }
        }
        guard candidates.count == 1, let url = candidates.first else {
            throw ExecError(candidates.isEmpty ? "App not found. Use its exact installed name or bundle identifier." : "More than one app matches. Use its bundle identifier.")
        }
        return try app(at: url)
    }
    private func app(at url: URL) throws -> AccessibilityController.App {
        let url = url.resolvingSymlinksInPath()
        guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              id != Bundle.main.bundleIdentifier, url != Bundle.main.bundleURL.resolvingSymlinksInPath() else {
            throw ExecError("Invalid app target. Exec cannot open or control itself.")
        }
        return .init(url: url, bundleID: id, name: url.deletingPathExtension().lastPathComponent)
    }
    func open(_ target: AccessibilityController.App) async throws -> Int32 {
        let current = try app(at: target.url)
        guard current.bundleID == target.bundleID else { throw ExecError("App identity changed after approval. Nothing was opened.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        // LaunchServices has no cancellation handle. A late launch is never retried.
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { application, error in
                if let application { continuation.resume(returning: application.processIdentifier) }
                else { continuation.resume(throwing: ExecError("Application launch failed; it may already have started. Do not retry without a new user request.")) }
            }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private func string(_ reference: AXUIElement, _ name: String) -> String {
        String(((attribute(reference, name) as? String) ?? "").prefix(2000))
    }
    private func settable(_ reference: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(reference, name as CFString, &result) == .success && result.boolValue
    }
    private func focusedWindow(_ pid: Int32) throws -> AXUIElement {
        guard pid != ownProcessID else { throw ExecError("Accessibility tools cannot target Exec itself.") }
        _ = try applicationName(pid)
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(attribute(app, kAXFocusedWindowAttribute)) ?? element(attribute(app, kAXMainWindowAttribute)) else {
            throw ExecError("The app has no accessible focused window. Use a screenshot for visual inspection.")
        }
        return window
    }
    private func node(_ reference: AXUIElement) throws -> Node {
        let role = string(reference, kAXRoleAttribute)
        guard !role.isEmpty else { throw ExecError("Accessibility element is no longer readable.") }
        let subrole = string(reference, kAXSubroleAttribute)
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField" || (attribute(reference, "AXProtectedContent") as? Bool) == true
        let enabled = (attribute(reference, kAXEnabledAttribute) as? Bool) ?? true
        var value: String?
        var completeValue = false
        let textField = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
        if !secure, textField || role == "AXStaticText" {
            let count = (attribute(reference, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
            if count.map({ $0 <= 2000 }) != false, let raw = attribute(reference, kAXValueAttribute) as? String {
                completeValue = raw.unicodeScalars.count <= 2000
                let limit = textField ? 2000 : 500
                value = String(raw.prefix(limit)) + (raw.count > limit ? "… [truncated]" : "")
            } else { value = "[value omitted: too large or unavailable]" }
        }
        var actions: [String] = []
        if enabled && !secure {
            var supported: CFArray?
            if AXUIElementCopyActionNames(reference, &supported) == .success, (supported as? [String])?.contains(kAXPressAction) == true { actions.append("press") }
            if settable(reference, kAXFocusedAttribute) { actions.append("focus") }
            // Only replace fully visible values. Never silently overwrite omitted text.
            if textField && completeValue && settable(reference, kAXValueAttribute) { actions.append("set_value") }
        }
        return Node(role: role, subrole: subrole, title: string(reference, kAXTitleAttribute),
                    description: string(reference, kAXDescriptionAttribute), enabled: enabled, secure: secure, value: value, actions: actions)
    }

    func inspect(_ pid: Int32) async throws -> String {
        clear()
        let root = try focusedWindow(pid)
        let launch = NSRunningApplication(processIdentifier: pid)?.launchDate
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = Set<AXUIElement>()
        var found: [String: Element] = [:]
        var lines: [String] = []
        var bytes = 0
        var index = 0
        var truncated = false
        let start = ContinuousClock.now
        while index < queue.count {
            try Task.checkCancellation()
            guard index < 160, start.duration(to: .now) < .seconds(2) else { truncated = true; break }
            let (reference, depth) = queue[index]
            index += 1
            guard visited.insert(reference).inserted else { continue }
            AXUIElementSetMessagingTimeout(reference, 0.1)
            guard let info = try? node(reference) else { truncated = true; continue }
            let id = "e\(index)"
            if depth == 0 || !info.actions.isEmpty || !info.title.isEmpty || !info.description.isEmpty || info.value != nil || info.secure {
                var row: [String: Any] = ["id": id, "depth": depth, "role": info.role, "enabled": info.enabled, "actions": info.actions]
                if !info.title.isEmpty { row["title"] = String(info.title.prefix(300)) }
                if !info.description.isEmpty { row["description"] = String(info.description.prefix(300)) }
                if info.secure { row["value"] = "[protected]" }
                else if let value = info.value { row["value"] = value }
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                guard bytes + data.count + 1 <= 24_000 else { truncated = true; break }
                bytes += data.count + 1
                lines.append(String(decoding: data, as: UTF8.self))
                if !info.actions.isEmpty { found[id] = Element(reference: reference, node: info) }
            }
            if !info.secure {
                var count: CFIndex = 0
                if AXUIElementGetAttributeValueCount(reference, kAXChildrenAttribute as CFString, &count) == .success, count > 0 {
                    let limit = min(count, 160 - queue.count)
                    if depth >= 8 || limit <= 0 { truncated = true }
                    else {
                        var children: CFArray?
                        if AXUIElementCopyAttributeValues(reference, kAXChildrenAttribute as CFString, 0, limit, &children) == .success,
                           let children = children as? [AXUIElement] { queue += children.map { ($0, depth + 1) } }
                        else { truncated = true }
                        if limit < count { truncated = true }
                    }
                }
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        guard !lines.isEmpty, CFEqual(root, try focusedWindow(pid)), NSRunningApplication(processIdentifier: pid)?.launchDate == launch else {
            throw ExecError("Focused window changed or accessibility state was unavailable. No usable references were issued.")
        }
        elements = found
        window = root
        processID = pid
        launchDate = launch
        return lines.joined(separator: "\n") + (truncated ? "\nAccessibility view truncated or partially unavailable. Missing controls may require a screenshot." : "")
    }

    func act(_ request: AccessibilityTool.ActionRequest) throws {
        guard processID == request.process_id, frontProcessID == request.process_id,
              NSRunningApplication(processIdentifier: request.process_id)?.launchDate == launchDate,
              let saved = elements[request.element_id], let window,
              CFEqual(window, try focusedWindow(request.process_id)), !IsSecureEventInputEnabled() else {
            throw ExecError("Accessibility target changed or secure input is active. No action was sent.")
        }
        defer { clear() }
        var pid: pid_t = 0
        guard AXUIElementGetPid(saved.reference, &pid) == .success, pid == request.process_id,
              CFEqual(saved.reference, window) || element(attribute(saved.reference, kAXWindowAttribute)).map({ CFEqual($0, window) }) == true else {
            throw ExecError("Element no longer belongs to the inspected window. No action was sent.")
        }
        let current = try node(saved.reference)
        guard current == saved.node, current.actions.contains(request.action.rawValue), !current.secure else {
            throw ExecError("Element state or supported actions changed. No action was sent. Inspect the UI again.")
        }
        let result: AXError
        switch request.action {
        case .press: result = AXUIElementPerformAction(saved.reference, kAXPressAction as CFString)
        case .focus: result = AXUIElementSetAttributeValue(saved.reference, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case .setValue: result = AXUIElementSetAttributeValue(saved.reference, kAXValueAttribute as CFString, request.value as CFString)
        }
        guard result == .success else {
            throw ExecError("Accessibility action did not report success and may have had effects. It was not retried. Inspect before proceeding.")
        }
    }
}
