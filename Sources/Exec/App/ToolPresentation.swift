import Foundation

/// Display-only interpretation of tool inputs. Stored results and model context
/// remain untouched; unfamiliar or malformed inputs retain their raw arguments.
struct ToolPresentation {
    struct Field: Equatable {
        let title: String
        let text: String
    }

    let title: String
    let icon: String
    var summary: String?
    var detail: String?
    var inputs: [Field] = []
    var outputTitle = "Result"
    var output: String

    init(_ result: ToolResult) {
        struct Arguments: Decodable {
            var path: String?
            var query: String?
            var command: String?
            var start_line: Int?
            var end_line: Int?
            var expected_revision: String?
            var old_text: String?
            var new_text: String?
        }
        let arguments = try? CodingTools.decode(Arguments.self, result.call)
        output = result.text
        switch result.call.name {
        case "shell":
            title = "Shell"; icon = "terminal"
            if let command = arguments?.command {
                summary = command
                inputs = [Field(title: "Command", text: command)]
            }
            outputTitle = "Output"
            // Only remove the runner's explicit numeric status line. Warnings,
            // timeouts and unfamiliar/legacy output remain intact in the body.
            let parts = result.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let first = String(parts.first ?? "")
            for (prefix, label) in [("Exit code: ", "Exit "), ("Terminated by signal: ", "Signal ")] {
                if first.hasPrefix(prefix), let number = Int(first.dropFirst(prefix.count)), number >= 0 {
                    detail = label + String(number)
                    output = parts.count > 1 ? String(parts[1]) : ""
                    break
                }
            }
        case "list_files":
            title = "List"; icon = "folder"
            if let path = arguments?.path {
                summary = path
                inputs = [Field(title: "Directory", text: path)]
            }
            outputTitle = "Entries"
        case "read_file":
            title = "Read"; icon = "doc.text"
            if let path = arguments?.path {
                summary = path
                inputs = [Field(title: "File", text: path)]
                if let start = arguments?.start_line, let end = arguments?.end_line {
                    inputs.append(Field(title: "Requested lines", text: start == end ? String(start) : "\(start)–\(end)"))
                }
            }
            detail = ReadFileSummary(result)?.lineLabel
            outputTitle = "Contents"
        case "search_text":
            title = "Search"; icon = "magnifyingglass"
            if let query = arguments?.query, let path = arguments?.path {
                summary = "\(query) · \(path)"
                inputs = [Field(title: "Query", text: query), Field(title: "Directory", text: path)]
            }
            outputTitle = "Matches"
        case "edit_file":
            title = "Edit"; icon = "pencil"
            if let edit = result.edit {
                summary = edit.path
                inputs = [Field(title: "File", text: edit.path)]
                detail = "Applied"
            } else if let path = arguments?.path {
                summary = path
                inputs = [Field(title: "File", text: path)]
                if let revision = arguments?.expected_revision {
                    inputs.append(Field(title: "Expected revision", text: revision))
                }
                if let old = arguments?.old_text, let new = arguments?.new_text {
                    inputs.append(Field(title: "Text to replace", text: old))
                    inputs.append(Field(title: "Replacement text", text: new))
                }
            }
        case "web_search":
            title = "Web search"; icon = "globe"
            if let query = result.webSearch?.query ?? arguments?.query {
                summary = query
                inputs = [Field(title: "Query", text: query)]
            }
        default:
            title = result.call.name; icon = "wrench"
        }
        if inputs.isEmpty { inputs = [Field(title: "Arguments", text: result.call.arguments)] }
        // These are terminal outcomes emitted by execution/recovery, not progress
        // hints. Never call a requested edit "Applied" without the saved edit.
        if result.edit == nil, result.webSearch == nil, detail == nil {
            if result.text.hasPrefix("Tool error: ") || result.text.hasPrefix("Error: ") { detail = "Error" }
            else if result.text.hasPrefix("User denied this ") { detail = "Denied" }
            else if result.text.hasPrefix("Interrupted.") || result.text == WebSearchTool.interrupted { detail = "Interrupted" }
            else if result.text.hasPrefix("Not executed:") || result.text == "Duplicate tool call ID; not executed." { detail = "Not run" }
            else if result.call.name == "shell", result.text.hasPrefix("Command timed out;") { detail = "Timed out" }
            if detail != nil { outputTitle = "Result" }
        }
    }

    var singleLineSummary: String? {
        summary?.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .replacingOccurrences(of: "\r", with: " ↵ ")
            .replacingOccurrences(of: "\t", with: " ⇥ ")
    }
}
