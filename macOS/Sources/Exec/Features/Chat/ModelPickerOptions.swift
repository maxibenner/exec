import SwiftUI

struct ProviderModelGroup: Identifiable {
    let id: String
    let name: String
    let models: [ChatModel]
}

/// All model menus use the library's authenticated catalog, never saved IDs.
struct ModelPickerOptions: View {
    let groups: [ProviderModelGroup]

    var body: some View {
        ForEach(groups) { group in
            if groups.count > 1 {
                Section(group.name) {
                    ForEach(group.models) { Text($0.name).tag($0.id) }
                }
            } else {
                ForEach(group.models) { Text($0.name).tag($0.id) }
            }
        }
    }
}
