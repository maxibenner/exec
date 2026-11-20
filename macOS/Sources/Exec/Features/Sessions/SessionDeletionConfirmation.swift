import AppKit

/// Only explicit UI deletion uses this policy; backend cleanup never prompts.
@MainActor struct SessionDeletionConfirmation {
    private let stopsRunningWork: Bool
    private let discardsUnsentDraft: Bool

    init(for id: UUID, in library: ChatLibrary) {
        stopsRunningWork = Self.isFamilyRunning(id, in: library)
        discardsUnsentDraft = library.needsDraftDeletionConfirmation(for: id)
    }

    var isRequired: Bool { stopsRunningWork || discardsUnsentDraft }

    private static func isFamilyRunning(_ id: UUID, in library: ChatLibrary) -> Bool {
        var remaining = [id]
        var visited: Set<UUID> = []
        while let next = remaining.popLast() {
            guard visited.insert(next).inserted else { continue }
            if library.isSessionRunning(next) { return true }
            remaining.append(contentsOf: library.childSessions(of: next).map(\.id))
        }
        return false
    }

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = stopsRunningWork ? "Delete running session?" : "Delete session?"
        var reasons: [String] = []
        if stopsRunningWork { reasons.append("This will stop its work.") }
        if discardsUnsentDraft { reasons.append("Its unsent message will be discarded.") }
        alert.informativeText = reasons.joined(separator: "\n\n")
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        return alert
    }

    static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible, window.attachedSheet == nil {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }
}
