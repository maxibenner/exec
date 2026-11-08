import SwiftUI

/// Keep the split view, toolbar and sizing constraints mounted while local data
/// becomes available. Startup changes the contents, not the window's structure.
struct ChatWindowLayout<Sidebar: View, Detail: View>: View {
    let workspace: URL?
    @State private var columnVisibility: NavigationSplitViewVisibility
    private let sidebar: Sidebar
    private let detail: Detail

    init(workspace: URL?, initiallyShowsSidebar: Bool,
         @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.workspace = workspace
        _columnVisibility = State(initialValue: initiallyShowsSidebar ? .all : .detailOnly)
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keep the same surface before and after the session list mounts.
                .background(.background.secondary)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(minWidth: 460, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .background(.background)
                .background(SidebarResizeBehavior())
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarItem(placement: .primaryAction) { workspaceItem }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .primaryAction) { workspaceItem }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    private var workspaceItem: some View {
        WorkspaceBar(root: workspace)
            .frame(maxWidth: 300)
            .padding(.trailing, 14)
    }
}
