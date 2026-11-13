import SwiftUI

struct UpdatesSettingsView: View {
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
            } footer: {
                Button("Check for Updates…", action: checkForUpdates)
                    .buttonStyle(.bordered)
                    .disabled(!canCheckForUpdates)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return version
        }
        return "\(version) (\(build))"
    }
}
