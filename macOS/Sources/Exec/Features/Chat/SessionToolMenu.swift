import SwiftUI

/// A popover keeps the native checkboxes available across multiple selection changes.
struct SessionToolMenu: View {
    let conversation: ChatStore
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false
    @State private var availability = ToolAvailabilityObserver()

    var body: some View {
        let query = conversation.toolAvailabilityQuery
        Button {
            isPresented.toggle()
        } label: {
            Label("Session tools", systemImage: "slider.horizontal.3")
        }
        .help("Session tools")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SessionTool.Group.allCases, id: \.self) { group in
                    GroupBox(group.rawValue) {
                        VStack(spacing: 8) {
                            ForEach(SessionTool.all.filter { $0.group == group }) { tool in
                                toolRow(tool, query: query)
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .controlSize(.regular)
            .padding(12)
            .frame(width: 280)
            .disabled(!isEnabled || !conversation.canSelectTools)
            .task(id: query) {
                await availability.observe(query: query, api: conversation.provider.api)
            }
        }
    }

    private func toolRow(_ tool: SessionTool, query: ToolAvailabilityQuery) -> some View {
        let status = availability.status(for: tool.name, query: query)
        let unavailable = status?.available != true
        return HStack(spacing: 8) {
            Image(systemName: tool.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(verbatim: tool.label)
                .accessibilityHidden(true)
            Spacer(minLength: 16)
            Toggle(tool.label, isOn: Binding(
                get: { !conversation.disabledTools.contains(tool.name) },
                set: { if !unavailable { conversation.setToolEnabled(tool.name, $0) } }))
                .toggleStyle(.checkbox)
                .tint(AppColors.systemAccent).accentColor(AppColors.systemAccent)
                .labelsHidden()
                .accessibilityIdentifier(tool.name)
        }
        .disabled(unavailable)
        .opacity(unavailable ? 0.35 : 1)
    }
}
