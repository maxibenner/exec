import AppKit

/// A fresh native field per presentation avoids SwiftUI alert text-entry reuse.
@MainActor final class SessionRenamePrompt: NSObject, NSTextFieldDelegate {
    weak var window: NSWindow?
    private var alert: NSAlert?

    func present(title: String, rename: @escaping (String) -> Void) {
        guard alert == nil, let window, window.isVisible, window.attachedSheet == nil else { return }
        let field = NSTextField(string: title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Name")
        field.delegate = self

        let alert = NSAlert()
        alert.messageText = "Rename Conversation"
        alert.addButton(withTitle: "Rename").isEnabled = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.alert === alert else { return }
            self.alert = nil
            guard response == .alertFirstButtonReturn,
                  !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            rename(field.stringValue)
        }
        alert.window.makeFirstResponder(field)
        field.selectText(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === alert?.accessoryView else { return }
        alert?.buttons.first?.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
