import SwiftUI

struct GeneratedImageView: View {
    let attachment: ImageAttachment

    var body: some View {
        if let image = NSImage(data: attachment.data) {
            ToolImageView(image: image, accessibilityTitle: "Generated image")
        }
    }
}

struct ToolImageView: View {
    let image: NSImage
    let accessibilityTitle: String

    var body: some View {
        Image(nsImage: image).resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxHeight: 480)
            .accessibilityLabel(Text(verbatim: accessibilityTitle))
    }
}
