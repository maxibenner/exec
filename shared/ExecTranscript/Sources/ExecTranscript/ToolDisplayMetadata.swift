/// Shared display metadata, not a source of runtime capabilities or approval policy.
/// Selector labels stay distinct from the shorter, sometimes dynamic transcript titles.
public struct ToolDisplayMetadata: Equatable, Identifiable, Sendable {
    public let name: String
    public let label: String
    public let icon: String
    public let transcriptTitle: String
    public var id: String { name }

    /// Unknown tools keep their exact wire name visible without inventing a label.
    public init(name: String) {
        self = Self.all.first { $0.name == name }
            ?? Self(name: name, label: name, icon: "wrench")
    }

    private init(name: String, label: String, icon: String, transcriptTitle: String? = nil) {
        self.name = name
        self.label = label
        self.icon = icon
        self.transcriptTitle = transcriptTitle ?? label
    }

    /// Preserve the existing client selector order. Availability remains host-owned.
    public static let all: [ToolDisplayMetadata] = [
        .init(name: "list_files", label: "List files", icon: "folder", transcriptTitle: "List"),
        .init(name: "read_file", label: "Read file", icon: "doc.text", transcriptTitle: "Read"),
        .init(name: "search_text", label: "Search text", icon: "magnifyingglass", transcriptTitle: "Search"),
        .init(name: "edit_file", label: "Edit file", icon: "pencil", transcriptTitle: "Edit"),
        .init(name: "shell", label: "Run shell command", icon: "terminal", transcriptTitle: "Shell"),
        .init(name: "web_search", label: "Search the web", icon: "globe", transcriptTitle: "Web search"),
        .init(name: "fetch_content", label: "Fetch web page", icon: "doc.text", transcriptTitle: "Fetch page"),
        .init(name: "generate_image", label: "Generate image", icon: "photo"),
        .init(name: "take_screenshot", label: "Take screenshot", icon: "camera", transcriptTitle: "Screenshot"),
        .init(name: "delegate", label: "Delegate to sub-agents", icon: "person.2", transcriptTitle: "Sub-agent"),
        .init(name: "wait", label: "Wait", icon: "stopwatch")
    ]
}
