import AppKit
import SwiftUI

@MainActor struct SessionRenameTests {
    private func views<V: NSView>(_ root: NSView, _ type: V.Type) -> [V] {
        (root as? V).map { [$0] } ?? root.subviews.flatMap { views($0, type) }
    }

    func repeatedRenamesSelectTheCurrentTitle() async throws {
        _ = NSApplication.shared
        try expect(NSApp.isRunning)
        let fixture = try LifecycleFixture()
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let host = NSHostingView(rootView: SessionSidebar(store: library, open: { _ in }, delete: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            window.orderOut(nil)
            window.contentView = nil
        }
        try await SessionLifecycleTests.wait("rename sidebar rows") {
            host.layoutSubtreeIfNeeded()
            return self.views(host, NSTableView.self).first?.numberOfRows == 2
        }
        let table = views(host, NSTableView.self)[0]
        let path = AgentAPI.path(fixture.otherID, "/title")
        try await fixture.transport.responses.reply(path, .object([:]))

        func begin(row index: Int, title: String) async throws -> (NSWindow, NSTextField, NSTextView) {
            host.layoutSubtreeIfNeeded()
            guard let row = table.rowView(atRow: index, makeIfNecessary: true),
                  let action = self.views(row, SessionContextMenu.MenuView.self).flatMap(\.items).compactMap({ item -> (() -> Void)? in
                      if case let .action("Rename…", enabled, perform) = item, enabled { return perform }
                      return nil
                  }).first else { throw CheckFailure(description: "Missing sidebar rename action") }
            action()
            try await SessionLifecycleTests.wait("rename sheet and field editor") {
                guard let sheet = window.attachedSheet, let content = sheet.contentView,
                      let field = self.views(content, NSTextField.self).first(where: \.isEditable) else { return false }
                return sheet.isVisible && field.currentEditor() != nil
            }
            let sheet = window.attachedSheet!
            let field = self.views(sheet.contentView!, NSTextField.self).first(where: \.isEditable)!
            let editor = field.currentEditor() as! NSTextView
            try expect(field.stringValue == title)
            try expect(editor.selectedRange() == NSRange(location: 0, length: (title as NSString).length))
            // A second invocation while this sheet is open must not queue another prompt.
            action()
            try expect(window.sheets.count == 1)
            return (sheet, field, editor)
        }
        func finish(_ sheet: NSWindow, button title: String) async throws {
            guard let button = self.views(sheet.contentView!, NSButton.self).first(where: { $0.title == title }) else {
                throw CheckFailure(description: "Missing rename dialog button: \(title)")
            }
            try expect(button.isEnabled)
            button.performClick(nil)
            try await SessionLifecycleTests.wait("rename sheet dismissal") { window.attachedSheet == nil }
            await library.waitForNavigation()
            try expect(library.error == nil)
        }
        func savedTitle(_ title: String) throws -> AgentJSON {
            guard case .object(var fields) = fixture.other, case .object(var metadata) = fields["metadata"] else {
                throw CheckFailure(description: "Invalid rename fixture")
            }
            metadata["title"] = .string(title)
            metadata["manuallyNamed"] = .bool(true)
            fields["metadata"] = .object(metadata)
            return .object(fields)
        }

        var currentTitle = "Other session"
        var previousField: NSTextField?
        for replacement in ["Renamed once 👩🏽‍💻", "Renamed twice 🚀"] {
            let (sheet, field, editor) = try await begin(row: 1, title: currentTitle)
            try expect(field !== previousField)
            previousField = field
            // Typing replaces the selected title without an explicit Select All.
            editor.insertText(replacement, replacementRange: editor.selectedRange())
            try expect(field.stringValue == replacement)
            let updated = try savedTitle(replacement)
            try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, fixture.child, updated]))
            try await finish(sheet, button: "Rename")
            currentTitle = replacement
            try expect(library.sessionList.first(where: { $0.id == fixture.otherID })?.title == currentTitle)
        }
        let (cancelled, field, editor) = try await begin(row: 1, title: currentTitle)
        editor.insertText("   ", replacementRange: editor.selectedRange())
        let rename = views(cancelled.contentView!, NSButton.self).first(where: { $0.title == "Rename" })!
        try expect(field.stringValue == "   " && !rename.isEnabled)
        try await finish(cancelled, button: "Cancel")
        let (reopened, _, _) = try await begin(row: 1, title: currentTitle)
        try await finish(reopened, button: "Cancel")
        let (otherSession, _, _) = try await begin(row: 0, title: "Lifecycle parent")
        try await finish(otherSession, button: "Cancel")
        let writes = await fixture.transport.responses.requests.filter { $0.method == "PUT" }
        try expect(writes.count == 2 && writes.allSatisfy { $0.path == path })
    }
}
