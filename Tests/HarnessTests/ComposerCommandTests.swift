import Foundation

struct ComposerCommandTests {
    func recognizesOnlyLeadingCommands() throws {
        let root = try unwrap(ComposerCommand("/"))
        try expect(root.page == nil && root.query.isEmpty)
        let partial = try unwrap(ComposerCommand("/app"))
        try expect(partial.page == nil && partial.query == "app")
        let model = try unwrap(ComposerCommand("/model gpt"))
        try expect(model.page == .model && model.query == "gpt")
        let effort = try unwrap(ComposerCommand("/effort"))
        try expect(effort.page == .effort && effort.query.isEmpty)
        let approve = try unwrap(ComposerCommand("/approve off"))
        try expect(approve.page == .approve && approve.query == "off")
        for draft in ["", "hello /model", " /model", "/Users/me/project", "/model/file", "/tmp", "/unknown", "/m prose", "/model\nhello", "/approve\roff"] {
            try expect(ComposerCommand(draft) == nil)
        }
    }

    private func unwrap(_ command: ComposerCommand?) throws -> ComposerCommand {
        guard let command else { throw CheckFailure(description: "Expected a composer command") }
        return command
    }
}
