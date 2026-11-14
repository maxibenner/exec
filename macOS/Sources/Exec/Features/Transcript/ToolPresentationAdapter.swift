#if canImport(ExecTranscript)
import ExecTranscript
typealias ToolPresentation = ExecTranscript.ToolPresentation
typealias ToolDisplayResult = ExecTranscript.ToolDisplayResult
#endif

extension ToolPresentation {
    init(_ result: ToolResult) { self.init(call: result.call, result: result) }
    init(call: ToolCall, result: ToolResult? = nil, descriptiveShellTitles: Bool = false) {
        self.init(name: call.name, arguments: call.arguments, result: result.map {
            ToolDisplayResult(text: $0.text, outcome: $0.outcome, editPath: $0.edit?.path,
                searchQuery: $0.webSearch?.query, pageText: $0.pageText,
                legacyInterrupted: [WebSearchTool.interrupted, FetchContentTool.interrupted,
                    ScreenshotTool.interrupted, ImageGenerationTool.interrupted].contains($0.text))
        }, descriptiveShellTitles: descriptiveShellTitles)
    }
}
