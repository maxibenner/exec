import AppKit
import SwiftUI

@MainActor struct ToolPresentationTests {
    private func result(_ name: String, _ arguments: String, _ output: String) -> ToolResult {
        ToolResult(call: ToolCall(id: name, name: name, arguments: arguments), text: output)
    }

    func describesInputsAndPreservesResults() throws {
        let command = "printf 'hello'\nprintf 'world'"
        let arguments = String(decoding: try JSONEncoder().encode(["command": command]), as: UTF8.self)
        let shell = ToolPresentation(result("shell", arguments, "Exit code: 2\nhello\nworld\n"))
        try expect(shell.summary == command && shell.singleLineSummary == "printf 'hello' ↵ printf 'world'")
        try expect(shell.detail == nil && shell.inputs == [.init(title: "Command", text: command)])
        try expect(shell.output == "Exit code: 2\nhello\nworld\n")
        let empty = ToolPresentation(result("shell", arguments, "Exit code: 0\n"))
        try expect(empty.detail == nil && empty.output == "Exit code: 0\n")

        let listing = ToolPresentation(result("list_files", #"{"path":"Sources"}"#, "App/\nCore/\n"))
        try expect(listing.summary == "Sources" && listing.detail == nil)
        try expect(listing.inputs == [.init(title: "Directory", text: "Sources")])
        try expect(listing.output == "App/\nCore/\n" && listing.outputTitle == "Entries")
        let read = ToolPresentation(result("read_file", #"{"path":"file.swift","start_line":10,"end_line":400}"#,
                                           "Revision: revision\n10: first\n11: last\n[Output truncated at 32 KiB.]"))
        try expect(read.summary == "file.swift" && read.detail == "Lines 10–11")
        try expect(read.inputs.isEmpty && read.outputTitle == nil)
        try expect(read.output.hasPrefix("Revision: revision") && read.output.contains("[Output truncated"))
        let search = ToolPresentation(result("search_text", #"{"path":"Sources","query":"literal .*"}"#, "No matches in searched files.\n[Search incomplete]"))
        try expect(search.summary == "literal .* · Sources" && search.outputTitle == "Matches")
        try expect(search.inputs == [.init(title: "Query", text: "literal .*"), .init(title: "Directory", text: "Sources")])
        try expect(search.output.contains("[Search incomplete]"))

        var edit = result("edit_file", #"{"path":"file.swift"}"#, "Edited file.swift. Revision: new-revision")
        edit.edit = .init(path: "file.swift", diff: "-old\n+new")
        let applied = ToolPresentation(edit)
        try expect(applied.summary == "file.swift" && applied.detail == nil)
        try expect(applied.inputs.isEmpty && applied.outputTitle == nil)
        var web = result("web_search", #"{"query":"native layout"}"#, "Opaque context")
        web.webSearch = .init(query: "native layout", answer: "Answer", sources: [])
        let webPresentation = ToolPresentation(web)
        try expect(webPresentation.summary == "native layout")
        try expect(webPresentation.inputs == [.init(title: "Query", text: "native layout")])
    }

    func handlesFailuresAndUnknownArgumentsHonestly() throws {
        for text in [
            "User denied this command. It was not executed.",
            "Command timed out; termination requested for its process group. It may have changed files.\npartial",
            "Interrupted. An operation may have changed files.",
            "Not executed: the turn was stopped.",
            "Tool error: Cannot run command."
        ] {
            let presentation = ToolPresentation(result("shell", #"{"command":"some command"}"#, text))
            try expect(presentation.summary == "some command" && presentation.detail == nil)
            try expect(presentation.output == text && presentation.outputTitle == "Result")
        }
        let denied = ToolPresentation(result("edit_file", #"{"path":"file","expected_revision":"new","old_text":"","new_text":"new"}"#,
                                              "User denied this edit. Nothing was written."))
        try expect(denied.title == "Edit" && denied.detail == "Denied")
        try expect(denied.inputs.isEmpty && denied.outputTitle == nil)
        try expect(denied.output == "User denied this edit. Nothing was written.")
        for name in ["shell", "read_file", "list_files", "search_text", "edit_file", "web_search", "unknown_tool"] {
            let malformed = ToolPresentation(result(name, "{broken", "Tool error: invalid arguments"))
            if name == "read_file" || name == "edit_file" {
                try expect(malformed.inputs.isEmpty && malformed.outputTitle == nil)
            } else {
                try expect(malformed.inputs == [.init(title: "Arguments", text: "{broken")])
            }
            try expect(malformed.summary == nil && malformed.output == "Tool error: invalid arguments")
        }
        let unknown = ToolPresentation(result("unknown_tool", #"{"custom":true}"#, "Exact result\n"))
        try expect(unknown.title == "unknown_tool" && unknown.output == "Exact result\n")
        let invalidStatus = ToolPresentation(result("shell", #"{"command":"echo"}"#, "Exit code: unknown\noutput"))
        try expect(invalidStatus.detail == nil && invalidStatus.output == "Exit code: unknown\noutput")
    }

    func keepsHeadersOnOneLineAndBodiesSelectable() throws {
        _ = NSApplication.shared
        let long = String(repeating: "long input ", count: 100)
        let arguments = ["command": long + "\nsecond line", "path": long, "query": long]
        let json = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        for name in ["shell", "read_file", "list_files", "search_text", "edit_file", "web_search"] {
            let result = result(name, json, "Exit code: 0\noutput text")
            let presentation = ToolPresentation(result)
            for width in [CGFloat(300), 760] {
                let header = NSHostingView(rootView: ToolCallHeader(presentation: presentation).frame(width: width))
                try expect(header.fittingSize.height < 24)
            }
            let state = TranscriptState()
            let id = UUID()
            state.expanded[id] = true
            let body = NSHostingView(rootView: ToolMessageView(result: result, state: state, messageID: id).frame(width: 700))
            body.frame.size = body.fittingSize
            body.layoutSubtreeIfNeeded()
            let fields = fields(in: body)
            for input in presentation.inputs where !input.text.isEmpty {
                try expect(fields.contains { $0.isSelectable && $0.stringValue == input.text })
            }
            try expect(fields.contains { $0.isSelectable && $0.stringValue == presentation.output })
        }
        // Successful edits expand to the diff alone, not the file/result text.
        var edit = result("edit_file", #"{"path":"file.swift"}"#, "Edited file.swift. Revision: revision")
        edit.edit = .init(path: "file.swift", diff: "--- file.swift\n+++ file.swift\n@@ -1 +1 @@\n-old content\n+new content\n")
        let host = NSHostingView(rootView: ToolMessageView(result: edit, state: TranscriptState(), messageID: UUID()).frame(width: 700))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let texts = fields(in: host).map(\.stringValue)
        try expect(!texts.contains(edit.text) && !texts.contains("file.swift"))
        try expect(texts.contains { $0.contains("old content") } && texts.contains { $0.contains("new content") })
    }
}
