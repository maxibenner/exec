import SwiftUI

/// Keep the split view, toolbar and sizing constraints mounted while local data
/// becomes available. Startup changes the contents, not the window's structure.
struct ChatWindowLayout<Sidebar: View, Detail: View>: View {
    let workspace: URL?
    // nil while the local session catalog is still loading.
    var hasSessions: Bool? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var didSetInitialVisibility = false
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
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
        .onChange(of: hasSessions, initial: true) { _, hasSessions in
            guard !didSetInitialVisibility, let hasSessions else { return }
            didSetInitialVisibility = true
            columnVisibility = hasSessions ? .all : .detailOnly
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    private var workspaceItem: some View {
        WorkspaceBar(root: workspace)
            .frame(maxWidth: 300)
            .padding(.trailing, 14)
    }
}
