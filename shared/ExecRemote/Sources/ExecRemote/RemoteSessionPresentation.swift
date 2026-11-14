import Foundation

/// Session activity is stored by the host as milliseconds since the epoch.
public struct RemoteSessionDay: Identifiable {
    public let date: Date
    public let conversations: [RemoteJSON]
    public var id: Date { date }

    public static func group(_ conversations: [RemoteJSON], calendar: Calendar = .current) -> [Self] {
        let sorted = conversations.sorted {
            let lhs = activityDate($0), rhs = activityDate($1)
            return lhs == rhs ? ($0["id"].string ?? "") < ($1["id"].string ?? "") : lhs > rhs
        }
        let groups = Dictionary(grouping: sorted) { calendar.startOfDay(for: activityDate($0)) }
        return groups.keys.sorted(by: >).map { Self(date: $0, conversations: groups[$0] ?? []) }
    }

    public static func activityDate(_ conversation: RemoteJSON) -> Date {
        Date(timeIntervalSince1970: (conversation["metadata"]["activityAt"].number ?? 0) / 1000)
    }

    public func title(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMMd" : "MMMMdy")
        return formatter.string(from: date)
    }
}

/// Bind queued input to the observed operation; never fall back to a new turn if
/// that operation settles before the host accepts the request.
public struct RemoteMessageSubmission {
    public let path: String
    public let body: RemoteJSON

    public static func isActive(_ snapshot: RemoteJSON) -> Bool {
        ["running", "awaiting_approval", "cancelling"].contains(snapshot["operation"]["state"].string ?? "")
    }

    public static func showsStop(snapshot: RemoteJSON, draft: String) -> Bool {
        isActive(snapshot) && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init?(conversationID: String, snapshot: RemoteJSON, text: String) {
        guard snapshot["id"].string == conversationID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if Self.isActive(snapshot) {
            guard let operation = snapshot["operation"]["id"].string else { return nil }
            path = "/v1/conversations/\(conversationID)/steer"
            body = .object(["operationID": .string(operation), "text": .string(text)])
        } else {
            path = "/v1/conversations/\(conversationID)/turns"
            body = .object(["text": .string(text)])
        }
    }
}
