import AppKit
import Observation

/// Independently authorized HTTP native channel. No reconnect, capture retry, or implicit grant.
@MainActor @Observable final class AgentDesktop {
    private let api: AgentAPI
    private let preflight: () -> Bool
    private let requestPermission: () -> Bool
    private let capture: (ScreenshotTool.Request) async throws -> ScreenshotTool.Output
    private(set) var frontendID: String?
    private(set) var enabled: Set<UUID> = []
    private(set) var changing: Set<UUID> = []
    private(set) var error: String?
    private var channel: Task<Void, Never>?
    private var captures: [String: Task<Void, Never>] = [:]
    private var reportedPermission = false

    init(api: AgentAPI, preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         requestPermission: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         capture: @escaping (ScreenshotTool.Request) async throws -> ScreenshotTool.Output = ScreenshotCapture.capture) {
        self.api = AgentAPI(transport: api.transport)
        self.preflight = preflight
        self.requestPermission = requestPermission
        self.capture = capture
    }

    func start() async throws {
        guard channel == nil, frontendID == nil else { return }
        reportedPermission = preflight()
        let body = try JSONEncoder().encode(AgentJSON.object(["osScreenPermission": .bool(reportedPermission)]))
        let events = api.transport.events("POST", "/v1/native/events", body: body)
        let deadline = Task { [weak self] in
            try await Task.sleep(for: .seconds(15))
            if self?.frontendID == nil { self?.stop() }
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
                channel = Task { [weak self] in
                    var registered = false
                    do {
                        for try await data in events {
                            try Task.checkCancellation()
                            guard let self else { throw CancellationError() }
                            let event = try JSONDecoder().decode(AgentJSON.self, from: data)
                            if !registered {
                                guard event["type"].string == "registered", let id = event["frontendID"].string else {
                                    throw ExecError("The screenshot channel returned an invalid registration.")
                                }
                                self.frontendID = id
                                registered = true
                                ready.resume()
                                continue
                            }
                            try await self.reportPermission()
                            switch event["type"].string {
                            case "request": self.receive(event["request"])
                            case "cancelled":
                                if let id = event["request"]["id"].string { self.captures.removeValue(forKey: id)?.cancel() }
                            default: break
                            }
                        }
                        throw ExecError("The screenshot channel closed.")
                    } catch {
                        if !registered { ready.resume(throwing: error) }
                        if !Task.isCancelled {
                            self?.error = "Screenshot access disconnected. Restart Exec to establish a new trusted channel."
                        }
                    }
                    self?.stop()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    private func reportPermission() async throws {
        let granted = preflight()
        guard granted != reportedPermission, let frontendID else { return }
        if !granted {
            enabled.removeAll()
            cancelCaptures()
        }
        _ = try await api.request("PUT", "/v1/native/permission", .object([
            "frontendID": .string(frontendID), "granted": .bool(granted)]))
        reportedPermission = granted
    }

    func setEnabled(_ grant: Bool, for conversation: UUID) async throws {
        guard changing.insert(conversation).inserted else { return }
        defer { changing.remove(conversation) }
        guard let frontendID else { throw ExecError(error ?? "Screenshot access is unavailable. Restart Exec to establish its trusted channel.") }
        if grant {
            // Only this explicit user action may request macOS Screen Recording access.
            guard preflight() || requestPermission() else {
                throw ExecError("Allow Exec in System Settings → Privacy & Security → Screen Recording, then enable screenshots again. You may need to restart Exec.")
            }
            try await reportPermission()
            guard reportedPermission else { throw ExecError("Screen Recording permission is not available yet. Restart Exec after granting it in System Settings.") }
        } else {
            enabled.remove(conversation)
            cancelCaptures() // Conservative: never share an in-flight capture after revocation.
        }
        _ = try await api.request("PUT", AgentAPI.path(conversation, "/desktop"), .object([
            "frontendID": grant ? .string(frontendID) : .null, "enabled": .bool(grant)]))
        try Task.checkCancellation()
        guard self.frontendID == frontendID else { throw ExecError("Screenshot access disconnected while permission was changing. Restart Exec before enabling it again.") }
        if grant {
            guard preflight() else { throw ExecError("Screen Recording permission was revoked.") }
            enabled.insert(conversation)
        }
    }

    private func receive(_ request: AgentJSON) {
        guard let id = request["id"].string, captures[id] == nil else { return }
        captures[id] = Task { [weak self] in
            guard let self else { return }
            defer { captures[id] = nil }
            var result = AgentJSON.object(["type": .string("failed")])
            do {
                guard request["frontendID"].string == frontendID,
                      let conversation = request["conversationID"].string.flatMap(UUID.init(uuidString:)),
                      enabled.contains(conversation), preflight(),
                      let target = request["action"]["target"].string.flatMap(ScreenshotTool.Target.init(rawValue:)) else {
                    throw ExecError("Screenshot request is no longer authorized.")
                }
                let number = request["action"]["windowID"].number ?? 0
                guard number >= 0, number <= Double(UInt32.max), number.rounded() == number,
                      (target == .window) == (number > 0) else { throw ExecError("Invalid screenshot target.") }
                let output = try await capture(.init(target: target, window_id: UInt32(number)))
                try Task.checkCancellation()
                guard preflight(), enabled.contains(conversation), request["frontendID"].string == frontendID else {
                    throw ExecError("Screenshot permission was revoked.")
                }
                if target == .listWindows, let windows = output.windows {
                    result = .object(["type": .string("windows"), "windows": .array(windows.map {
                        .object(["id": .number(Double($0.id)), "title": .string($0.title)])
                    })])
                } else if let image = output.image {
                    result = .object(["type": .string("image"), "base64": .string(image.data.base64EncodedString())])
                }
            } catch { /* One failed reply, without sensitive OS errors or screen contents. */ }
            guard !Task.isCancelled else { return }
            do { _ = try await api.request("POST", "/v1/native/results", .object(["request": request, "result": result])) }
            catch { /* Stale/ambiguous result acknowledgements must never be retried. */ }
        }
    }

    private func cancelCaptures() { captures.values.forEach { $0.cancel() }; captures.removeAll() }
    func stop() {
        channel?.cancel(); channel = nil
        cancelCaptures()
        frontendID = nil
        enabled.removeAll()
    }
}
