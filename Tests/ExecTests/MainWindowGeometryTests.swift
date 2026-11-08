import AppKit
import SwiftUI

@MainActor struct MainWindowGeometryTests {
    private let primary = MainWindowGeometry.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050))
    private let secondary = MainWindowGeometry.Display(id: 2, frame: CGRect(x: -1440, y: -900, width: 1440, height: 900),
        visibleFrame: CGRect(x: -1440, y: -900, width: 1440, height: 870))
    private let minimum = CGSize(width: 720, height: 480)

    private func seed(_ snapshot: MainWindowGeometry.Snapshot, in preferences: UserDefaults) throws {
        preferences.set(try JSONEncoder().encode(snapshot), forKey: MainWindowGeometry.preferenceKey)
    }

    func roundTripsWithoutChromeDrift() throws {
        let suite = "ExecWindowTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let geometry = MainWindowGeometry(preferences: preferences)
        for (display, frame) in [(primary, CGRect(x: 100, y: 250, width: 980, height: 700)),
                                 (secondary, CGRect(x: -1300, y: -720, width: 900, height: 600))] {
            var snapshot = MainWindowGeometry.Snapshot(frame: frame, displayID: display.id,
                                                       visibleFrame: display.visibleFrame, titlebarHeight: 52)
            for _ in 0..<5 {
                try seed(snapshot, in: preferences)
                // Reading through a new store models the next launch; never subtract
                // the toolbar from the saved outer size or add it on each restart.
                let fresh = MainWindowGeometry(preferences: preferences)
                let placement = fresh.placement(displays: [primary, secondary], defaultDisplayID: primary.id,
                                                minimumContentSize: minimum)!
                let restored = CGRect(x: placement.position.x,
                    y: primary.frame.maxY - placement.position.y - placement.size.height,
                    width: placement.size.width, height: placement.size.height)
                try expect(restored == frame && fresh.saved == snapshot)
                snapshot = .init(frame: restored, displayID: display.id, visibleFrame: display.visibleFrame, titlebarHeight: 52)
            }
        }
        let placement = geometry.placement(displays: [primary, secondary], defaultDisplayID: primary.id, minimumContentSize: minimum)!
        try expect(placement.position == CGPoint(x: -1300, y: 1200))
    }

    func adaptsToDisplayChanges() throws {
        let suite = "ExecWindowTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let geometry = MainWindowGeometry(preferences: preferences)
        try seed(.init(frame: CGRect(x: -1300, y: -720, width: 900, height: 600), displayID: secondary.id,
                       visibleFrame: secondary.visibleFrame, titlebarHeight: 52), in: preferences)
        let moved = MainWindowGeometry.Display(id: secondary.id, frame: CGRect(x: 1920, y: 0, width: 1440, height: 900),
                                               visibleFrame: CGRect(x: 1920, y: 0, width: 1440, height: 870))
        let repositioned = geometry.placement(displays: [primary, moved], defaultDisplayID: primary.id, minimumContentSize: minimum)!
        try expect(repositioned.position == CGPoint(x: 2060, y: 300))
        let disconnected = geometry.placement(displays: [primary], defaultDisplayID: primary.id, minimumContentSize: minimum)!
        try expect(disconnected.position == CGPoint(x: 510, y: 255) && disconnected.size == CGSize(width: 900, height: 600))
        // A smaller display keeps the title bar and window reachable.
        let small = MainWindowGeometry.Display(id: secondary.id, frame: CGRect(x: 1920, y: 0, width: 800, height: 600),
                                               visibleFrame: CGRect(x: 1920, y: 0, width: 800, height: 570))
        let fitted = geometry.placement(displays: [primary, small], defaultDisplayID: primary.id, minimumContentSize: minimum)!
        try expect(fitted.position == CGPoint(x: 1920, y: 510) && fitted.size == CGSize(width: 800, height: 570))
        // Saved geometry from an older, smaller layout respects current content minima.
        try seed(.init(frame: CGRect(x: 100, y: 250, width: 600, height: 400), displayID: primary.id,
                       visibleFrame: primary.visibleFrame, titlebarHeight: 52), in: preferences)
        let minimumSize = geometry.placement(displays: [primary], defaultDisplayID: primary.id, minimumContentSize: minimum)!
        try expect(minimumSize.size == CGSize(width: 720, height: 532))
    }

    func rejectsInvalidPreferences() throws {
        let suite = "ExecWindowTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let geometry = MainWindowGeometry(preferences: preferences)
        try expect(geometry.saved == nil)
        preferences.set(Data("corrupt".utf8), forKey: MainWindowGeometry.preferenceKey)
        try expect(geometry.placement(displays: [primary], defaultDisplayID: primary.id, minimumContentSize: minimum) == nil)
        for (frame, chrome) in [(CGRect.zero, CGFloat(52)), (CGRect(x: 0, y: 0, width: 980, height: 700), CGFloat(-1))] {
            try seed(.init(frame: frame, displayID: primary.id, visibleFrame: primary.visibleFrame, titlebarHeight: chrome), in: preferences)
            try expect(geometry.saved == nil)
        }
    }

    func observesOnlyVisibleNormalMainWindow() async throws {
        _ = NSApplication.shared
        let suite = "ExecWindowTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let geometry = MainWindowGeometry(preferences: preferences)
        let window = NSWindow(contentViewController: NSHostingController(rootView:
            ChatWindowLayout(workspace: nil) { Color.clear } detail: { Color.clear }))
        window.setContentSize(CGSize(width: 980, height: 700))
        window.center()
        geometry.observe(window)
        defer { geometry.observe(nil); window.orderOut(nil) }
        let center = NotificationCenter.default
        center.post(name: NSWindow.didResizeNotification, object: window)
        try expect(geometry.saved == nil) // Attaching cannot overwrite the saved placement with a startup frame.
        window.orderFront(nil)
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let snapshot = geometry.saved!
        try expect(snapshot.frame == window.frame && snapshot.titlebarHeight == window.frame.height - window.contentLayoutRect.height)
        try expect(snapshot.titlebarHeight > 0)
        // Read-only placement calculation never adjusts the live window.
        let frame = window.frame
        _ = geometry.placement(minimumContentSize: minimum, defaultDisplayBounds: .zero)
        try expect(window.frame == frame)
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(frame.insetBy(dx: -20, dy: -20), display: false)
        center.post(name: NSWindow.didResizeNotification, object: window)
        try expect(geometry.saved == snapshot)
        center.post(name: NSWindow.willExitFullScreenNotification, object: window)
        window.setFrame(frame, display: false)
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try expect(geometry.saved == snapshot)
        let other = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 500),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        center.post(name: NSWindow.didResizeNotification, object: other)
        try expect(geometry.saved == snapshot)
        geometry.observe(nil)
        window.setFrameOrigin(CGPoint(x: frame.minX + 20, y: frame.minY + 10))
        center.post(name: NSWindow.didMoveNotification, object: window)
        try expect(geometry.saved == snapshot)
        geometry.observe(window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        try expect(geometry.saved?.frame == window.frame && geometry.saved != snapshot)
    }
}
