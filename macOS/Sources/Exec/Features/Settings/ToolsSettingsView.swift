import SwiftUI

struct ToolsSettingsView: View {
    let store: ChatLibrary

    var body: some View {
        Form {
            ForEach(SessionTool.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(SessionTool.all.filter { $0.group == group }) { tool in
                        Toggle(isOn: Binding(
                            get: { !store.defaultDisabledTools.contains(tool.name) },
                            set: { store.setDefaultToolEnabled(tool.name, $0) }
                        )) {
                            Label(tool.label, systemImage: tool.icon)
                        }
                        .toggleStyle(.checkbox)
                        .tint(AppColors.systemAccent).accentColor(AppColors.systemAccent)
                        .accessibilityIdentifier("default-tool-\(tool.name)")
                    }
                } header: {
                    Text(group.rawValue)
                } footer: {
                    if group == .execute {
                        Text("Sets the default tools available in a new session. Existing sessions keep their tool selections.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
