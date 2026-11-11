import SwiftUI

/// Keep the split view and sizing constraints mounted while local data
/// becomes available. Startup changes the contents, not the window's structure.
struct ChatWindowLayout<Sidebar: View, Detail: View>: View {
    private let initiallyShowsSidebar: Bool
    private let sidebarRevealRequest: Int
    private let sidebar: Sidebar
    private let detail: Detail

    init(initiallyShowsSidebar: Bool, sidebarRevealRequest: Int = 0,
         @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.initiallyShowsSidebar = initiallyShowsSidebar
        self.sidebarRevealRequest = sidebarRevealRequest
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        // Native toolbar and keyboard actions own collapse state. A second,
        // externally bound visibility value can replay stale state on an update.
        NavigationSplitView {
            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keep the same surface before and after the session list mounts.
                .background(.background.secondary)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                // Fit beside the widest sidebar (320) at the window minimum (720).
                .frame(minWidth: 400, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .background(.background)
                .background(SidebarResizeBehavior(initiallyShowsSidebar: initiallyShowsSidebar,
                                                  revealRequest: sidebarRevealRequest))
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowReference { ChatWindowAppearance.configure($0) })
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }
}
