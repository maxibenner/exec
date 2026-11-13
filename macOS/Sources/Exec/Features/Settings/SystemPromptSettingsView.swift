import SwiftUI

struct SystemPromptSettingsView: View {
    let store: ChatLibrary

    var body: some View {
        @Bindable var settings = store
        Form {
            TextEditor(text: $settings.systemPrompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260, maxHeight: .infinity)
                .accessibilityLabel("System prompt")
        }
        .formStyle(.grouped)
    }
}
