struct SessionToolCatalogTests {
    func preservesNamesGroupsAndTranscriptIcons() throws {
        try expect(SessionTool.names == [
            "list_files", "read_file", "search_text", "edit_file", "shell",
            "web_search", "fetch_content", "generate_image", "take_screenshot", "delegate"
        ])
        try expect(Set(SessionTool.all.map(\.id)).count == SessionTool.names.count)
        try expect(SessionTool.Group.allCases == [.read, .write, .sensitive])
        try expect(SessionTool.all.filter { $0.group == .read }.map(\.name) == [
            "list_files", "read_file", "search_text", "web_search", "fetch_content"
        ])
        try expect(SessionTool.all.filter { $0.group == .write }.map(\.name) == [
            "edit_file", "generate_image"
        ])
        try expect(SessionTool.all.filter { $0.group == .sensitive }.map(\.name) == [
            "shell", "take_screenshot", "delegate"
        ])
        for tool in SessionTool.all {
            try expect(!tool.label.isEmpty && !tool.label.contains("_"))
            try expect(tool.icon == ToolPresentation(name: tool.name, arguments: "{}").icon)
        }
    }
}
