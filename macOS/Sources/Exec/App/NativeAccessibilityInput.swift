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
        let selected: Bool?
        let focused: Bool?
        let actions: [String]
    }
    private struct Element {
        let reference: AXUIElement
        let node: Node
        let path: [AXUIElement]
    }
    private var keyboardFocus: AXUIElement?
    private var keyboardFocusState: Node?
    private var elements: [String: Element] = [:]
    private var window: AXUIElement?
    private var processID: Int32?
    private var launchDate: Date?
    private let native = NativeComputerInput()
    var ownProcessID: Int32 { native.ownProcessID }
    var frontProcessID: Int32 { native.frontProcessID }

    func clear() {
        elements = [:]; window = nil; processID = nil; launchDate = nil
        keyboardFocus = nil; keyboardFocusState = nil
    }
    func isRunning(_ pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }
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
            if settable(reference, kAXSelectedAttribute) { actions.append("select") }
            // Only replace fully visible values. Never silently overwrite omitted text.
            if textField && completeValue && settable(reference, kAXValueAttribute) { actions.append("set_value") }
        }
        return Node(role: role, subrole: subrole, title: string(reference, kAXTitleAttribute),
                    description: string(reference, kAXDescriptionAttribute), enabled: enabled, secure: secure, value: value,
                    selected: attribute(reference, kAXSelectedAttribute) as? Bool,
                    focused: attribute(reference, kAXFocusedAttribute) as? Bool, actions: actions)
    }

    private func protected(_ reference: AXUIElement) -> Bool {
        string(reference, kAXRoleAttribute) == "AXSecureTextField" ||
        string(reference, kAXSubroleAttribute) == "AXSecureTextField" ||
        (attribute(reference, "AXProtectedContent") as? Bool) == true
    }

    private func children(_ reference: AXUIElement, limit: Int) -> [AXUIElement] {
        guard !protected(reference) else { return [] }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(reference, kAXChildrenAttribute as CFString, &count) == .success, count > 0 else { return [] }
        var children: CFArray?
        guard AXUIElementCopyAttributeValues(reference, kAXChildrenAttribute as CFString, 0, min(count, limit), &children) == .success else { return [] }
        return children as? [AXUIElement] ?? []
    }

    private func focusedElement(_ pid: Int32) -> AXUIElement? {
        element(attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute))
    }

    func inspect(_ pid: Int32, filter: AccessibilityTool.Filter) async throws -> String {
        clear()
        let root = try focusedWindow(pid)
        let launch = NSRunningApplication(processIdentifier: pid)?.launchDate
        let focus = focusedElement(pid)
        let focusState = focus.flatMap { try? node($0) }
        var readNodes: [AXUIElement: Node] = [:]
        var partiallyUnavailable = false
        // Filtering uses only labels, not action discovery on every skipped node.
        // In a broad view, read each node once and omit unlabelled structural matches.
        let search = try await AccessibilityTree.search(in: root, matches: { reference in
            if filter.isEmpty {
                guard let info = try? self.node(reference) else { partiallyUnavailable = true; return false }
                readNodes[reference] = info
                return CFEqual(reference, root) || !info.actions.isEmpty || !info.title.isEmpty ||
                    !info.description.isEmpty || info.value != nil || info.secure || info.selected == true || info.focused == true
            }
            let role = self.string(reference, kAXRoleAttribute)
            guard !role.isEmpty else { partiallyUnavailable = true; return false }
            guard !self.protected(reference) else { return false }
            var text = [self.string(reference, kAXTitleAttribute), self.string(reference, kAXDescriptionAttribute)]
            if ["AXTextField", "AXTextArea", "AXComboBox", "AXStaticText"].contains(role) {
                let count = (self.attribute(reference, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
                if count.map({ $0 <= 2000 }) != false { text.append(self.string(reference, kAXValueAttribute)) }
            }
            return filter.matches(role: role, text: text)
        }, children: { self.children($0, limit: $1) })
        var found: [String: Element] = [:]
        var identifiers: [AXUIElement: String] = [:]
        var lines: [String] = []
        var bytes = 0
        var truncated = search.truncated || partiallyUnavailable
        let renderStart = ContinuousClock.now
        // Always expose the window for shortcuts, even when the search finds nothing.
        render: for path in [[root]] + search.paths {
            for index in path.indices {
                let reference = path[index]
                if let id = identifiers[reference] {
                    if found[id]?.node.secure == true { break }
                    continue
                }
                try Task.checkCancellation()
                guard found.count < 160, renderStart.duration(to: .now) < .seconds(2) else { truncated = true; break render }
                guard let info = readNodes[reference] ?? (try? node(reference)) else { truncated = true; break }
                let id = "e\(found.count + 1)"
                var actions = info.actions
                if index == 0, let focusState, !focusState.secure { actions.append("press_key") }
                var row: [String: Any] = ["id": id, "depth": index, "role": info.role, "enabled": info.enabled, "actions": actions]
                if index > 0, let parent = identifiers[path[index - 1]] { row["parent_id"] = parent }
                if !info.title.isEmpty { row["title"] = String(info.title.prefix(300)) }
                if !info.description.isEmpty { row["description"] = String(info.description.prefix(300)) }
                if let selected = info.selected { row["selected"] = selected }
                if let focused = info.focused { row["focused"] = focused }
                if info.secure { row["value"] = "[protected]" }
                else if let value = info.value { row["value"] = value }
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                guard bytes + data.count + 1 <= 24_000 else { truncated = true; break render }
                bytes += data.count + 1
                lines.append(String(decoding: data, as: UTF8.self))
                identifiers[reference] = id
                found[id] = Element(reference: reference, node: info, path: Array(path.prefix(index + 1)))
                if info.secure { break }
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        guard !lines.isEmpty, CFEqual(root, try focusedWindow(pid)), NSRunningApplication(processIdentifier: pid)?.launchDate == launch else {
            throw ExecError("Focused window changed or accessibility state was unavailable. No usable references were issued.")
        }
        elements = found
        window = root
        processID = pid
        launchDate = launch
        keyboardFocus = focus
        keyboardFocusState = focusState
        let result = !filter.isEmpty && search.paths.isEmpty ? "\nNo matching controls found in the bounded search." : ""
        let scope = filter.isEmpty ? "" : "\nFiltered view with ancestors; other selected items may be omitted. Do not assume selection is exclusive."
        return lines.joined(separator: "\n") + result + scope + (truncated ? "\nAccessibility view truncated or partially unavailable. Narrow query/role or use a screenshot for missing controls." : "")
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
        guard AXUIElementGetPid(saved.reference, &pid) == .success, pid > 0, pid != ownProcessID else {
            throw ExecError("Element process is unavailable or belongs to Exec. No action was sent.")
        }
        // Remote Open/Save panel controls need not report the host app's PID or
        // AXWindow. Instead, prove the exact reference is still in its current tree.
        let belongs = try AccessibilityTree.containsPath(saved.path, in: window) { self.children($0, limit: $1) }
        guard belongs else {
            throw ExecError("Element is no longer reachable in the inspected window's bounded accessibility tree. No action was sent. Inspect the UI again.")
        }
        let current = try node(saved.reference)
        guard current == saved.node, !current.secure,
              request.action == .pressKey || current.actions.contains(request.action.rawValue) else {
            throw ExecError("Element state or supported actions changed. No action was sent. Inspect the UI again.")
        }
        try Task.checkCancellation()
        guard frontProcessID == request.process_id, CFEqual(window, try focusedWindow(request.process_id)), !IsSecureEventInputEnabled() else {
            throw ExecError("Focus changed or secure input became active during validation. No action was sent.")
        }
        if request.action == .pressKey {
            guard CFEqual(saved.reference, window), let keyboardFocus, let keyboardFocusState,
                  !keyboardFocusState.secure, let currentFocus = focusedElement(request.process_id),
                  CFEqual(keyboardFocus, currentFocus), try node(currentFocus) == keyboardFocusState else {
                throw ExecError("Keyboard focus changed or was unavailable/protected. No input was sent. Inspect the UI again.")
            }
            try native.checkPermission()
            try native.validateTarget(request.process_id, point: nil)
            try native.press(ComputerUseTool.Key(request.value))
            return
        }
        // A row may have no own label. Recheck its displayed descendants before
        // selecting it, so recycled row references cannot silently change targets.
        if request.action == .select {
            let start = ContinuousClock.now
            for child in elements.values where child.path.dropLast().contains(saved.reference) {
                guard start.duration(to: .now) < .seconds(2),
                      try AccessibilityTree.containsPath(child.path, in: window, children: { self.children($0, limit: $1) }),
                      try node(child.reference) == child.node else {
                    throw ExecError("Selection contents changed or could not be verified. No action was sent.")
                }
            }
        }
        try Task.checkCancellation()
        guard frontProcessID == request.process_id, CFEqual(window, try focusedWindow(request.process_id)), !IsSecureEventInputEnabled() else {
            throw ExecError("Focus changed or secure input became active. No action was sent.")
        }
        let result: AXError
        switch request.action {
        case .press: result = AXUIElementPerformAction(saved.reference, kAXPressAction as CFString)
        case .focus: result = AXUIElementSetAttributeValue(saved.reference, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case .select: result = AXUIElementSetAttributeValue(saved.reference, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        case .pressKey: preconditionFailure("Keyboard input is handled above")
        case .setValue: result = AXUIElementSetAttributeValue(saved.reference, kAXValueAttribute as CFString, request.value as CFString)
        }
        guard result == .success else {
            throw ExecError("Accessibility action did not report success and may have had effects. It was not retried. Inspect before proceeding.")
        }
    }
}
