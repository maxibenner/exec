import Foundation

enum ScreenshotTool {
    static let definition = ToolDefinition(name: "take_screenshot", description: "Capture the main desktop or a specific window without a picker. Use list_windows first to discover window IDs. Subject to auto mode or screenshot permission for this session; otherwise asks for approval. Captures and window titles are shared with the model and saved in the conversation. Never retry denied, failed, or interrupted operations without a new user request.", parameters: [
        .init(name: "target", type: "string", description: "desktop (main display), list_windows (visible window IDs and titles), or window"),
        .init(name: "window_id", type: "integer", description: "Window ID from list_windows for window capture; use 0 for desktop or list_windows")
    ])

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
        var text: String
        var image: ImageAttachment?
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
