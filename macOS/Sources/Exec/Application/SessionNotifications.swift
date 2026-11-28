import AppKit
import UserNotifications

@MainActor final class SessionNotifications {
    private struct Alert: Equatable {
        let operationID: UUID?
        let title: String

        init?(_ summary: SessionSummary) {
            guard !summary.unreadable else { return nil }
            operationID = summary.operationID
            if summary.hasStorageError || summary.operationState == "failed" {
                title = "Session failed"
            } else if summary.awaitingApproval {
                title = "Approval needed"
            } else if summary.parent == nil, summary.completedTurnID != nil {
                title = "Session finished"
            } else {
                return nil
            }
        }
    }

    private let isActive: @MainActor () -> Bool
    private let post: @MainActor (UNNotificationRequest) -> Void
    private var requestedAuthorization = false

    init(isActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
         post: @escaping @MainActor (UNNotificationRequest) -> Void = { SessionNotifications.center?.add($0) }) {
        self.isActive = isActive
        self.post = post
    }

    private static var center: UNUserNotificationCenter? {
        // Unbundled SwiftPM executables have no notification identity.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return .current()
    }

    func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization, isActive(), let center = Self.center else { return }
        requestedAuthorization = true
        // macOS remembers the user's choice and only prompts the first time.
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func catalogDidChange(from previous: [SessionSummary], to current: [SessionSummary]) {
        guard !isActive() else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for summary in current {
            guard let alert = Alert(summary), alert != previousByID[summary.id].flatMap(Alert.init) else { continue }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = summary.title
            post(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
