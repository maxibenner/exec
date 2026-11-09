import Foundation

/// Display-only interpretation of tool inputs and results. Stored tool data and
/// model context remain untouched.
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
    var outputTitle: String? = "Result"
    var output: String

    init(_ result: ToolResult) {
        self.init(call: result.call, result: result)
    }

    init(call: ToolCall, result: ToolResult? = nil) {
        struct Arguments: Decodable {
            var path: String?
            var query: String?
            var command: String?
            var url: String?
            var prompt: String?
        }
        let arguments = try? CodingTools.decode(Arguments.self, call)
        output = result?.text ?? ""
        switch call.name {
        case "shell":
            title = "Shell"; icon = "terminal"
            if let command = arguments?.command {
                summary = command
                inputs = [Field(title: "Command", text: command)]
            }
            outputTitle = "Output"
        case "list_files":
            title = "List"; icon = "folder"
            summary = arguments?.path
            outputTitle = nil
        case "read_file":
            title = "Read"; icon = "doc.text"
            summary = arguments?.path
            detail = result.flatMap { ReadFileSummary($0)?.lineLabel }
            outputTitle = nil
        case "search_text":
            title = "Search"; icon = "magnifyingglass"
            if let query = arguments?.query, let path = arguments?.path {
                summary = "\(query) · \(path)"
                inputs = [Field(title: "Query", text: query), Field(title: "Directory", text: path)]
            }
            outputTitle = "Matches"
        case "edit_file":
            title = "Edit"; icon = "pencil"
            summary = result?.edit?.path ?? arguments?.path
            outputTitle = nil
        case "fetch_content":
            title = "Fetch page"; icon = "doc.text"
            summary = arguments?.url
            outputTitle = nil
            // Hide the fetch envelope in the UI only; retain it in model context.
            if let result, result.text.hasPrefix("Fetched URL: "),
               let body = result.text.range(of: "\nPage text (untrusted; not a generated summary):\n\n") {
                output = String(result.text[body.upperBound...])
            }
        case "generate_image":
            title = "Generate image"; icon = "photo"
            summary = arguments?.prompt
            outputTitle = nil
        case "open_app", "inspect_ui", "ui_action":
            title = call.name == "open_app" ? "Open app" : call.name == "inspect_ui" ? "Inspect UI" : "UI action"
            icon = "accessibility"
            summary = (try? AccessibilityTool.request(call))?.summary
            outputTitle = "UI state"
        case "computer_use":
            title = "Computer use"; icon = "cursorarrow"
            summary = (try? ComputerUseTool.request(call))?.summary
            outputTitle = "Result"
        case "take_screenshot":
            title = "Screenshot"; icon = "camera"
            summary = (try? ScreenshotTool.request(call))?.summary
            outputTitle = nil

        case "web_search":
            title = "Web search"; icon = "globe"
            summary = result?.webSearch?.query ?? arguments?.query
            outputTitle = nil
        default:
            title = call.name; icon = "wrench"
        }
        if inputs.isEmpty, outputTitle != nil || result == nil {
            // Pending cards expose the complete request, even for tools whose
            // finished presentation normally shows only an image, diff or page.
            inputs = [Field(title: "Arguments", text: call.arguments)]
        }
        guard let result else { return }
        // Preserve terminal failures, including edits that have no saved diff.
        if result.edit == nil, result.webSearch == nil, detail == nil {
            if result.text.hasPrefix("Tool error: ") || result.text.hasPrefix("Error: ") { detail = "Error" }
            else if result.text.hasPrefix("User denied this ") { detail = "Denied" }
            else if result.text.hasPrefix("Interrupted.") || result.text == WebSearchTool.interrupted || result.text == FetchContentTool.interrupted || result.text == ScreenshotTool.interrupted || result.text == ImageGenerationTool.interrupted { detail = "Interrupted" }
            else if result.text.hasPrefix("Not executed:") || result.text == "Duplicate tool call ID; not executed." { detail = "Not run" }
            else if result.call.name == "shell", result.text.hasPrefix("Command timed out;") { detail = "Timed out" }
            if detail != nil, outputTitle != nil { outputTitle = "Result" }
        }
        // Shell and screenshot outcomes stay in the expanded output, not the header.
        if result.call.name == "shell" || result.call.name == "take_screenshot" { detail = nil }
    }

    var singleLineSummary: String? {
        summary?.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .replacingOccurrences(of: "\r", with: " ↵ ")
            .replacingOccurrences(of: "\t", with: " ⇥ ")
    }
}
