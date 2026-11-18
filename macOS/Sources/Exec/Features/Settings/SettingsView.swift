import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void

    var body: some View {
        HSplitView {
            List(selection: Binding<ChatLibrary.SettingsTab?>(
                get: { store.settingsTab },
                set: { if let section = $0 { store.settingsTab = section } }
            )) {
                ForEach(ChatLibrary.SettingsTab.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 0, for: .scrollContent)
            .accessibilityLabel("Settings sections")
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 0) {
                Text(store.settingsTab.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                settingsDetail
                    .contentMargins(.top, 0, for: .scrollContent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 400, idealHeight: 560)
    }

    @ViewBuilder private var settingsDetail: some View {
        switch store.settingsTab {
        case .modelsAndTools:
            ModelsAndToolsSettingsView(store: store)
        case .tools:
            ToolsSettingsView(store: store)
        case .systemPrompt:
            SystemPromptSettingsView(store: store)
        case .accounts:
            ProviderSettingsView(store: store)
        case .remoteAccess:
            RemoteAccessSettingsView(api: store.remoteAPI)
        case .usage:
            UsageSettingsView(store: store)
        case .updates:
            UpdatesSettingsView(canCheckForUpdates: canCheckForUpdates, checkForUpdates: checkForUpdates)
        }
    }
}

private extension ChatLibrary.SettingsTab {
    var title: String {
        switch self {
        case .modelsAndTools: "General"
        case .tools: "Tools"
        case .systemPrompt: "System Prompt"
        case .accounts: "Providers"
        case .remoteAccess: "Remote Access"
        case .usage: "Usage"
        case .updates: "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .modelsAndTools: "gearshape"
        case .tools: "wrench.and.screwdriver"
        case .systemPrompt: "text.alignleft"
        case .accounts: "person.crop.circle"
        case .remoteAccess: "iphone.and.arrow.forward"
        case .usage: "chart.bar"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}
