import SwiftUI

/// SwiftUI menu toggles use native macOS checked menu items.
struct SessionToolMenu: View {
    let conversation: ChatStore

    var body: some View {
        Menu {
            ForEach(SessionTool.names, id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { !conversation.disabledTools.contains(name) },
                    set: { conversation.setToolEnabled(name, $0) }))
            }
            .disabled(!conversation.canSelectTools)
        } label: {
            Label("Session tools", systemImage: "slider.horizontal.3")
        }
        .menuIndicator(.hidden)
        .help("Session tools")
    }
}
