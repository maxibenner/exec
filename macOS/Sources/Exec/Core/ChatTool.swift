import Foundation

struct ToolCall: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let arguments: String
}

struct ToolResult: Codable, Sendable, Equatable {
    struct AppliedEdit: Codable, Sendable, Equatable {
        let path: String
        let diff: String
    }
    let call: ToolCall
    let text: String
    var edit: AppliedEdit?
    var webSearch: WebSearchResult?
    var screenshot: ImageAttachment?
    var generatedImage: ImageAttachment?
    var outcome: String?
    var pageText: String?
}

enum CodingTools {
    // Display metadata must never affect command validation or execution.
    // Older persisted calls may not include a description.
    static func shellDescription(_ call: ToolCall) -> String? {
        guard call.name == "shell" else { return nil }
        struct Arguments: Decodable { let description: String? }
        guard let arguments = try? decode(Arguments.self, call),
              let description = arguments.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        return description
    }

    static func decode<T: Decodable>(_ type: T.Type, _ call: ToolCall) throws -> T {
        guard call.arguments.utf8.count <= 32_768 else { throw ExecError("Tool arguments exceeded 32 KiB.") }
        do { return try JSONDecoder().decode(type, from: Data(call.arguments.utf8)) }
        catch { throw ExecError("Invalid arguments for \(call.name).") }
    }
}
