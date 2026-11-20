import Foundation
import ExecRemote

/// A table item is either one message or a contiguous run of tools. Calls keep
/// their own identities even though UIKit measures the entire run in one host.
struct TranscriptItem: Equatable {
    let rows: [RemoteTranscriptRow]
    var isQueued = false
    var id: String { rows[0].id }
    var isToolGroup: Bool { rows[0].call != nil }

    // Queue projection lives here, not in ConversationPresentation or a cache.
    // It works without a snapshot and disappears immediately on expiry/cancel.
    static func project(_ snapshot: RemoteJSON, queuedMessage: RemoteJSON = .null) -> [Self] {
        let queuedID = queuedMessage["id"].string
        let rows = RemoteTranscriptRow.project(snapshot) + RemoteTranscriptRow.project(
            .object(["pendingInput": .array(queuedID == nil ? [] : [queuedMessage])]))
        var items: [Self] = []
        var tools: [RemoteTranscriptRow] = []
        var seen: Set<String> = []
        for row in rows where !row.id.isEmpty && seen.insert(row.id).inserted {
            if row.call != nil {
                tools.append(row)
            } else {
                if !tools.isEmpty { items.append(Self(rows: tools)); tools = [] }
                items.append(Self(rows: [row], isQueued: row.id == queuedID))
            }
        }
        if !tools.isEmpty { items.append(Self(rows: tools)) }
        return items
    }
}

/// Only reader input changes follow intent. Geometry, keyboard changes and
/// delayed self-sizing must never infer permission to return to the latest row.
struct TranscriptScrollState {
    enum Intent: Equatable { case latest, turn(String), reading }
    private(set) var intent: Intent = .latest
    private(set) var reservedTurnID: String?
    private var previousIDs: Set<String> = []
    private var lastUserID: String?
    private var initialized = false

    /// Returns true only for a newly delivered user turn, not a history page,
    /// cached initial snapshot, or acknowledgement of an optimistic local row.
    mutating func update(rows: [RemoteTranscriptRow]) -> Bool {
        let ids = Set(rows.map(\.id))
        let user = rows.last { $0.message["role"].string == "user" }
        let appended = initialized && (previousIDs.isEmpty || !previousIDs.isDisjoint(with: ids))
        let isNewUser = appended && user.map { $0.id != lastUserID && !previousIDs.contains($0.id) } == true
        let shouldFollow = isNewUser && user.map { intent != .reading || $0.id.hasPrefix("local-") } == true
        if shouldFollow, let user {
            intent = .turn(user.id)
            reservedTurnID = user.id
        } else if let reservedTurnID, !ids.contains(reservedTurnID) {
            self.reservedTurnID = nil
            if case .turn = intent { intent = .latest }
        }
        previousIDs = ids
        lastUserID = user?.id
        initialized = true
        return shouldFollow
    }

    /// Explicit local input also pins when a cold page has no history baseline.
    mutating func submitted(_ rowID: String) {
        intent = .turn(rowID)
        reservedTurnID = rowID
    }

    /// Reopening adopts the current cached history without replaying messages
    /// received while hidden as a newly sent turn.
    mutating func restoreRows(_ rows: [RemoteTranscriptRow]) {
        previousIDs = Set(rows.map(\.id))
        lastUserID = rows.last { $0.message["role"].string == "user" }?.id
        initialized = true
        if let reservedTurnID, !previousIDs.contains(reservedTurnID) {
            self.reservedTurnID = nil
            if case .turn = intent { intent = .latest }
        }
    }

    mutating func disclosedTool() { intent = .reading }

    mutating func readerScrolled(towardLatest: Bool, atBottom: Bool) {
        if towardLatest && atBottom {
            intent = .latest
            reservedTurnID = nil
        } else {
            // Retain the response-space minimum while reading so a short turn
            // doesn't collapse out from under an interrupted send animation.
            intent = .reading
        }
    }
}

struct TranscriptViewportAnchor: Equatable {
    let rowID: String
    let offset: CGFloat
}

/// In-memory presentation state, retained only alongside a resident transcript.
/// The generation prevents a late disappearing view from saving into another host.
struct TranscriptViewState {
    let generation: Int
    var scrollState = TranscriptScrollState()
    var anchor: TranscriptViewportAnchor?
    var expansion: [String: Bool] = [:]
    var rowHeights: [String: CGFloat] = [:]
    var layoutWidth: CGFloat = 0
    var contentSizeCategory = ""
}

/// Shared arithmetic for the unobscured viewport. A response consumes the
/// reserved blank space before extending naturally below a top-anchored turn.
enum TranscriptScrollGeometry {
    static let turnPadding: CGFloat = 8
    static func turnOffset(rowTop: CGFloat, topInset: CGFloat) -> CGFloat {
        max(-topInset, rowTop - topInset - turnPadding)
    }
    static func reservation(turnOffset: CGFloat, naturalHeight: CGFloat,
                            viewportHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(0, turnOffset + viewportHeight - bottomInset - naturalHeight)
    }
    static func bottom(contentHeight: CGFloat, viewportHeight: CGFloat,
                       topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(-topInset, contentHeight - viewportHeight + bottomInset)
    }
    static func shouldAnimate(initial: Bool, geometryChanged: Bool, reduceMotion: Bool) -> Bool {
        !initial && !geometryChanged && !reduceMotion
    }
}
