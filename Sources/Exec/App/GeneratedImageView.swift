import SwiftUI

struct GeneratedImageView: View {
    let attachment: ImageAttachment

    var body: some View {
        if let image = NSImage(data: attachment.data) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxHeight: 480)
                .accessibilityLabel("Generated image")
        }
    }
}
