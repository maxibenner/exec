import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: ChatStore?
    private var waitingToQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingToQuit { return .terminateLater }
        guard let store, store.busy || !store.draft.isEmpty || store.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Harness?"
        alert.informativeText = "Any active operation will be stopped. Unsent text and changes that could not be saved will be discarded. Saved conversations will be kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard store.busy else { return .terminateNow }
        waitingToQuit = true
        store.stop()
        // Let cancellation reap shell children and checkpoint outcomes before exiting.
        Task {
            while store.busy { try? await Task.sleep(for: .milliseconds(50)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
