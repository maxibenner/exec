import Foundation

/// Display-only interpretation of tool inputs and results. Stored tool data and
/// model context remain untouched.
public struct ToolPresentation: Sendable {
    public struct Field: Equatable, Sendable {
        public let title: String
        public let text: String
        public init(title: String, text: String) { self.title = title; self.text = text }
    }

    public let title: String
    public let icon: String
    public var summary: String?
    public var detail: String?
    public var inputs: [Field] = []
    public var outputTitle: String? = "Result"
    public var output: String
    public var showsOutput = true
    /// A result body can be published before the executor has settled.
    public let isRunning: Bool

    public init(name: String, arguments rawArguments: String, result: ToolDisplayResult? = nil, descriptiveShellTitles: Bool = false) {
        isRunning = result?.outcome == "running"
        struct DelegatedTask: Decodable {
            let task: String
            let title: String?

            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let legacyTask = try? value.decode(String.self) {
                    task = legacyTask
                    title = nil
                } else {
                    struct TitledTask: Decodable { let task: String; let title: String }
                    let entry = try value.decode(TitledTask.self)
                    task = entry.task
                    title = entry.title
                }
            }
        }
        struct Arguments: Decodable {
            var path: String?
            var query: String?
            var command: String?
            var url: String?
            var prompt: String?
            var task: String?
            var title: String?
            var tasks: [DelegatedTask]?
        }
        let arguments = rawArguments.utf8.count <= 32_768 ? try? JSONDecoder().decode(Arguments.self, from: Data(rawArguments.utf8)) : nil
        output = result?.text ?? ""
        let metadata = ToolDisplayMetadata(name: name)
        title = name == "delegate" && arguments?.tasks != nil ? "Sub-agents" : metadata.transcriptTitle
        icon = metadata.icon
        switch name {
        case "delegate":
            summary = arguments?.title ?? arguments?.task ?? arguments?.tasks?.map { $0.title ?? $0.task }.joined(separator: " · ")
            if let tasks = arguments?.tasks {
                inputs = tasks.enumerated().map { Field(title: "Task \($0.offset + 1)", text: $0.element.task) }
            } else if let task = arguments?.task {
                inputs = [Field(title: "Task", text: task)]
            }
        case "wait":
            showsOutput = false
            struct WaitArguments: Decodable {
                let duration_seconds: Int
                let description: String
                let wake_prompt: String
            }
            if rawArguments.utf8.count <= 32_768,
               let wait = try? JSONDecoder().decode(WaitArguments.self, from: Data(rawArguments.utf8)) {
                summary = wait.description
                inputs = [Field(title: "Duration", text: "\(wait.duration_seconds)s"),
                          Field(title: "Wake prompt", text: wait.wake_prompt)]
            }
        case "shell":
            if let command = arguments?.command {
                summary = descriptiveShellTitles ? (Self.shellDescription(rawArguments) ?? command) : command
                inputs = [Field(title: "Command", text: command)]
            }
            outputTitle = "Output"
        case "list_files":
            summary = arguments?.path
            outputTitle = nil
        case "read_file":
            summary = arguments?.path
            detail = result.flatMap { ReadFileSummary(name: name, arguments: rawArguments, output: $0.text)?.lineLabel }
            outputTitle = nil
        case "search_text":
            if let query = arguments?.query, let path = arguments?.path {
                summary = "\(query) · \(path)"
                inputs = [Field(title: "Query", text: query), Field(title: "Directory", text: path)]
            }
            outputTitle = "Matches"
        case "edit_file":
            summary = result?.editPath ?? arguments?.path
            outputTitle = nil
        case "fetch_content":
            summary = arguments?.url
            outputTitle = nil
            if let text = result?.pageText { output = text }
            // Hide the fetch envelope in the UI only; retain it in model context.
            if let result, result.text.hasPrefix("Fetched URL: "),
               let body = result.text.range(of: "\nPage text (untrusted; not a generated summary):\n\n") {
                output = String(result.text[body.upperBound...])
            }
        case "generate_image":
            summary = arguments?.prompt
            outputTitle = nil
        case "take_screenshot":
            summary = Self.screenshotSummary(rawArguments)
            outputTitle = nil

        case "web_search":
            summary = result?.searchQuery ?? arguments?.query
            outputTitle = nil
        default:
            break
        }
        if inputs.isEmpty, outputTitle != nil || result == nil {
            // Pending cards expose the complete request, even for tools whose
            // finished presentation normally shows only an image, diff or page.
            inputs = [Field(title: "Arguments", text: rawArguments)]
        }
        // Child failure text is still output, not a terminal state for a live delegate.
        guard let result, !isRunning else { return }
        // Preserve terminal failures, including edits that have no saved diff.
        if result.editPath == nil, result.searchQuery == nil, detail == nil {
            if result.text.hasPrefix("Tool error: ") || result.text.hasPrefix("Error: ") { detail = "Error" }
            else if result.text.hasPrefix("User denied this ") { detail = "Denied" }
            else if result.text.hasPrefix("Interrupted.") || result.legacyInterrupted { detail = "Interrupted" }
            else if result.text.hasPrefix("Not executed:") || result.text == "Duplicate tool call ID; not executed." { detail = "Not run" }
            else if name == "shell", result.text.hasPrefix("Command timed out;") { detail = "Timed out" }
            if detail != nil, outputTitle != nil { outputTitle = "Result" }
        }
        if let outcome = result.outcome {
            switch outcome {
            case "denied": detail = "Denied"
            case "failed": detail = "Error"
            case "interrupted": detail = "Interrupted"
            case "not_executed": detail = "Not run"
            default: break
            }
        }
        // Shell and screenshot outcomes stay in the expanded output, not the header.
        if name == "shell" || name == "take_screenshot" { detail = nil }
    }

    public var singleLineSummary: String? {
        summary?.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .replacingOccurrences(of: "\r", with: " ↵ ")
            .replacingOccurrences(of: "\t", with: " ⇥ ")
    }
    private static func shellDescription(_ arguments: String) -> String? {
        struct Description: Decodable { let description: String? }
        guard arguments.utf8.count <= 32_768,
              let value = try? JSONDecoder().decode(Description.self, from: Data(arguments.utf8)),
              let text = value.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    private static func screenshotSummary(_ arguments: String) -> String? {
        struct Capture: Decodable { let target: String; let window_id: UInt32 }
        guard arguments.utf8.count <= 32_768,
              let value = try? JSONDecoder().decode(Capture.self, from: Data(arguments.utf8)) else { return nil }
        switch (value.target, value.window_id) {
        case ("desktop", 0): return "Main display"
        case ("list_windows", 0): return "Visible windows"
        case ("window", let id) where id > 0: return "Window \(id)"
        default: return nil
        }
    }

}
