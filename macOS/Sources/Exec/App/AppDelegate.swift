import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: ChatLibrary?
    private var waitingToQuit = false
    var shutdownBackend: (@MainActor () async -> Void)?

    // Keep presentation and the final AppKit reply injectable so tests never quit
    // the test process or interact with the user's windows.
    var confirmQuit: @MainActor (NSAlert, NSWindow?) async -> NSApplication.ModalResponse = { alert, window in
        if let window, window.isVisible, window.attachedSheet == nil {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }
    var replyToTermination: (NSApplication, Bool) -> Void = { application, shouldQuit in
        application.reply(toApplicationShouldTerminate: shouldQuit)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingToQuit { return .terminateLater }
        guard let store, store.hasRunningOperations || store.hasUnsavedChanges else {
            guard let shutdownBackend else { return .terminateNow }
            waitingToQuit = true
            Task { await shutdownBackend(); replyToTermination(sender, true) }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = "Quit Exec?"
        var reasons: [String] = []
        if store.hasRunningOperations {
            reasons.append(store.ownsBackend ? "Active operations in all conversations will be stopped."
                : "Active operations on the external backend will continue.")
        }
        if store.hasUnsavedChanges { reasons.append("Changes that could not be saved will be discarded.") }
        reasons.append("Saved conversations will be kept.")
        alert.informativeText = reasons.joined(separator: " ")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        // Mark the entire confirmation as pending BEFORE presenting it. Returning
        // to AppKit first avoids a nested termination callback from a modal loop;
        // repeated Quit/Close requests share this one decision instead of stacking alerts.
        waitingToQuit = true
        Task {
            let response = await confirmQuit(alert, sender.keyWindow ?? sender.mainWindow)
            guard response == .alertFirstButtonReturn else {
                // Keep the guard set while AppKit unwinds the cancelled request.
                replyToTermination(sender, false)
                waitingToQuit = false
                return
            }
            if store.ownsBackend && store.hasRunningOperations { store.stopAll() }
            if let shutdownBackend {
                // Rust owns cancellation, process reaping, checkpoint settlement and lock removal.
                await shutdownBackend()
            } else if store.ownsBackend {
                while store.hasRunningOperations { try? await Task.sleep(for: .milliseconds(50)) }
            }
            replyToTermination(sender, true)
        }
        return .terminateLater
    }
}
