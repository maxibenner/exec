import Foundation

struct SessionSummary: Identifiable, Sendable {
    let id: UUID
    var title: String
    var customTitle: String?
    var isTitleManuallySet: Bool?
    let workspace: String?
    let updatedAt: Date
    var unreadable = false
    var isLocalDraft = false

    init(localDraft id: UUID, workspace: String?) {
        self.id = id
        title = "Unsent draft"
        self.workspace = workspace
        updatedAt = .now
        isLocalDraft = true
    }

    init(_ value: AgentJSON) throws {
        guard let raw = value["id"].string, let id = UUID(uuidString: raw) else { throw ExecError("The backend returned an invalid conversation ID.") }
        self.id = id
        unreadable = value["unreadable"].bool
        let metadata = value["metadata"]
        title = unreadable ? "Unreadable conversation" : metadata["title"].string ?? "Untitled"
        customTitle = metadata["title"].string
        isTitleManuallySet = metadata["manuallyNamed"].bool
        workspace = value["workspace"].string
        updatedAt = Date(timeIntervalSince1970: (metadata["activityAt"].number ?? 0) / 1000)
    }
    init(snapshot: AgentSnapshot) {
        id = snapshot.id
        title = snapshot.metadata.title ?? "Untitled"
        customTitle = snapshot.metadata.title
        isTitleManuallySet = snapshot.metadata.manuallyNamed
        workspace = snapshot.workspace
        updatedAt = Date(timeIntervalSince1970: snapshot.metadata.activityAt / 1000)
    }
}
