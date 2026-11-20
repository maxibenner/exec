import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: ChatLibrary?
    private var waitingToQuit = false
    private var readyToQuit = false
    var shutdownBackend: (@MainActor () async -> Void)?

    // Keep presentation and the final AppKit request injectable so unit tests
    // never quit their host process or interact with the user's windows.
    var confirmQuit: @MainActor (NSAlert, NSWindow?) async -> NSApplication.ModalResponse = { alert, window in
        if let window, window.isVisible, window.attachedSheet == nil {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }
    var finishQuitRequest: (NSApplication, Bool) -> Void = { application, shouldQuit in
        if shouldQuit { application.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        if waitingToQuit { return .terminateCancel }
        guard let store, store.hasRunningOperations || store.hasUnsavedChanges || store.hasUnsentDrafts else {
            guard let shutdownBackend else { return .terminateNow }
            waitingToQuit = true
            Task { await shutdownBackend(); finishQuit(sender) }
            return .terminateCancel
        }
        let alert = NSAlert()
        alert.messageText = "Quit Exec?"
        var reasons: [String] = []
        if store.hasRunningOperations {
            reasons.append("Active operations in all conversations will be stopped.")
        }
        if store.hasUnsavedChanges { reasons.append("Changes that could not be saved will be discarded.") }
        if store.hasUnsentDrafts { reasons.append("Unsent text and attachments in all conversations will be discarded.") }
        reasons.append("Saved conversations will be kept.")
        alert.informativeText = reasons.joined(separator: " ")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        // Reserve the whole decision before yielding; repeated Quit requests
        // must neither stack alerts nor start a second shutdown.
        waitingToQuit = true
        Task {
            let response = await confirmQuit(alert, sender.keyWindow ?? sender.mainWindow)
            guard response == .alertFirstButtonReturn else {
                finishQuitRequest(sender, false)
                waitingToQuit = false
                return
            }
            if store.hasRunningOperations { store.stopAll() }
            if let shutdownBackend {
                // Rust owns cancellation, process reaping, checkpoint settlement and lock removal.
                await shutdownBackend()
            } else {
                while store.hasRunningOperations { try? await Task.sleep(for: .milliseconds(50)) }
            }
            finishQuit(sender)
        }
        // terminateLater can enter a modal loop while the caller still occupies
        // the main dispatch queue, preventing our main-actor task from running.
        // Unwind this request, then re-enter termination only after cleanup settles.
        return .terminateCancel
    }

    private func finishQuit(_ sender: NSApplication) {
        readyToQuit = true
        finishQuitRequest(sender, true)
    }
}
