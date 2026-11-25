import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding<ChatLibrary.SettingsTab?>(
                get: { store.settingsTab },
                set: { if let section = $0 { store.settingsTab = section } }
            )) {
                ForEach(ChatLibrary.SettingsTab.allCases, id: \.self) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.systemImage)
                            // Preserve native tint while compositing each symbol once.
                            .drawingGroup()
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 0, for: .scrollContent)
            .accessibilityLabel("Settings sections")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            settingsDetail
                .tint(nil)
                .accentColor(nil)
                .buttonStyle(.bordered)
                .contentMargins(.top, 0, for: .scrollContent)
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.background)
                .background(SettingsWindowConfiguration())
                .ignoresSafeArea(.container, edges: .top)
        }
        .toolbar(.visible, for: .windowToolbar)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 740, idealWidth: 800, minHeight: 400, idealHeight: 560)
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
            RemoteAccessSettingsView(settings: store.remoteAccessSettings)
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
