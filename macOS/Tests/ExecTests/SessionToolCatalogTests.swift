struct SessionToolCatalogTests {
    func preservesNamesGroupsAndTranscriptIcons() throws {
        try expect(SessionTool.names == [
            "list_files", "read_file", "search_text", "edit_file", "shell",
            "web_search", "fetch_content", "generate_image", "take_screenshot", "delegate", "wait"
        ])
        try expect(Set(SessionTool.all.map(\.id)).count == SessionTool.names.count)
        try expect(SessionTool.Group.allCases == [.read, .write, .sensitive])
        try expect(SessionTool.all.filter { $0.group == .read }.map(\.name) == [
            "list_files", "read_file", "search_text", "web_search", "fetch_content", "wait"
        ])
        try expect(SessionTool.all.filter { $0.group == .write }.map(\.name) == [
            "edit_file", "generate_image"
        ])
        try expect(SessionTool.all.filter { $0.group == .sensitive }.map(\.name) == [
            "shell", "take_screenshot", "delegate"
        ])
        try expect(SessionTool.names == RemoteSessionCreation.tools.map(\.id))
        for (tool, remote) in zip(SessionTool.all, RemoteSessionCreation.tools) {
            let metadata = ToolDisplayMetadata(name: tool.name)
            try expect(!tool.label.isEmpty && !tool.label.contains("_"))
            try expect(tool.label == metadata.label && tool.label == remote.label)
            try expect(tool.icon == metadata.icon && tool.icon == remote.icon)
            try expect(tool.icon == ToolPresentation(name: tool.name, arguments: "{}").icon)
        }
    }
}
