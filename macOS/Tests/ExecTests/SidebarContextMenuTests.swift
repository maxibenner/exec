import AppKit
import SwiftUI

/// Register only in --composer-events: hit testing must run with a real current event.
@MainActor struct SidebarContextMenuTests {
    private final class EventWindow: NSWindow {
        struct Hit {
            let items: [SessionContextMenu.Item]?
            let current: Bool
            let target: String
        }
        var posted = Set<Int>()
        var hits: [Int: Hit] = [:]
        var contextUps = Set<Int>()

        override func sendEvent(_ event: NSEvent) {
            let down = event.type == .rightMouseDown || event.type == .leftMouseDown
            let contextual = event.type == .rightMouseDown || event.type == .rightMouseUp ||
                ((event.type == .leftMouseDown || event.type == .leftMouseUp) && event.modifierFlags.contains(.control))
            if posted.contains(event.eventNumber) {
                if down {
                    let target = contentView?.hitTest(event.locationInWindow)
                    hits[event.eventNumber] = Hit(items: (target as? SessionContextMenu.MenuView)?.items,
                        current: NSApp.currentEvent?.eventNumber == event.eventNumber && NSApp.currentEvent?.type == event.type,
                        target: target.map { String(describing: type(of: $0)) } ?? "nil")
                } else if contextual { contextUps.insert(event.eventNumber) }
            }
            // Observe the native target, but never enter NSMenu's modal tracking loop.
            // Ordinary clicks and scrolling still go through the native hierarchy.
            if !contextual { super.sendEvent(event) }
        }
    }

