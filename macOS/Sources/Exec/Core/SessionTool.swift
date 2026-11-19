#if canImport(ExecTranscript)
import ExecTranscript
#endif

/// Callable tools shared by session controls. Groups describe capabilities, not approval policy.
struct SessionTool: Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case read = "Read"
        case write = "Write"
        case sensitive = "Sensitive"
    }

    let name: String
    let group: Group

    var label: String { ToolDisplayMetadata(name: name).label }
    var icon: String { ToolDisplayMetadata(name: name).icon }
    var id: String { name }

    // Keep capability groups and the existing callable-name order local; display
    // metadata is shared with iOS selectors, approvals and both transcripts.
    static let all: [SessionTool] = [
        .init(name: "list_files", group: .read),
        .init(name: "read_file", group: .read),
        .init(name: "search_text", group: .read),
        .init(name: "edit_file", group: .write),
        .init(name: "shell", group: .sensitive),
        .init(name: "web_search", group: .read),
        .init(name: "fetch_content", group: .read),
        .init(name: "generate_image", group: .write),
        .init(name: "take_screenshot", group: .sensitive),
        .init(name: "delegate", group: .sensitive),
        .init(name: "wait", group: .read)
    ]

    static let names = all.map(\.name)
}
