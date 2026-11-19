import XCTest
import ExecTranscript
@testable import ExecRemote

final class RemoteSessionCreationTests: XCTestCase {
    func testToolSelectionUsesSharedMacAndTranscriptDisplayMetadata() {
        XCTAssertEqual(RemoteSessionCreation.tools.map(\.id), [
            "list_files", "read_file", "search_text", "edit_file", "shell",
            "web_search", "fetch_content", "generate_image", "take_screenshot", "delegate", "wait"
        ])
        XCTAssertEqual(RemoteSessionCreation.tools, ToolDisplayMetadata.all)
        for tool in RemoteSessionCreation.tools {
            // The iOS approval disclosure looks up this same metadata by wire name.
            let approval = ToolDisplayMetadata(name: tool.id)
            let transcript = ToolPresentation(name: tool.id, arguments: "{}")
            XCTAssertEqual(tool.label, approval.label)
            XCTAssertEqual(tool.icon, approval.icon)
            XCTAssertEqual(tool.icon, transcript.icon)
            XCTAssertEqual(approval.transcriptTitle, transcript.title)
        }
        var selection = RemoteSessionCreation.ToolSelection(library: .null)
        selection.setEnabled("future_tool", true)
        XCTAssertFalse(selection.isEnabled("future_tool"), "A display fallback must not grant availability.")
        XCTAssertNil(selection.creationDisabledTools)
    }
    private let model: RemoteJSON = .object([
        "id": .string("fixture/reasoning"), "defaultEffort": .string("high"),
        "efforts": .array([.object(["id": .string("high"), "name": .string("High")])])
    ])
    private let settings: RemoteJSON = .object([
        "systemPrompt": .string("Synthetic instructions"), "autoApprove": .bool(false),
        "effort": .string("high"), "searchModel": .string("fixture/search")
    ])

    private func library(_ disabled: [String]) -> RemoteJSON {
        .object(["defaultDisabledTools": .array(disabled.map(RemoteJSON.string)), "settings": settings])
    }
    private func body(_ tools: RemoteSessionCreation.ToolSelection) -> RemoteJSON {
        RemoteSessionCreation.body(workspace: "/Fixture/Workspace", model: model, effort: "high",
                                   settings: settings, tools: tools)
    }
    private func assertInherits(_ value: RemoteJSON, file: StaticString = #filePath, line: UInt = #line) {
        guard case .object(let fields) = value else { return XCTFail("Expected create object", file: file, line: line) }
        XCTAssertNil(fields["disabledTools"], "Inheritance requires omission, not null or []", file: file, line: line)
    }

    func testMissingLegacyDefaultsDisableOnlyShellAndKeepBackendInheritance() {
        let tools = RemoteSessionCreation.ToolSelection(library: .object([:]))
        XCTAssertEqual(tools.disabledTools, ["shell"])
        for tool in RemoteSessionCreation.tools {
            XCTAssertEqual(tools.isEnabled(tool.id), tool.id != "shell")
        }
        assertInherits(body(tools))
        assertInherits(RemoteSessionCreation.body(workspace: "/Fixture/Workspace", model: model,
                                                  effort: "high", settings: settings))
    }

    func testExplicitEmptyDefaultsEnableAllAndCanDisableOneToolPerSession() {
        var tools = RemoteSessionCreation.ToolSelection(library: library([]))
        XCTAssertTrue(RemoteSessionCreation.tools.allSatisfy { tools.isEnabled($0.id) })
        assertInherits(body(tools))
        tools.setEnabled("shell", false)
        let create = body(tools)
        XCTAssertEqual(create["disabledTools"], .array([.string("shell")]))
        XCTAssertEqual(create["settings"], settings)
        XCTAssertEqual(create["settings"]["disabledTools"], .null)
    }

    func testEnablingDefaultDisabledToolSendsExplicitEmptyArrayAndPreservesSharedSettings() {
        let defaults = library(["shell"])
        var tools = RemoteSessionCreation.ToolSelection(library: defaults)
        tools.setEnabled("shell", true)
        let create = body(tools)
        XCTAssertEqual(create["disabledTools"], .array([]))
        XCTAssertEqual(create["workspace"], .string("/Fixture/Workspace"))
        XCTAssertEqual(create["model"], model["id"])
        XCTAssertEqual(create["settings"], defaults["settings"])
        XCTAssertEqual(defaults, library(["shell"]))
        XCTAssertFalse(RemoteSessionCreation.ToolSelection(library: defaults).isEnabled("shell"))
    }

    func testUnavailableDefaultsAreInheritedUntilEditedThenOnlySupportedNamesAreSent() {
        let defaults = library(["temporarily_unavailable", "shell"])
        var tools = RemoteSessionCreation.ToolSelection(library: defaults, supportedTools: ["shell", "read_file", "read_file"])
        assertInherits(body(tools))
        tools.setEnabled("temporarily_unavailable", false)
        tools.setEnabled("unknown", false)
        assertInherits(body(tools))
        tools.setEnabled("read_file", false)
        XCTAssertEqual(body(tools)["disabledTools"], .array([.string("read_file"), .string("shell")]))
        XCTAssertFalse(tools.isEnabled("unknown"))
        XCTAssertEqual(defaults, library(["temporarily_unavailable", "shell"]))
    }

    func testRevertingSelectionRestoresOmissionIncludingWithUnavailableDefaults() {
        var tools = RemoteSessionCreation.ToolSelection(library: library(["shell", "future_tool"]))
        tools.setEnabled("shell", true)
        XCTAssertEqual(body(tools)["disabledTools"], .array([]))
        tools.setEnabled("read_file", false)
        XCTAssertEqual(body(tools)["disabledTools"], .array([.string("read_file")]))
        tools.setEnabled("read_file", true)
        tools.setEnabled("shell", false)
        assertInherits(body(tools))
    }

    func testSeparateSessionDraftsDoNotShareToolEdits() {
        let first = RemoteSessionCreation.ToolSelection(library: library(["shell"]))
        var second = first
        second.setEnabled("edit_file", false)
        second.setEnabled("shell", true)
        assertInherits(body(first))
        XCTAssertEqual(body(second)["disabledTools"], .array([.string("edit_file")]))
        XCTAssertEqual(first.disabledTools, ["shell"])
    }
}
