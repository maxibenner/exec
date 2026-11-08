import SwiftUI

struct UpdatesSettingsView: View {
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                Button("Check for Updates…", action: checkForUpdates)
                    .disabled(!canCheckForUpdates)
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
