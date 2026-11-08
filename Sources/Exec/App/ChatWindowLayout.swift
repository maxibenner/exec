import SwiftUI

/// Keep the split view, toolbar and sizing constraints mounted while local data
/// becomes available. Startup changes the contents, not the window's structure.
struct ChatWindowLayout<Sidebar: View, Detail: View>: View {
    let workspace: URL?
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(minWidth: 460, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarItem(placement: .primaryAction) { workspaceItem }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .primaryAction) { workspaceItem }
                    }
                }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    private var workspaceItem: some View {
        WorkspaceBar(root: workspace)
            .frame(maxWidth: 300)
            .padding(.trailing, 14)
    }
}
