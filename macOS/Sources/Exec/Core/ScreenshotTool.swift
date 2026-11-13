import Foundation

enum ScreenshotTool {
    enum Target: String, Decodable, Sendable { case desktop, window, listWindows = "list_windows" }

    struct Request: Decodable, Sendable {
        let target: Target
        let window_id: UInt32

        var summary: String {
            switch target {
            case .desktop: "Main display"
            case .window: "Window \(window_id)"
            case .listWindows: "Visible windows"
            }
        }
    }

    struct Output: Sendable {
        let text: String
        var image: ImageAttachment?
        var windows: [Window]?
    }

    struct Window: Sendable {
        let id: UInt32
        let title: String
    }

    static func request(_ call: ToolCall) throws -> Request {
        let request = try CodingTools.decode(Request.self, call)
        guard (request.target == .window) == (request.window_id > 0) else {
            throw ExecError("Use a positive window_id for window capture, or 0 for desktop/list_windows.")
        }
        return request
    }

    static let interrupted = "Screenshot operation failed or was interrupted. No capture result was shared. Do not retry without a new user request."
}
