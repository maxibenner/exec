import SwiftUI
import XCTest
@testable import ExecTranscript

final class DelegationPresentationTests: XCTestCase {
    @MainActor func testPartialResultsUseExistingBodyWithoutSettlingTheCard() {
        let arguments = #"{"tasks":[{"task":"Inspect parser","title":"Parser"},{"task":"Inspect tests","title":"Tests"}]}"#
        let partial = "Task 2\nChild session: child-2\n\nTests cover cancellation."
        let combined = "Task 1\nChild session: child-1\n\nParser result.\n\n" + partial
        for (text, outcome) in [(partial, "running"), (combined, "running"), (combined, "completed")] {
            let presentation = ToolPresentation(name: "delegate", arguments: arguments, result: .init(text: text, outcome: outcome))
            XCTAssertEqual(presentation.title, "Sub-agents")
            XCTAssertEqual(presentation.summary, "Parser · Tests")
            XCTAssertEqual(presentation.inputs, [.init(title: "Task 1", text: "Inspect parser"), .init(title: "Task 2", text: "Inspect tests")])
            XCTAssertEqual(presentation.outputTitle, "Result")
            XCTAssertEqual(presentation.output, text)
            XCTAssertNil(presentation.detail)
            XCTAssertEqual(presentation.isRunning, outcome == "running")
            // Owners that only map text/outcome still get the existing activity
            // indicator; passing result != nil must not make a partial terminal.
            let card = ToolCard(presentation: presentation, isExpanded: .constant(true), isRunning: false) { EmptyView() }
            XCTAssertEqual(card.isRunning, outcome == "running")
        }
        let settled = ToolPresentation(name: "delegate", arguments: arguments, result: .init(text: combined, outcome: "failed"))
        XCTAssertEqual(settled.detail, "Error")
        XCTAssertFalse(settled.isRunning)
        let cleanup = ToolCard(presentation: settled, isExpanded: .constant(true), isRunning: true) { EmptyView() }
        XCTAssertTrue(cleanup.isRunning) // Explicit executor ownership survives result publication.
    }

    func testChildFailureTextDoesNotBecomeTheRunningDelegatesTerminalStatus() {
        for text in ["Tool error: child failed.", "Interrupted. Child cancelled."] {
            let partial = ToolPresentation(name: "delegate", arguments: #"{"task":"Review parser"}"#,
                                           result: .init(text: text, outcome: "running"))
            XCTAssertTrue(partial.isRunning)
            XCTAssertNil(partial.detail)
            XCTAssertEqual(partial.output, text)
        }
        let interrupted = ToolPresentation(name: "delegate", arguments: #"{"task":"Review parser"}"#,
                                           result: .init(text: "Saved child result", outcome: "interrupted"))
        XCTAssertFalse(interrupted.isRunning)
        XCTAssertEqual(interrupted.detail, "Interrupted")
        XCTAssertEqual(interrupted.output, "Saved child result")
    }
}
