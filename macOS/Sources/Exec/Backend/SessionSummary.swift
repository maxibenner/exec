import Foundation

struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var customTitle: String?
    var isTitleManuallySet: Bool?
    let workspace: String?
    let updatedAt: Date
    var unreadable = false
    let parent: AgentSessionParent?
    let operationState: String?
    var awaitingApproval: Bool { operationState == "awaiting_approval" }
    var isRunning: Bool { ["running", "awaiting_approval", "cancelling"].contains(operationState ?? "") }

    init(_ value: AgentJSON) throws {
        guard let raw = value["id"].string, let id = UUID(uuidString: raw) else { throw ExecError("The backend returned an invalid conversation ID.") }
        self.id = id
        unreadable = value["unreadable"].bool
        let metadata = value["metadata"]
        parent = metadata["parent"] == .null ? nil : try metadata["parent"].decoded(AgentSessionParent.self)
        operationState = value["operation"]["state"].string
        title = unreadable ? "Unreadable conversation" : metadata["title"].string ?? "Untitled"
        customTitle = metadata["title"].string
        isTitleManuallySet = metadata["manuallyNamed"].bool
        workspace = value["workspace"].string
        updatedAt = Date(timeIntervalSince1970: (metadata["activityAt"].number ?? 0) / 1000)
    }
    init(snapshot: AgentSnapshot) {
        id = snapshot.id
        parent = snapshot.metadata.parent
        operationState = snapshot.operation?.state
        title = snapshot.metadata.title ?? "Untitled"
        customTitle = snapshot.metadata.title
        isTitleManuallySet = snapshot.metadata.manuallyNamed
        workspace = snapshot.workspace
        updatedAt = Date(timeIntervalSince1970: snapshot.metadata.activityAt / 1000)
    }
}
