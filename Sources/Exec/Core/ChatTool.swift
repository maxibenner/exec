import Foundation

struct ToolCall: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let arguments: String
}

struct ToolDefinition: Sendable {
    struct Parameter: Sendable {
        let name: String
        let type: String
        let description: String
    }
    let name: String
    let description: String
    let parameters: [Parameter]
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
}

enum CodingTools {
    static let definitions: [ToolDefinition] = [
        .init(name: "list_files", description: "List one workspace directory. Paths are relative; use '.' for the root. Symlinks are not followed.", parameters: [
            .init(name: "path", type: "string", description: "Relative directory path")
        ]),
        .init(name: "read_file", description: "Read UTF-8 text with line numbers and a full-file Revision for edit_file. At most 400 lines and 32 KiB of output; files must be at most 1 MiB. Symlinks are not followed.", parameters: [
            .init(name: "path", type: "string", description: "Relative file path"),
            .init(name: "start_line", type: "integer", description: "First line, starting at 1"),
            .init(name: "end_line", type: "integer", description: "Last line, inclusive")
        ]),
        .init(name: "search_text", description: "Search UTF-8 files for a case-sensitive literal string, not a regex. Bounded recursive search; skips hidden entries, node_modules, dist, symlinks, binary files and files over 1 MiB. Reports incomplete searches.", parameters: [
            .init(name: "path", type: "string", description: "Relative directory path; '.' for root"),
            .init(name: "query", type: "string", description: "Nonempty literal text")
        ]),
        .init(name: "edit_file", description: "Propose one exact replacement subject to the user's approval setting. First read_file and pass its Revision as expected_revision. old_text must occur exactly once. For a new file, use expected_revision 'new' and empty old_text; the parent directory must exist. Arguments must fit within 32 KiB; split large changes. Never retry interrupted edits automatically.", parameters: [
            .init(name: "path", type: "string", description: "Relative file path"),
            .init(name: "expected_revision", type: "string", description: "Revision from read_file, or 'new' to create a file"),
            .init(name: "old_text", type: "string", description: "Exact unique text to replace"),
            .init(name: "new_text", type: "string", description: "Replacement text")
        ]),
        .init(name: "shell", description: "Run a bash command in the workspace subject to the user's approval setting. Not sandboxed. Commands have a 60-second timeout and bounded combined output. Never automatically retry commands or assume a cancelled command had no effects.", parameters: [
            .init(name: "command", type: "string", description: "Exact shell command to show for approval")
        ])
    ]

    static func command(_ call: ToolCall) throws -> String {
        struct Arguments: Decodable { let command: String }
        let command = try decode(Arguments.self, call).command
        guard !command.isEmpty, command.utf8.count <= 16_384, !command.contains("\0") else {
            throw ExecError("Shell command must be nonempty, contain no NUL bytes, and be at most 16 KiB.")
        }
        return command
    }

    static func readOnly(_ call: ToolCall, workspace: Workspace) throws -> String {
        let files = WorkspaceFiles(root: workspace.root)
        switch call.name {
        case "list_files":
            struct Arguments: Decodable { let path: String }
            return try files.list(decode(Arguments.self, call).path)
        case "read_file":
            struct Arguments: Decodable { let path: String; let start_line: Int; let end_line: Int }
            let arguments = try decode(Arguments.self, call)
            return try files.read(arguments.path, start: arguments.start_line, end: arguments.end_line)
        case "search_text":
            struct Arguments: Decodable { let path: String; let query: String }
            let arguments = try decode(Arguments.self, call)
            return try files.search(arguments.path, query: arguments.query)
        default: throw ExecError("Unknown tool: \(call.name)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ call: ToolCall) throws -> T {
        guard call.arguments.utf8.count <= 32_768 else { throw ExecError("Tool arguments exceeded 32 KiB.") }
        do { return try JSONDecoder().decode(type, from: Data(call.arguments.utf8)) }
        catch { throw ExecError("Invalid arguments for \(call.name).") }
    }
}
