import XCTest
@testable import ExecTranscript

final class ToolDisplayMetadataTests: XCTestCase {
    func testAllElevenToolsKeepSelectorLabelsAndConciseTranscriptTitles() {
        let expected = [
            ("list_files", "List files", "folder", "List"),
            ("read_file", "Read file", "doc.text", "Read"),
            ("search_text", "Search text", "magnifyingglass", "Search"),
            ("edit_file", "Edit file", "pencil", "Edit"),
            ("shell", "Run shell command", "terminal", "Shell"),
            ("web_search", "Search the web", "globe", "Web search"),
            ("fetch_content", "Fetch web page", "doc.text", "Fetch page"),
            ("generate_image", "Generate image", "photo", "Generate image"),
            ("take_screenshot", "Take screenshot", "camera", "Screenshot"),
            ("delegate", "Delegate to sub-agents", "person.2", "Sub-agent"),
            ("wait", "Wait", "stopwatch", "Wait")
        ]
        XCTAssertEqual(ToolDisplayMetadata.all.map(\.name), expected.map { $0.0 })
        for (name, label, icon, transcriptTitle) in expected {
            let metadata = ToolDisplayMetadata(name: name)
            XCTAssertEqual(metadata.id, name)
            XCTAssertEqual(metadata.label, label)
            XCTAssertEqual(metadata.icon, icon)
            XCTAssertEqual(metadata.transcriptTitle, transcriptTitle)
            // Both pending and settled cards use the same icon/title.
            let results: [ToolDisplayResult?] = [nil, .init(text: "Exact result", outcome: "completed")]
            for result in results {
                let card = ToolPresentation(name: name, arguments: "{invalid", result: result)
                XCTAssertEqual(card.title, transcriptTitle, name)
                XCTAssertEqual(card.icon, icon, name)
            }
        }
    }

    func testDynamicTranscriptTitlesAndSummariesDoNotUseSelectorLabels() {
        let single = ToolPresentation(name: "delegate", arguments: #"{"task":"Inspect files","title":"Inspection"}"#)
        XCTAssertEqual(single.title, "Sub-agent")
        XCTAssertEqual(single.summary, "Inspection")
        let batch = ToolPresentation(name: "delegate", arguments: #"{"tasks":[{"task":"Inspect files","title":"Inspection"},"Run tests"]}"#)
        XCTAssertEqual(batch.title, "Sub-agents")
        XCTAssertEqual(batch.summary, "Inspection · Run tests")
        XCTAssertEqual(batch.inputs, [.init(title: "Task 1", text: "Inspect files"), .init(title: "Task 2", text: "Run tests")])
        let shell = ToolPresentation(name: "shell", arguments: #"{"command":"swift test","description":"Run checks"}"#, descriptiveShellTitles: true)
        XCTAssertEqual(shell.title, "Shell")
        XCTAssertEqual(shell.summary, "Run checks")
        XCTAssertEqual(shell.inputs, [.init(title: "Command", text: "swift test")])
    }

    func testUnknownToolFallbackKeepsRawNameArgumentsAndResult() {
        let name = "future_tool"
        let metadata = ToolDisplayMetadata(name: name)
        XCTAssertEqual(metadata.name, name)
        XCTAssertEqual(metadata.label, name)
        XCTAssertEqual(metadata.transcriptTitle, name)
        XCTAssertEqual(metadata.icon, "wrench")
        let card = ToolPresentation(name: name, arguments: "{invalid", result: .init(text: "Exact result", outcome: "denied"))
        XCTAssertEqual(card.title, name)
        XCTAssertEqual(card.icon, metadata.icon)
        XCTAssertEqual(card.inputs, [.init(title: "Arguments", text: "{invalid")])
        XCTAssertEqual(card.output, "Exact result")
        XCTAssertEqual(card.detail, "Denied")
        XCTAssertFalse(ToolDisplayMetadata.all.contains { $0.name == name })
    }
}
