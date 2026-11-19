#if canImport(ExecTranscript)
import ExecTranscript
#endif

/// Callable tools shared by session controls. Groups describe capabilities, not approval policy.
struct SessionTool: Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case inspect = "Inspect"
        case modify = "Modify"
        case execute = "Execute"
    }

    let name: String
    // Orchestration tools have no user-facing group but retain their persisted names.
    let group: Group?

    var label: String { ToolDisplayMetadata(name: name).label }
    var icon: String { ToolDisplayMetadata(name: name).icon }
    var id: String { name }

    // Keep capability groups and the existing callable-name order local; display
    // metadata is shared with iOS selectors, approvals and both transcripts.
    static let all: [SessionTool] = [
        .init(name: "list_files", group: .inspect),
        .init(name: "read_file", group: .inspect),
        .init(name: "search_text", group: .inspect),
        .init(name: "edit_file", group: .modify),
        .init(name: "shell", group: .execute),
        .init(name: "web_search", group: .inspect),
        .init(name: "fetch_content", group: .inspect),
        .init(name: "generate_image", group: .modify),
        .init(name: "take_screenshot", group: .inspect),
        .init(name: "delegate", group: nil),
        .init(name: "wait", group: nil)
    ]

    static let names = all.map(\.name)
}
