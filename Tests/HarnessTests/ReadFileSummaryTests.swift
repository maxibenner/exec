import Foundation

struct ReadFileSummaryTests {
    func showsActualReturnedLines() throws {
        let call = ToolCall(id: "read", name: "read_file", arguments: #"{"path":"Sources/File.swift","start_line":10,"end_line":40}"#)
        let summary = ReadFileSummary(ToolResult(call: call, text: "Revision: test\n10: first\n11: 999: content\n[Output truncated at 32 KiB.]"))
        try expect(summary?.path == "Sources/File.swift")
        try expect(summary?.lines == 10...11)
        try expect(summary?.lineLabel == "Lines 10–11")
        try expect(ReadFileSummary(ToolResult(call: call, text: "Revision: test\n10: only\n"))?.lineLabel == "Line 10")
        for output in ["Requested range is past end of file (2 lines).", "Error: not found", "Revision: test\n[Output truncated at 32 KiB.]"] {
            try expect(ReadFileSummary(ToolResult(call: call, text: output))?.lines == nil)
        }
        let malformed = ToolCall(id: "bad", name: "read_file", arguments: "{}")
        try expect(ReadFileSummary(ToolResult(call: malformed, text: "")) == nil)
    }
}
