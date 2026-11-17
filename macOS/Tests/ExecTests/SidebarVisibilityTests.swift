import AppKit
import Observation
import SwiftUI

@MainActor struct SidebarVisibilityTests {
    func appliesInitialVisibilityBeforeOrderingWindowFront() async throws {
        for count in [0, 1, 2] {
            let fixture = Fixture(sessionCount: count)
            defer { fixture.dispose() }

            try expect(!fixture.window.isVisible)
            try await fixture.expectSidebar(visible: count > 1)
            try expect(!fixture.window.isVisible)

            fixture.window.orderFront(nil)
            try await fixture.expectSidebar(visible: count > 1)
        }
    }

    func nativeToggleSurvivesContentCountAndFocusChanges() async throws {
        // Exercise both opening an initially closed sidebar and closing an open one.
        for count in [1, 2] {
            let fixture = Fixture(sessionCount: count)
            defer { fixture.dispose() }
            let split = try await fixture.expectSidebar(visible: count > 1)
            fixture.window.orderFront(nil)
            split.toggleSidebar(nil)
            let manuallyVisible = count == 1
            try await fixture.expectSidebar(visible: manuallyVisible, sameController: split)

            // Recompute the root, including initiallyShowsSidebar changing true -> false.
            // Neither that input nor ordinary detail updates may reset the user's choice.
            for updatedCount in [2, 1] {
                fixture.model.sessionCount = updatedCount
                fixture.model.contentRevision += 1
                try await fixture.expectSidebar(visible: manuallyVisible, sameController: split)
                try fixture.clickAndFocusDetail()
                try await fixture.expectSidebar(visible: manuallyVisible, sameController: split)
            }
        }
    }

    func revealRequestsOpenOnceAndRespectSubsequentManualClose() async throws {
        let fixture = Fixture(sessionCount: 1)
        defer { fixture.dispose() }
        let split = try await fixture.expectSidebar(visible: false)
        fixture.window.orderFront(nil)

        fixture.model.sidebarRevealRequest += 1
        try await fixture.expectSidebar(visible: true, sameController: split)
        fixture.model.contentRevision += 1
        try await fixture.expectSidebar(visible: true, sameController: split)

        split.toggleSidebar(nil)
        try await fixture.expectSidebar(visible: false, sameController: split)
        for count in [2, 1] {
            fixture.model.sessionCount = count
            fixture.model.contentRevision += 1
            try await fixture.expectSidebar(visible: false, sameController: split)
            try fixture.clickAndFocusDetail()
            try await fixture.expectSidebar(visible: false, sameController: split)
        }
        try expect(fixture.model.sidebarRevealRequest == 1)

        fixture.model.sidebarRevealRequest += 1
        try await fixture.expectSidebar(visible: true, sameController: split)
    }

    @MainActor @Observable final class Model: NSObject {
        var sessionCount: Int
        var contentRevision = 0
        var sidebarRevealRequest = 0
        var clicks = 0
        let button = NSButton(title: "Update detail", target: nil, action: nil)
        let editor = NSTextField(string: "Isolated draft")

        var summary: String {
            "Sessions: \(sessionCount), content: \(contentRevision), clicks: \(clicks)"
        }

        init(sessionCount: Int) {
            self.sessionCount = sessionCount
            super.init()
            button.target = self
            button.action = #selector(updateDetail)
        }

        @objc private func updateDetail() { clicks += 1 }
    }

    private struct Root: View {
        let model: Model

        var body: some View {
            ChatWindowLayout(initiallyShowsSidebar: model.sessionCount > 1,
                             sidebarRevealRequest: model.sidebarRevealRequest) {
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

        init(sessionCount: Int) {
            _ = NSApplication.shared
            model = Model(sessionCount: sessionCount)
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
            for _ in 0..<5 {
                window.contentView?.layoutSubtreeIfNeeded()
                try expect(sidebar.isCollapsed == !visible)
                try await Task.sleep(for: .milliseconds(20))
            }
            try expect(sidebar.isCollapsed == !visible)
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
