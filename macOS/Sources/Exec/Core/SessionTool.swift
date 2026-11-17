/// Callable tools shared by session controls. Groups describe capabilities, not approval policy.
struct SessionTool: Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case read = "Read"
        case write = "Write"
        case sensitive = "Sensitive"
    }

    let name: String
    let label: String
    let icon: String
    let group: Group

    var id: String { name }

    // Match the transcript's ToolPresentation symbols without coupling core metadata
    // to its argument/result rendering. Keep the existing callable-name order.
    static let all: [SessionTool] = [
        .init(name: "list_files", label: "List files", icon: "folder", group: .read),
        .init(name: "read_file", label: "Read file", icon: "doc.text", group: .read),
        .init(name: "search_text", label: "Search text", icon: "magnifyingglass", group: .read),
        .init(name: "edit_file", label: "Edit file", icon: "pencil", group: .write),
        .init(name: "shell", label: "Run shell command", icon: "terminal", group: .sensitive),
        .init(name: "web_search", label: "Search the web", icon: "globe", group: .read),
        .init(name: "fetch_content", label: "Fetch web page", icon: "doc.text", group: .read),
        .init(name: "generate_image", label: "Generate image", icon: "photo", group: .write),
        .init(name: "take_screenshot", label: "Take screenshot", icon: "camera", group: .sensitive),
        .init(name: "delegate", label: "Delegate to sub-agents", icon: "person.2", group: .sensitive),
        .init(name: "wait", label: "Wait", icon: "stopwatch", group: .read)
    ]

    static let names = all.map(\.name)
}
