import ExecTranscript

struct SessionToolCatalogTests {
    func preservesNamesGroupsAndTranscriptIcons() throws {
        try expect(SessionTool.names == [
            "list_files", "read_file", "search_text", "edit_file", "shell",
            "web_search", "fetch_content", "generate_image", "take_screenshot", "delegate", "wait"
        ])
        try expect(Set(SessionTool.all.map(\.id)).count == SessionTool.names.count)
        try expect(SessionTool.Group.allCases == [.inspect, .modify, .execute])
        try expect(SessionTool.all.filter { $0.group == .inspect }.map(\.name) == [
            "list_files", "read_file", "search_text", "web_search", "fetch_content", "take_screenshot"
        ])
        try expect(SessionTool.all.filter { $0.group == .modify }.map(\.name) == [
            "edit_file", "generate_image"
        ])
        try expect(SessionTool.all.filter { $0.group == .execute }.map(\.name) == [
            "shell"
        ])
        try expect(SessionTool.all.filter { $0.group == nil }.map(\.name) == [
            "delegate", "wait"
        ])
        let visible = SessionTool.Group.allCases.flatMap { group in
            SessionTool.all.filter { $0.group == group }
        }
        try expect(visible.map(\.name) == [
            "list_files", "read_file", "search_text", "web_search", "fetch_content", "take_screenshot",
            "edit_file", "generate_image", "shell"
        ])
        try expect(visible.map(\.name) == RemoteSessionCreation.tools.map(\.id))
        try expect(SessionTool.names == ToolDisplayMetadata.all.map(\.id))
        for tool in SessionTool.all {
            let metadata = ToolDisplayMetadata(name: tool.name)
            try expect(!tool.label.isEmpty && !tool.label.contains("_"))
            try expect(tool.label == metadata.label)
            try expect(tool.icon == metadata.icon)
            try expect(tool.icon == ToolPresentation(name: tool.name, arguments: "{}").icon)
        }
        for (tool, remote) in zip(visible, RemoteSessionCreation.tools) {
            try expect(tool.label == remote.label && tool.icon == remote.icon)
        }
    }
}
