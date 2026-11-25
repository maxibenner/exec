import SwiftUI

struct ToolsSettingsView: View {
    let store: ChatLibrary
    @State private var availability = ToolAvailabilityObserver()

    var body: some View {
        let query = store.defaultToolAvailabilityQuery
        Form {
            ForEach(SessionTool.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(SessionTool.all.filter { $0.group == group }) { tool in
                        let status = availability.status(for: tool.name, query: query)
                        let unavailable = status?.available == false
                        Toggle(isOn: Binding(
                            get: { !store.defaultDisabledTools.contains(tool.name) },
                            set: { store.setDefaultToolEnabled(tool.name, $0) }
                        )) {
                            Label(tool.label, systemImage: tool.icon)
                                .opacity(unavailable ? 0.35 : 1)
                        }
                        .toggleStyle(.checkbox)
                        .tint(AppColors.systemAccent).accentColor(AppColors.systemAccent)
                        .accessibilityIdentifier("default-tool-\(tool.name)")
                        .accessibilityLabel(tool.label)
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
        .task(id: query) {
            await availability.observe(query: query, api: store.toolAvailabilityAPI)
        }
    }
}
