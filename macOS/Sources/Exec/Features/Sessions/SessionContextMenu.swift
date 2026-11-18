import AppKit
import SwiftUI

/// Opens a native menu without asking List to highlight the right-clicked row.
struct SessionContextMenu: NSViewRepresentable {
    enum Item {
        case action(String, enabled: Bool, perform: () -> Void)
        case separator
    }

    let items: [Item]

    func makeNSView(context: Context) -> MenuView {
        MenuView()
    }

    func updateNSView(_ view: MenuView, context: Context) {
        view.items = items
    }

    final class MenuView: NSView {
        var items: [Item] = []

        // Leave ordinary clicks, scrolling and native row reordering to List.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown ||
                    (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else {
                return nil
            }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            showMenu(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                showMenu(with: event)
            } else {
                super.mouseDown(with: event)
            }
        }

        private func showMenu(with event: NSEvent) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                switch item {
                case let .action(title, enabled, perform):
                    let menuItem = ActionItem(title: title, perform: perform)
                    menuItem.isEnabled = enabled
                    menu.addItem(menuItem)
                case .separator:
                    menu.addItem(.separator())
                }
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private final class ActionItem: NSMenuItem {
        private let perform: () -> Void

        init(title: String, perform: @escaping () -> Void) {
            self.perform = perform
            super.init(title: title, action: #selector(invoke), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func invoke() {
            perform()
        }
    }
}
