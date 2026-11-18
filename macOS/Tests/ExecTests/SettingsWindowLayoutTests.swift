import AppKit
import SwiftUI

@MainActor struct SettingsWindowLayoutTests {
    func nativeHeaderKeepsSidebarVisibleAcrossSections() async throws {
        let suite = "exec-settings-layout-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let store = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())),
                                preferences: preferences)
        let root = SettingsView(store: store, canCheckForUpdates: false, checkForUpdates: {})
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "Exec Settings"
        window.setContentSize(CGSize(width: 760, height: 560))
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            store.closePresentations()
            preferences.removePersistentDomain(forName: suite)
        }

        for section: ChatLibrary.SettingsTab in [.modelsAndTools, .tools, .systemPrompt] {
            store.settingsTab = section
            for _ in 0..<20 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let content = window.contentView,
                  let split = findSplit(in: content),
                  let sidebar = split.splitViewItems.first(where: { $0.behavior == .sidebar }),
                  let detail = split.splitViewItems.last,
                  let toolbar = window.toolbar else {
                throw CheckFailure(description: "Settings must have a native split view and toolbar")
            }
            try expect(window.titleVisibility == .hidden && window.toolbarStyle == .unified)
            try expect(!sidebar.canCollapse && !sidebar.isCollapsed)
            try expect(!toolbar.items.contains { $0.itemIdentifier == .toggleSidebar })
            let sidebarTop = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: nil).maxY
            let detailTop = detail.viewController.view.convert(detail.viewController.view.bounds, to: nil).maxY
            try expect(abs(sidebarTop - detailTop) < 1)
            // No custom toolbar view may recreate a section-title button.
            try expect(toolbar.items.allSatisfy { $0 is NSTrackingSeparatorToolbarItem || $0.view == nil })
            guard let detailContent = findDetailContent(in: detail.viewController.view) else {
                throw CheckFailure(description: "Missing settings content")
            }
            let contentTop = detailContent.convert(detailContent.bounds, to: nil).maxY
            try expect(abs(contentTop - detailTop) < 1)
        }
    }

    private func findDetailContent(in view: NSView) -> SettingsWindowConfiguration.ConfigurationView? {
        if let content = view as? SettingsWindowConfiguration.ConfigurationView { return content }
        for child in view.subviews {
            if let content = findDetailContent(in: child) { return content }
        }
        return nil
    }

    private func findSplit(in view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           controller.splitViewItems.contains(where: { $0.behavior == .sidebar }) {
            return controller
        }
        for child in view.subviews {
            if let split = findSplit(in: child) { return split }
        }
        return nil
    }
}
