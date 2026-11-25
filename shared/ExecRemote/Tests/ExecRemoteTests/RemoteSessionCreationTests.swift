import XCTest
import ExecTranscript
@testable import ExecRemote

final class RemoteSessionCreationTests: XCTestCase {
    func testCreationToolsFollowVisibleMacOrderWithSharedLabelsAndIcons() {
        XCTAssertEqual(RemoteSessionCreation.tools.map(\.id), [
            "list_files", "read_file", "search_text", "web_search", "fetch_content", "take_screenshot",
            "edit_file", "generate_image", "shell"
        ])
        XCTAssertEqual(RemoteSessionCreation.tools.count, 9)
        XCTAssertFalse(RemoteSessionCreation.tools.contains { ["delegate", "wait"].contains($0.id) })
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

    func testMissingOrNullLegacyDefaultsDisableOnlyShellAndKeepBackendInheritance() {
        let libraries: [RemoteJSON] = [.null, .object([:]), .object(["defaultDisabledTools": .null])]
        for library in libraries {
            let tools = RemoteSessionCreation.ToolSelection(library: library)
            XCTAssertEqual(tools.disabledTools, ["shell"])
            for tool in RemoteSessionCreation.tools {
                XCTAssertEqual(tools.isEnabled(tool.id), tool.id != "shell")
            }
            assertInherits(body(tools))
        }
        assertInherits(RemoteSessionCreation.body(workspace: "/Fixture/Workspace", model: model,
                                                  effort: "high", settings: settings, tools: nil))
    }

    func testOrchestrationCannotBeDisabledEvenWhenExplicitlySupportedAndDisabledByHost() {
        let defaults = library(["delegate", "wait"])
        for supported in [RemoteSessionCreation.tools.map(\.id), ["delegate", "wait", "shell"]] {
            var tools = RemoteSessionCreation.ToolSelection(library: defaults, supportedTools: supported)
            for name in ["delegate", "wait"] {
                XCTAssertTrue(tools.isEnabled(name))
                tools.setEnabled(name, false)
                XCTAssertTrue(tools.isEnabled(name))
                tools.setEnabled(name, true)
            }
            XCTAssertEqual(tools.disabledTools, [])
            XCTAssertEqual(body(tools)["disabledTools"], .array([]))
            XCTAssertEqual(body(tools)["settings"], settings)
        }
        XCTAssertEqual(defaults, library(["delegate", "wait"]))
    }

    func testUntouchedOrchestrationOverridePreservesOtherInheritedNamesAndSettings() {
        let defaults = library(["wait", "temporarily_unavailable", "shell", "delegate", "future_tool", "read_file"])
        var tools = RemoteSessionCreation.ToolSelection(library: defaults, supportedTools: ["shell", "read_file"])
        let expected: RemoteJSON = .array(["future_tool", "read_file", "shell", "temporarily_unavailable"].map(RemoteJSON.string))
        XCTAssertEqual(tools.disabledTools, ["read_file", "shell"])
        XCTAssertEqual(body(tools)["disabledTools"], expected)
        XCTAssertEqual(body(tools)["settings"], defaults["settings"])
        for name in ["delegate", "wait", "future_tool", "temporarily_unavailable", "unknown"] {
            tools.setEnabled(name, false)
        }
        XCTAssertEqual(body(tools)["disabledTools"], expected, "Hidden and unavailable edits cannot change the draft.")
        XCTAssertEqual(defaults, library(["wait", "temporarily_unavailable", "shell", "delegate", "future_tool", "read_file"]))
    }

    func testVisibleEditsAfterOrchestrationOverrideSendOnlySupportedNamesIncludingEmptyArray() {
        var tools = RemoteSessionCreation.ToolSelection(library: library(["delegate", "wait", "shell", "future_tool"]))
        tools.setEnabled("read_file", false)
        XCTAssertEqual(body(tools)["disabledTools"], .array([.string("read_file"), .string("shell")]))
        tools.setEnabled("shell", true)
        XCTAssertEqual(body(tools)["disabledTools"], .array([.string("read_file")]))
        tools.setEnabled("read_file", true)
        XCTAssertEqual(body(tools)["disabledTools"], .array([]))
        tools.setEnabled("shell", false)
        XCTAssertEqual(body(tools)["disabledTools"], .array([.string("future_tool"), .string("shell")]),
                       "Reverting visible edits restores the sanitized inheritance override, not omission.")
        XCTAssertEqual(body(tools)["settings"], settings)
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

    func testAvailabilityQueryMatchesExactCreationModelAndSearchOverrideWithoutProviderInference() {
        let models: [RemoteJSON] = [model, .object(["id": .string("other/provider-model")])]
        let settingsCases: [RemoteJSON] = [settings, .object([:]), .object(["searchModel": .null]),
                                            .object(["searchModel": .string("")]), .null]
        for model in models {
            for settings in settingsCases {
                let create = RemoteSessionCreation.body(workspace: "/Fixture", model: model, effort: "", settings: settings)
                let query = RemoteSessionCreation.AvailabilityQuery(model: model, settings: settings)
                XCTAssertEqual(query.body["model"], create["model"])
                XCTAssertEqual(query.body["searchModel"], create["settings"]["searchModel"])
                XCTAssertEqual(query.body["names"], .array(RemoteSessionCreation.tools.map { .string($0.id) }))
                XCTAssertEqual(query.body["captureFrontendID"], .null)
                XCTAssertEqual(query.body["conversationID"], .null)
                XCTAssertEqual(query.body["remote_client"], .null, "Remote context belongs to the host route, not client provider logic")
            }
        }
    }

    func testAvailabilityUsesOnlyExplicitBooleansAndIgnoresReasonsAndUnknownNames() {
        let statuses = RemoteSessionCreation.availabilityStatuses(.object([
            "shell": .object(["available": .bool(false), "reason": .string("Synthetic unavailable reason")]),
            "read_file": .object(["available": .bool(true)]),
            "generate_image": .object(["available": .string("true")]),
            "web_search": .object(["reason": .string("No status")]),
            "delegate": .object(["available": .bool(true)]),
            "future_tool": .object(["available": .bool(true)])
        ]))
        XCTAssertEqual(statuses, ["shell": false, "read_file": true])
        XCTAssertEqual(RemoteSessionCreation.availabilityStatuses(.null), [:])
        XCTAssertEqual(RemoteSessionCreation.availabilityStatuses(.object([:])), [:])
    }

    func testAvailabilityRefreshesDoNotChangeInheritedCheckStateOrEditedCreationBody() {
        let defaults = library(["shell", "future_tool"])
        var tools = RemoteSessionCreation.ToolSelection(library: defaults)
        let inherited = body(tools)
        XCTAssertTrue(tools.isEnabled("take_screenshot"))
        XCTAssertFalse(tools.isEnabled("shell"))
        for available in [false, true, false] {
            _ = RemoteSessionCreation.availabilityStatuses(.object([
                "shell": .object(["available": .bool(available)]),
                "take_screenshot": .object(["available": .bool(available)])
            ]))
            XCTAssertEqual(body(tools), inherited)
            XCTAssertNil(tools.creationDisabledTools)
        }
        tools.setEnabled("shell", true)
        tools.setEnabled("read_file", false)
        let edited = body(tools)
        _ = RemoteSessionCreation.availabilityStatuses(.object([:]))
        XCTAssertEqual(body(tools), edited)
        XCTAssertEqual(edited["disabledTools"], .array([.string("read_file")]))
        XCTAssertEqual(edited["settings"], settings)
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
