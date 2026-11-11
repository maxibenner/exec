import SwiftUI

/// Keep the split view and sizing constraints mounted while local data
/// becomes available. Startup changes the contents, not the window's structure.
struct ChatWindowLayout<Sidebar: View, Detail: View>: View {
    @State private var columnVisibility: NavigationSplitViewVisibility
    private let sidebarRevealRequest: Int
    private let sidebar: Sidebar
    private let detail: Detail

    init(initiallyShowsSidebar: Bool, sidebarRevealRequest: Int = 0,
         @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        _columnVisibility = State(initialValue: initiallyShowsSidebar || sidebarRevealRequest > 0 ? .all : .detailOnly)
        self.sidebarRevealRequest = sidebarRevealRequest
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                // Fit beside the widest sidebar (320) at the window minimum (720).
                .frame(minWidth: 400, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .background(.background)
                .background(SidebarResizeBehavior())
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: sidebarRevealRequest) { _, _ in
            columnVisibility = .all
        }
        .background(WindowReference { ChatWindowAppearance.configure($0) })
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }
}
