#if canImport(ExecTranscript)
import ExecTranscript
typealias ReadFileSummary = ExecTranscript.ReadFileSummary
#endif

extension ReadFileSummary {
    init?(_ result: ToolResult) {
        self.init(name: result.call.name, arguments: result.call.arguments, output: result.text)
    }
}
