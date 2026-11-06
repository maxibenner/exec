import SwiftUI
import UniformTypeIdentifiers

struct GeneratedImageView: View {
    let attachment: ImageAttachment
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = NSImage(data: attachment.data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxHeight: 480)
                    .accessibilityLabel("Generated image")
            }
            Button("Save Image…", systemImage: "square.and.arrow.down") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = attachment.name
                panel.allowedContentTypes = [attachment.mediaType == "image/png" ? .png : .jpeg]
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    do { try attachment.data.write(to: url, options: .atomic) }
                    catch { saveError = error.localizedDescription }
                }
            }
            .buttonStyle(.borderless)
        }
        .alert("Could not save image", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
}