    func parentAndChildHitTargetsStayScoped() async throws {
        _ = NSApplication.shared
        try expect(NSApp.isRunning)
        let deadline = ProcessInfo.processInfo.systemUptime + 4.5
        let suite = "exec-sidebar-context-menu-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = FakeAgentTransport()
        let parentID = AgentIntegrationTests.conversationID, neighborID = UUID()
        let childIDs = [UUID(), UUID()]
        func snapshot(_ id: UUID, _ title: String, parent: UUID? = nil) throws -> AgentJSON {
            guard case .object(var fields) = try AgentIntegrationTests.fixture(state: "completed", result: true),
                  case .object(var metadata) = fields["metadata"] else { throw CheckFailure(description: "Invalid sidebar fixture") }
            fields["id"] = .string(id.uuidString)
            metadata["title"] = .string(title)
            if let parent {
                metadata["parent"] = .object(["sessionId": .string(parent.uuidString),
                    "operationId": .string(AgentIntegrationTests.operationID.uuidString), "toolCallId": .string("delegate")])
            }
            fields["metadata"] = .object(metadata)
            return .object(fields)
        }
        let parent = try snapshot(parentID, "Parent"), neighbor = try snapshot(neighborID, "Neighbor")
        let children = try childIDs.enumerated().map { try snapshot($0.element, "Sub-agent \($0.offset + 1)", parent: parentID) }
        var configuration = AgentLibraryConfiguration()
        configuration.order = [parentID, neighborID] + childIDs
        try await transport.reply("/v1/library", try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(configuration)))
        try await transport.reply("/v1/conversations", .array([parent, neighbor]))
        for (id, value) in zip([parentID, neighborID] + childIDs, [parent, neighbor] + children) {
            try await transport.reply(AgentAPI.path(id), value)
        }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        try library.current.apply(parent.decoded(AgentSnapshot.self))
        try await library.refreshSharedState()
        var deleted: [UUID] = []
        let host = NSHostingView(rootView: SessionSidebar(store: library,
            open: { library.openSession($0) }, delete: { deleted.append($0.id) }))
        let window = EventWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 500),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }

        func views<V: NSView>(_ root: NSView, _ type: V.Type) -> [V] {
            (root as? V).map { [$0] } ?? root.subviews.flatMap { views($0, type) }
        }
        func wait(_ context: String, until ready: () -> Bool) async throws {
            while ProcessInfo.processInfo.systemUptime < deadline {
                host.layoutSubtreeIfNeeded()
                if ready() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CheckFailure(description: "Sidebar context fixture timed out: \(context)")
        }
        try await wait("native rows") {
            guard let table = views(host, NSTableView.self).first,
                  let row = table.rowView(atRow: 0, makeIfNecessary: true) else { return false }
            return table.numberOfRows == 2 && table.rect(ofRow: 0).height > 40 &&
                views(row, SessionContextMenu.MenuView.self).count == 2
        }
        let table = views(host, NSTableView.self)[0]
        let row = table.rowView(atRow: 0, makeIfNecessary: true)!
        var lastHeight: CGFloat = 0, stable = 0
        try await wait("initial row height") {
            let height = table.rect(ofRow: 0).height
            stable = abs(height - lastHeight) < 0.1 ? stable + 1 : 0
            lastHeight = height
            return stable >= 3
        }
        let initialHeight = table.rect(ofRow: 0).height
        var eventNumber = 0
        func click(_ point: NSPoint, right: Bool = false, control: Bool = false) async throws -> EventWindow.Hit {
            if !NSApp.isActive || !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            try await wait("active key window") { NSApp.isActive && window.isKeyWindow && window.isVisible }
            eventNumber -= 1 // Reserve negative numbers; unrelated desktop input cannot satisfy delivery.
            let number = eventNumber
            window.posted.insert(number)
            let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
            let events = try types.enumerated().map { index, type in
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: control ? [.control] : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: number, clickCount: 1, pressure: index == 0 ? 1 : 0)
                else { throw CheckFailure(description: "Could not construct sidebar mouse event") }
                return event
            }
            for event in events { NSApp.postEvent(event, atStart: false) }
            try await wait("mouse delivery #\(number)") {
                window.hits[number] != nil && (!(right || control) || window.contextUps.contains(number))
            }
            return window.hits[number]!
        }
        func navigate(_ point: NSPoint, to id: UUID) async throws {
            let hit = try await click(point)
            try expect(hit.current && hit.items == nil)
            try await wait("ordinary click navigation") { !library.navigating && library.currentSessionID == id }
            try expect(library.sidebarSelectionID == id && table.selectedRow == -1)
        }
        func context(_ point: NSPoint, id: UUID, child: Bool = false, label: String) async throws {
            for control in [false, true] {
                let selected = library.sidebarSelectionID, current = library.current
                deleted.removeAll()
                let hit = try await click(point, right: !control, control: control)
                let expected = child ? ["Delete Sub-agent"] : ["Rename…", "Delete Session"]
                guard hit.current, let items = hit.items else {
                    throw CheckFailure(description: "\(label), control=\(control): hit \(hit.target), current=\(hit.current); expected \(expected)")
                }
                var titles: [String] = []
                for case let .action(title, enabled, perform) in items {
                    titles.append(title)
                    try expect(enabled)
                    if title == expected.last! { perform() } // Only the fixture's recording delete closure, never Rename.
                }
                guard titles == expected, deleted == [id] else {
                    throw CheckFailure(description: "\(label), control=\(control): actions \(titles), delete IDs \(deleted); expected \(expected) for \(id)")
                }
                try expect(library.sidebarSelectionID == selected && library.current === current && table.selectedRow == -1)
            }
        }
        func parentPoint(_ nativeRow: NSView, x: CGFloat, footer: Bool) -> NSPoint {
            // Use native family bounds, NOT the parent menu's height (which used to cover only the title).
            let fromTop = footer ? nativeRow.bounds.height - 14 : 14
            let y = nativeRow.isFlipped ? nativeRow.bounds.minY + fromTop : nativeRow.bounds.maxY - fromTop
            return nativeRow.convert(NSPoint(x: x, y: y), to: nil)
        }
        let neighborRow = table.rowView(atRow: 1, makeIfNecessary: true)!
        let neighborPoint = parentPoint(neighborRow, x: neighborRow.bounds.midX, footer: false)
        try await navigate(neighborPoint, to: neighborID)

        // Remove the first child before the second: reused overlays must not retain the removed child's action.
        for count in [0, 2, 1, 0] {
            try await transport.reply("/v1/conversations", .array([parent, neighbor] + Array(children.suffix(count))))
            try await library.refreshSharedState()
            stable = 0; lastHeight = 0
            try await wait("\(count) children settled") {
                let height = table.rect(ofRow: 0).height
                stable = abs(height - lastHeight) < 0.1 ? stable + 1 : 0
                lastHeight = height
                return stable >= 3 && abs(height - initialHeight - CGFloat(count * 22)) < 1 &&
                    views(row, SessionContextMenu.MenuView.self).count == count + 2
            }
            try expect(table.numberOfRows == 2 && table.selectedRow == -1)
            try expect(table.rowView(atRow: 0, makeIfNecessary: true) === row)
            let menus = views(row, SessionContextMenu.MenuView.self)
            guard let parentMenu = menus.first(where: { menu in
                menu.items.contains { if case .action("Rename…", _, _) = $0 { return true }; return false }
            }) else { throw CheckFailure(description: "Missing parent menu") }
            let bounds = parentMenu.convert(parentMenu.bounds, to: row)
            for footer in [false, true] {
                // Footer left covers the shortcut, +40 covers /tmp's workspace label;
                // middle/right include blank space and the trailing date/status slot.
                let xs = footer ? [bounds.minX + 4, bounds.minX + 40, bounds.midX, bounds.maxX - 4] :
                    [bounds.minX + 4, bounds.midX, bounds.maxX - 4]
                for x in xs {
                    try await context(parentPoint(row, x: x, footer: footer), id: parentID,
                                      label: "\(count) children, \(footer ? "footer" : "title") x=\(x)")
                }
            }
            let childMenus = menus.filter { menu in
                !menu.items.contains { if case .action("Rename…", _, _) = $0 { return true }; return false }
            }.sorted {
                let a = $0.convert($0.bounds, to: row).midY, b = $1.convert($1.bounds, to: row).midY
                return row.isFlipped ? a < b : a > b
            }
            for (menu, id) in zip(childMenus, childIDs.suffix(count)) {
                let rect = menu.bounds
                for x in [rect.minX + 4, rect.midX, rect.maxX - 4] {
                    try await context(menu.convert(NSPoint(x: x, y: rect.midY), to: nil), id: id, child: true,
                                      label: "\(count) children, child \(id) x=\(x)")
                }
            }
            if let child = childMenus.last {
                try await navigate(child.convert(NSPoint(x: child.bounds.midX, y: child.bounds.midY), to: nil), to: childIDs.last!)
            }
            try await navigate(parentPoint(row, x: bounds.midX, footer: count > 0), to: parentID)
            try await navigate(parentPoint(neighborRow, x: neighborRow.bounds.midX, footer: false), to: neighborID)
        }
        let requests = await transport.requests
        try expect(requests.allSatisfy { $0.method == "GET" })
    }
}
