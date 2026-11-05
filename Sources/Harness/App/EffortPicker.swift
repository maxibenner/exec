import SwiftUI

struct EffortPicker: View {
    @Bindable var store: ChatLibrary

    private var defaultName: String {
        guard let model = store.current.model,
              let effort = model.efforts.first(where: { $0.id == model.defaultEffort }) else { return "Default effort" }
        return "Default (\(effort.name))"
    }

    var body: some View {
        Picker("Effort", selection: $store.selectedEffort) {
            Text(defaultName).tag(String?.none)
            ForEach(store.current.model?.efforts ?? []) { effort in
                Text(effort.name).tag(Optional(effort.id)).help(effort.description)
            }
        }
        .labelsHidden().pickerStyle(.menu).controlSize(.small)
        .frame(maxWidth: 150).fixedSize(horizontal: true, vertical: false)
        .disabled(store.busy || store.current.model?.efforts.isEmpty != false)
        .help("Reasoning effort").accessibilityLabel("Reasoning effort")
    }
}
