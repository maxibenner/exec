import Foundation
import ExecRemote

/// A table item is either one message or a contiguous run of tools. Calls keep
/// their own identities even though UIKit measures the entire run in one host.
struct TranscriptItem: Equatable {
    let rows: [RemoteTranscriptRow]
    var id: String { rows[0].id }
    var isToolGroup: Bool { rows[0].call != nil }

    static func project(_ snapshot: RemoteJSON) -> [Self] {
        let rows = RemoteTranscriptRow.project(snapshot)
        var items: [Self] = []
        var tools: [RemoteTranscriptRow] = []
        var seen: Set<String> = []
        for row in rows where !row.id.isEmpty && seen.insert(row.id).inserted {
            if row.call != nil {
                tools.append(row)
            } else {
                if !tools.isEmpty { items.append(Self(rows: tools)); tools = [] }
                items.append(Self(rows: [row]))
            }
        }
        if !tools.isEmpty { items.append(Self(rows: tools)) }
        return items
    }
}

/// One matched local Send, not a property of the transcript rows. The store
/// checks that the request is still current when UIKit applies its update.
struct TranscriptSendPin {
    let rowID: String
    let consume: @MainActor () -> Bool

    @MainActor func take(in rows: [RemoteTranscriptRow]) -> String? {
        guard rows.contains(where: { $0.id == rowID && $0.message["role"].string == "user" }),
              consume() else { return nil }
        return rowID
    }
}

/// Only reader input and an explicit Send change follow intent. Geometry,
/// streaming, and queued promotions must not infer a new turn to pin.
struct TranscriptScrollState {
    enum Intent: Equatable { case latest, turn(String), reading }
    private(set) var intent: Intent = .latest
    private(set) var reservedTurnID: String?

    mutating func update(rows: [RemoteTranscriptRow], pinTo rowID: String? = nil) -> Bool {
        if let rowID, rows.contains(where: { $0.id == rowID && $0.message["role"].string == "user" }) {
            intent = .turn(rowID)
            reservedTurnID = rowID
            return true
        }
        restoreRows(rows)
        return false
    }

    /// Reopening adopts cached history without applying a new send request.
    mutating func restoreRows(_ rows: [RemoteTranscriptRow]) {
        if let reservedTurnID, !rows.contains(where: { $0.id == reservedTurnID }) {
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
