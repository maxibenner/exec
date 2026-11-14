/// Presentation-only result metadata. Agent execution and provider formats do
/// not belong in the shared transcript components.
public struct ToolDisplayResult: Sendable {
    public let text: String
    public let outcome: String?
    public let editPath: String?
    public let searchQuery: String?
    public let pageText: String?
    public let legacyInterrupted: Bool
    public init(text: String, outcome: String? = nil, editPath: String? = nil,
                searchQuery: String? = nil, pageText: String? = nil, legacyInterrupted: Bool = false) {
        self.text = text; self.outcome = outcome; self.editPath = editPath
        self.searchQuery = searchQuery; self.pageText = pageText; self.legacyInterrupted = legacyInterrupted
    }
}
