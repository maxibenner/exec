import SwiftUI

struct AttachmentStrip: View {
    let images: [ImageAttachment]
    var remove: ((UUID) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(images) { image in
                    AttachmentThumbnail(attachment: image)
                        .overlay(alignment: .topTrailing) {
                            if let remove {
                                Button { remove(image.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.8))
                                        .font(.system(size: 18))
                                }
                                .buttonStyle(.plain).padding(3)
                                .help("Remove \(image.name)")
                                .accessibilityLabel("Remove \(image.name)")
                            }
                        }
                }
            }
            .padding(2)
        }
        .scrollIndicators(.hidden)
    }
}

private struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 100, height: 80)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(attachment.name)
        .accessibilityLabel("Attached image: \(attachment.name)")
        .task(id: attachment.id) { image = NSImage(data: attachment.data) }
    }
}
