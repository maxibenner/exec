import Foundation

/// Only a leading, single-line command is interpreted locally. Paths and prose stay drafts.
struct ComposerCommand: Equatable {
    enum Page: String, CaseIterable {
        case model, effort, approve, compact

        var names: [String] {
            switch self {
            case .model: ["model"]
            case .effort: ["reasoning", "effort"]
            case .approve: ["auto-approve", "approve", "approval"]
            case .compact: ["compact"]
            }
        }
        var hasOptions: Bool { self == .model || self == .effort }
        var commandName: String { names[0] }
        func matches(_ query: String) -> Bool { names.contains { $0.hasPrefix(query.lowercased()) } }
    }
    let page: Page?
    let query: String

    init?(_ draft: String) {
        guard draft.hasPrefix("/"), !draft.contains("\n"), !draft.contains("\r") else { return nil }
        let text = String(draft.dropFirst())
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts.first ?? "").lowercased()
        if let page = Page.allCases.first(where: { $0.names.contains(name) }) {
            self.page = page
            query = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        } else {
            guard parts.count == 1, Page.allCases.contains(where: { $0.matches(name) }) else { return nil }
            page = nil
            query = name
        }
    }
}
