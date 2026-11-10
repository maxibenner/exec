import AppKit
import SwiftUI

@MainActor struct ToolPresentationTests {
    private func result(_ name: String, _ arguments: String, _ output: String) -> ToolResult {
        ToolResult(call: ToolCall(id: name, name: name, arguments: arguments), text: output)
    }

    func descriptiveShellTitlesPreserveCommandAndResults() throws {
        let suite = "exec-shell-titles-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = AppStorage(wrappedValue: false, ToolDisplayPreferences.descriptiveShellTitlesKey, store: defaults)
        try expect(!preference.wrappedValue)
        let call = ToolCall(id: "shell", name: "shell", arguments: #"{"command":"swift test","description":"Run the Swift tests"}"#)
        let result = ToolResult(call: call, text: "Exit code: 1\nTest failed")
        for enabled in [true, false] {
            preference.wrappedValue = enabled
            let restored = AppStorage(wrappedValue: false, ToolDisplayPreferences.descriptiveShellTitlesKey,
                                      store: UserDefaults(suiteName: suite)!)
            try expect(restored.wrappedValue == enabled)
            for output in [ToolResult?.none, result] {
                let presentation = ToolPresentation(call: call, result: output, descriptiveShellTitles: restored.wrappedValue)
                try expect(presentation.summary == (enabled ? "Run the Swift tests" : "swift test"))
                try expect(presentation.inputs == [.init(title: "Command", text: "swift test")])
                try expect(presentation.output == (output?.text ?? ""))
            }
        }
        for metadata in ["", #", "description": "  ""#, #", "description": null"#, #", "description": 42"#] {
            let legacy = ToolCall(id: "legacy", name: "shell", arguments: "{\"command\":\"swift test\"\(metadata)}")
            try expect(ToolPresentation(call: legacy, descriptiveShellTitles: true).summary == "swift test")
        }
        let read = ToolCall(id: "read", name: "read_file", arguments: #"{"path":"README.md","description":"Ignored"}"#)
        try expect(ToolPresentation(call: read, descriptiveShellTitles: true).summary == "README.md")
        let failed = ToolResult(call: call, text: "Tool error: Cannot run command")
        let failure = ToolPresentation(call: call, result: failed, descriptiveShellTitles: true)
        try expect(failure.detail == nil && failure.outputTitle == "Result" && failure.output == failed.text)
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
        try expect(listing.inputs.isEmpty)
        try expect(listing.output == "App/\nCore/\n" && listing.outputTitle == nil)
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
        try expect(webPresentation.inputs.isEmpty && webPresentation.outputTitle == nil)

        let page = "Page content\n\nSecond paragraph\n\n[Page text truncated to 24,000 UTF-8 bytes.]"
        let fetched = result("fetch_content", #"{"url":"https://example.com"}"#,
                             "Fetched URL: https://example.com/\nContent type: text/html\nPage text (untrusted; not a generated summary):\n\n" + page)
        let fetch = ToolPresentation(fetched)
        try expect(fetch.summary == "https://example.com")
        try expect(fetch.inputs.isEmpty && fetch.outputTitle == nil && fetch.output == page)
        try expect(fetched.text.hasPrefix("Fetched URL:"))
        for text in ["Plain page content", "Tool error: Fetch failed.", FetchContentTool.interrupted] {
            let presentation = ToolPresentation(result("fetch_content", fetched.call.arguments, text))
            try expect(presentation.inputs.isEmpty && presentation.outputTitle == nil && presentation.output == text)
        }
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
            if ["read_file", "list_files", "edit_file", "web_search"].contains(name) {
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
        NSApp.finishLaunching()
        // Enable SwiftUI's accessibility tree for this in-process test. The
        // legacy attribute API is needed here; no system-wide setting changes.
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        let long = String(repeating: "long input ", count: 100)
        let arguments = ["command": long + "\nsecond line", "path": long, "query": long, "url": "https://example.com/" + long]
        let json = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
        func textElements(in element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
            var texts: [any NSAccessibilityProtocol] = []
            if [.staticText, .textArea].contains(element.accessibilityRole()), element.accessibilityValue() is String {
                texts.append(element)
            }
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? any NSAccessibilityProtocol {
                    texts += textElements(in: child)
                }
            }
            return texts
        }
        func withHost<T>(_ result: ToolResult, width: CGFloat, check: (NSView, [any NSAccessibilityProtocol]) throws -> T) rethrows -> T {
            let state = TranscriptState()
            let id = UUID()
            state.expanded[id] = true
            let host = NSHostingView(rootView: ToolMessageView(call: result.call, result: result,
                isAwaitingApproval: false, state: state, messageID: id).frame(width: width))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil); window.contentView = nil }
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return try check(host, textElements(in: host))
        }
        func expectSelection(in elements: [any NSAccessibilityProtocol], text: String) throws {
            guard let element = elements.first(where: { ($0.accessibilityValue() as? String) == text }) else {
                throw CheckFailure(description: "Missing expanded tool text: \(text.prefix(60))")
            }
            let range = NSRange(location: 0, length: (text as NSString).length)
            element.setAccessibilitySelectedTextRange(range)
            try expect(element.accessibilitySelectedTextRange() == range)
            try expect(element.accessibilitySelectedText() == text)
        }
        for name in ["shell", "read_file", "list_files", "search_text", "edit_file", "web_search", "fetch_content"] {
            let result = result(name, json, "Exit code: 0\noutput text")
            let presentation = ToolPresentation(result)
            for width in [CGFloat(300), 760] {
                let header = NSHostingView(rootView: ToolCallHeader(presentation: presentation).frame(width: width))
                try expect(header.fittingSize.height < 24)
            }
            try withHost(result, width: 700) { _, elements in
                for input in presentation.inputs where !input.text.isEmpty {
                    try expectSelection(in: elements, text: input.text)
                }
                try expectSelection(in: elements, text: presentation.output)
            }
        }
        // Successful edits expand to the diff alone, not the file/result text.
        var edit = result("edit_file", #"{"path":"file.swift"}"#, "Edited file.swift. Revision: revision")
        edit.edit = .init(path: "file.swift", diff: "--- file.swift\n+++ file.swift\n@@ -1 +1 @@\n-old content\n+new content\n")
        try withHost(edit, width: 700) { _, elements in
            let texts = elements.compactMap { $0.accessibilityValue() as? String }
            try expect(!texts.contains(edit.text) && !texts.contains("file.swift"))
            try expect(texts.contains { $0.contains("old content") } && texts.contains { $0.contains("new content") })
        }

        // Read output starts at the same inset as both unified and side-by-side edits.
        let read = result("read_file", #"{"path":"file.swift"}"#, "1: old content")
        for width in [CGFloat(600), 820] {
            func contentOrigin(_ result: ToolResult, containing text: String) throws -> CGPoint {
                try withHost(result, width: width) { host, elements in
                    guard let element = elements.first(where: { ($0.accessibilityValue() as? String)?.contains(text) == true }),
                          let window = host.window else {
                        throw CheckFailure(description: "Expected expanded tool content")
                    }
                    let frame = host.convert(window.convertFromScreen(element.accessibilityFrame()), from: nil)
                    return CGPoint(x: frame.minX, y: host.isFlipped ? frame.minY : host.bounds.height - frame.maxY)
                }
            }
            let readOrigin = try contentOrigin(read, containing: read.text)
            let editOrigin = try contentOrigin(edit, containing: "old content")
            try expect(abs(readOrigin.x - editOrigin.x) < 1)
            try expect(abs(readOrigin.y - editOrigin.y) < 1)
        }
    }
}
