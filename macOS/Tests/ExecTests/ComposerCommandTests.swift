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
        for page in ComposerCommand.Page.allCases {
            for name in page.names {
                for length in 0..<name.count {
                    let prefix = String(name.prefix(length))
                    let command = try unwrap(ComposerCommand("/" + prefix))
                    try expect(command.page == nil || command.page == page)
                    try expect(page.matches(command.query))
                }
                try expect(ComposerCommand("/" + name)?.page == page)
                let filtered = try unwrap(ComposerCommand("/" + name + " high"))
                try expect(filtered.page == page && filtered.query == "high")
            }
        }
        try expect(ComposerCommand.Page.effort.matches("r"))
        try expect(ComposerCommand.Page.approve.matches("auto"))
        try expect(ComposerCommand("/compact")?.page == .compact)
        try expect(!ComposerCommand.Page.approve.hasOptions && !ComposerCommand.Page.compact.hasOptions)
        try expect(ComposerCommand.Page.model.hasOptions && ComposerCommand.Page.effort.hasOptions)
        let approve = try unwrap(ComposerCommand("/approve off"))
        try expect(approve.page == .approve && approve.query == "off")
        for draft in ["/clear", "/CLEAR", "/clear   "] {
            let clear = try unwrap(ComposerCommand(draft))
            try expect(clear.page == .clear && clear.query.isEmpty)
        }
        let clearPrefix = try unwrap(ComposerCommand("/cl"))
        try expect(clearPrefix.page == nil && clearPrefix.query == "cl" && ComposerCommand.Page.clear.matches(clearPrefix.query))
        try expect(!ComposerCommand.Page.clear.hasOptions)
        try expect(!ComposerCommand.Page.allCases.flatMap(\.names).contains("workspace"))
        for draft in ["", "hello /model", " /model", "/Users/me/project", "/model/file", "/tmp", "/unknown", "/m prose", "/model\nhello", "/approve\roff",
                      "/workspace", "/workspace /tmp", "/work", " /clear", "hello /clear", "/clear/file", "/clear\nhello", "/clear\rhello", "/cl prose"] {
            try expect(ComposerCommand(draft) == nil)
        }
    }

    private func unwrap(_ command: ComposerCommand?) throws -> ComposerCommand {
        guard let command else { throw CheckFailure(description: "Expected a composer command") }
        return command
    }
}
