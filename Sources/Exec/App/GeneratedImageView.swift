import SwiftUI
import UniformTypeIdentifiers

struct GeneratedImageView: View {
    let attachment: ImageAttachment
    @State private var saveError: String?
    @State private var savePanel: NSSavePanel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = NSImage(data: attachment.data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxHeight: 480)
                    .accessibilityLabel("Generated image")
            }
            Button("Save Image…", systemImage: "square.and.arrow.down") {
                guard savePanel == nil else { return }
                let window = NSApp.keyWindow ?? NSApp.mainWindow
                let panel = NSSavePanel()
                savePanel = panel
                panel.nameFieldStringValue = attachment.name
                panel.allowedContentTypes = [attachment.mediaType == "image/png" ? .png : .jpeg]
                let completion: (NSApplication.ModalResponse) -> Void = { response in
                    savePanel = nil
                    guard response == .OK, let url = panel.url else { return }
                    do { try attachment.data.write(to: url, options: .atomic) }
                    catch { saveError = error.localizedDescription }
                }
                NSApp.activate(ignoringOtherApps: true)
                if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
                else { panel.begin(completionHandler: completion) }
            }
            .buttonStyle(.borderless)
            .disabled(savePanel != nil)
        }
        .alert("Could not save image", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
}
