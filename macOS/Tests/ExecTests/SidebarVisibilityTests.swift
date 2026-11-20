import AppKit
import Observation
import SwiftUI

@MainActor struct SidebarVisibilityTests {
    func nativeObservationPublishesOnlyAttachedChangesOnce() async throws {
        _ = NSApplication.shared
        let split = NSSplitViewController()
        let sidebarController = NSViewController(), detail = NSViewController()
        sidebarController.view = NSView()
        detail.view = NSView()
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.isCollapsed = true
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        let window = NSWindow(contentViewController: split)
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 980, height: 700))
        let observer = SidebarResizeBehavior.ConfigurationView()
        var changes: [Bool] = []
        observer.onVisibilityChange = { changes.append($0) }
        defer {
            observer.removeFromSuperview()
            window.contentViewController = nil
            window.close()
        }
        detail.view.addSubview(observer)
        observer.configure()
        observer.configure()
        try await Task.sleep(for: .milliseconds(50))
        try expect(changes.isEmpty) // Attachment must not write a preference.

        sidebar.isCollapsed = false
        sidebar.isCollapsed = false
        observer.configure()
        try await Task.sleep(for: .milliseconds(50))
        try expect(changes == [true])
        sidebar.isCollapsed = true
        try await Task.sleep(for: .milliseconds(50))
        try expect(changes == [true, false])

        // Queue a publication, then detach and reattach to the SAME item before
        // yielding. Item identity alone cannot reject this stale callback.
        sidebar.isCollapsed = false
        observer.removeFromSuperview()
        detail.view.addSubview(observer)
        observer.configure()
        try await Task.sleep(for: .milliseconds(50))
        try expect(changes == [true, false])

        observer.removeFromSuperview()
        sidebar.isCollapsed = true
        try await Task.sleep(for: .milliseconds(50))
        try expect(changes == [true, false])
        detail.view.addSubview(observer)
        observer.configure()
        sidebar.isCollapsed = false
        try await Task.sleep(for: .milliseconds(50))
        try expect(changes == [true, false, true])

        sidebar.isCollapsed = true
        SidebarResizeBehavior.dismantleNSView(observer, coordinator: ())
        try await Task.sleep(for: .milliseconds(50))
        try expect(changes == [true, false, true])
    }

    func appliesInitialVisibilityBeforeOrderingWindowFront() async throws {
        let suite = "exec-sidebar-visibility-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }

        for savedVisibility: Bool? in [nil, false, true] {
            preferences.removeObject(forKey: SidebarVisibilityPreference.preferenceKey)
            if let savedVisibility {
                SidebarVisibilityPreference(preferences: preferences).isVisible = savedVisibility
            }
            for count in [0, 1, 2] {
                let fixture = Fixture(sessionCount: count, preferences: preferences)
                defer { fixture.dispose() }

                try expect(!fixture.window.isVisible)
                try await fixture.expectSidebar(visible: savedVisibility ?? false)
                try expect(!fixture.window.isVisible)

                fixture.window.orderFront(nil)
                try await fixture.expectSidebar(visible: savedVisibility ?? false)
                if savedVisibility == nil {
                    try expect(preferences.object(forKey: SidebarVisibilityPreference.preferenceKey) == nil)
                }
            }
        }
    }

    func nativeToggleSurvivesContentCountAndFocusChanges() async throws {
        let suite = "exec-sidebar-visibility-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }

        // Exercise both opening an initially closed sidebar and closing an open one.
        for initiallyVisible in [false, true] {
            SidebarVisibilityPreference(preferences: preferences).isVisible = initiallyVisible
            let fixture = Fixture(sessionCount: 1, preferences: preferences)
            defer { fixture.dispose() }
            let split = try await fixture.expectSidebar(visible: initiallyVisible)
            fixture.window.orderFront(nil)
            split.toggleSidebar(nil)
            let manuallyVisible = !initiallyVisible
            try await fixture.expectSidebar(visible: manuallyVisible, sameController: split)

            // Refresh the root, including additions and removing every session.
            // Neither catalog changes nor detail focus may reset the user's choice.
            for updatedCount in [2, 1, 0, 3, 0] {
                fixture.model.sessionCount = updatedCount
                fixture.model.contentRevision += 1
                try await fixture.expectSidebar(visible: manuallyVisible, sameController: split)
                try fixture.clickAndFocusDetail()
                try await fixture.expectSidebar(visible: manuallyVisible, sameController: split)
            }
        }
    }

    func nativeTogglesPersistAcrossWindowRemounts() async throws {
        let suite = "exec-sidebar-visibility-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }

        for count in [0, 1] {
            for initiallyVisible in [false, true] {
                SidebarVisibilityPreference(preferences: preferences).isVisible = initiallyVisible
                do {
                    let fixture = Fixture(sessionCount: count, preferences: preferences)
                    defer { fixture.dispose() }
                    let split = try await fixture.expectSidebar(visible: initiallyVisible)
                    fixture.window.orderFront(nil)
                    let menuItem = NSMenuItem(title: "Toggle Sidebar",
                                              action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                              keyEquivalent: "")
                    try expect(NSApp.sendAction(menuItem.action!, to: split, from: menuItem))
                    try await fixture.expectSidebar(visible: !initiallyVisible, sameController: split)
                }

                // Recreate both the native window and preference reader, as at relaunch.
                let restored = Fixture(sessionCount: count, preferences: UserDefaults(suiteName: suite)!)
                defer { restored.dispose() }
                try await restored.expectSidebar(visible: !initiallyVisible)
                try expect(!restored.window.isVisible)
                restored.window.orderFront(nil)
                try await restored.expectSidebar(visible: !initiallyVisible)
            }
        }
    }

    func revealRequestsOpenOnceAndRespectSubsequentManualClose() async throws {
        let suite = "exec-sidebar-visibility-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }

        do {
            let fixture = Fixture(sessionCount: 1, preferences: preferences)
            defer { fixture.dispose() }
            let split = try await fixture.expectSidebar(visible: false)
            fixture.window.orderFront(nil)

            fixture.model.sessionCount = 2
            fixture.model.sidebarRevealRequest += 1
            try await fixture.expectSidebar(visible: true, sameController: split)
            fixture.model.contentRevision += 1
            try await fixture.expectSidebar(visible: true, sameController: split)
        }

        do {
            // The automatic open survives a remount, even after all sessions disappear.
            let fixture = Fixture(sessionCount: 0, preferences: UserDefaults(suiteName: suite)!, sidebarRevealRequest: 1)
            defer { fixture.dispose() }
            let split = try await fixture.expectSidebar(visible: true)
            fixture.window.orderFront(nil)
            split.toggleSidebar(nil)
            try await fixture.expectSidebar(visible: false, sameController: split)
            for count in [2, 1, 0] {
                fixture.model.sessionCount = count
                fixture.model.contentRevision += 1
                try await fixture.expectSidebar(visible: false, sameController: split)
                try fixture.clickAndFocusDetail()
                try await fixture.expectSidebar(visible: false, sameController: split)
            }
            try expect(fixture.model.sidebarRevealRequest == 1)
        }

        // A previously consumed reveal must not replay over a saved manual close.
        let restored = Fixture(sessionCount: 1, preferences: UserDefaults(suiteName: suite)!, sidebarRevealRequest: 1)
        defer { restored.dispose() }
        let split = try await restored.expectSidebar(visible: false)
        restored.window.orderFront(nil)
        restored.model.sidebarRevealRequest += 1
        try await restored.expectSidebar(visible: true, sameController: split)
    }

    @MainActor @Observable final class Model: NSObject {
        let sidebarVisibility: SidebarVisibilityPreference
        var sessionCount: Int
        var contentRevision = 0
        var sidebarRevealRequest: Int
        var clicks = 0
        let button = NSButton(title: "Update detail", target: nil, action: nil)
        let editor = NSTextField(string: "Isolated draft")

        var summary: String {
            "Sessions: \(sessionCount), content: \(contentRevision), clicks: \(clicks)"
        }

        init(sessionCount: Int, preferences: UserDefaults, sidebarRevealRequest: Int) {
            self.sidebarVisibility = SidebarVisibilityPreference(preferences: preferences)
            self.sessionCount = sessionCount
            self.sidebarRevealRequest = sidebarRevealRequest
            super.init()
            button.target = self
            button.action = #selector(updateDetail)
        }

        @objc private func updateDetail() { clicks += 1 }
    }

    private struct Root: View {
        let model: Model

        var body: some View {
            ChatWindowLayout(initiallyShowsSidebar: model.sidebarVisibility.isVisible,
                             sidebarRevealRequest: model.sidebarRevealRequest,
                             onSidebarVisibilityChange: { model.sidebarVisibility.isVisible = $0 }) {
                Text("Sessions: \(model.sessionCount)")
            } detail: {
                DetailControls(model: model, summary: model.summary)
                    .padding()
            }
        }
    }

    // Native controls make clicks and first-responder changes independent of
    // SwiftUI's private button/text-field implementation. No session store is used.
    private struct DetailControls: NSViewRepresentable {
        let model: Model
        let summary: String

        func makeNSView(context: Context) -> NSStackView {
            let stack = NSStackView(views: [model.button, model.editor])
            stack.orientation = .vertical
            stack.spacing = 12
            return stack
        }

        func updateNSView(_ view: NSStackView, context: Context) {
            model.button.title = summary
        }
    }

    @MainActor private final class Fixture {
        let model: Model
        let window: NSWindow

        init(sessionCount: Int, preferences: UserDefaults, sidebarRevealRequest: Int = 0) {
            _ = NSApplication.shared
            model = Model(sessionCount: sessionCount, preferences: preferences, sidebarRevealRequest: sidebarRevealRequest)
            window = NSWindow(contentViewController: NSHostingController(rootView: Root(model: model)))
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.setContentSize(CGSize(width: 980, height: 700))
        }

        func dispose() {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }

        func clickAndFocusDetail() throws {
            try expect(model.button.window === window && model.editor.window === window)
            let previousClicks = model.clicks
            // performClick runs a nested AppKit event loop, which can end the
            // async command-line runner's main loop. Dispatch the same action.
            try expect(NSApp.sendAction(model.button.action!, to: model.button.target, from: model.button))
            try expect(model.clicks == previousClicks + 1)
            try expect(window.makeFirstResponder(model.editor))
            guard let editor = model.editor.currentEditor() else {
                throw CheckFailure(description: "Sidebar fixture did not focus its native detail editor")
            }
            try expect(window.firstResponder === editor)
        }

        @discardableResult
        func expectSidebar(visible: Bool, sameController: NSSplitViewController? = nil) async throws -> NSSplitViewController {
            // Yield to Observation/SwiftUI and native split animations, including
            // while the window is still unordered. Do not accept a transient match.
            for _ in 0..<25 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let content = window.contentView,
                  let split = Self.findSplitController(in: content),
                  let sidebar = split.splitViewItems.first(where: { $0.behavior == .sidebar }) else {
                throw CheckFailure(description: "Sidebar fixture has no native sidebar split controller")
            }
            if let sameController { try expect(split === sameController) }
            // Prove that the changed root contents actually reached the native host.
            try expect(model.button.title == model.summary)
            func expectCollapsedState() throws {
                guard sidebar.isCollapsed == !visible else {
                    throw CheckFailure(description: "Native sidebar expected visible=\(visible), collapsed=\(sidebar.isCollapsed), ordered=\(window.isVisible), \(model.summary)")
                }
            }
            for _ in 0..<5 {
                window.contentView?.layoutSubtreeIfNeeded()
                try expectCollapsedState()
                try await Task.sleep(for: .milliseconds(20))
            }
            try expectCollapsedState()
            guard model.sidebarVisibility.isVisible == visible else {
                throw CheckFailure(description: "Sidebar preference expected=\(visible), saved=\(model.sidebarVisibility.isVisible), collapsed=\(sidebar.isCollapsed), ordered=\(window.isVisible), \(model.summary)")
            }
            return split
        }

        private static func findSplitController(in view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController,
               controller.splitViewItems.contains(where: { $0.behavior == .sidebar }) {
                return controller
            }
            for child in view.subviews {
                if let controller = findSplitController(in: child) { return controller }
            }
            return nil
        }
    }
}
