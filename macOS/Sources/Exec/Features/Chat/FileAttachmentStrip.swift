import SwiftUI

struct FileAttachmentStrip: View {
    let files: [FileAttachment]
    var remove: ((UUID) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
                        Text(file.name).font(.callout).lineLimit(2).frame(maxWidth: 160, alignment: .leading)
                        if let remove {
                            Button { remove(file.id) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(file.name)")
                            .accessibilityLabel("Remove \(file.name)")
                        }
                    }
                    .padding(10)
                    .frame(height: 60)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .help(file.name)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Attached file: \(file.name)")
                }
            }
            .padding(2)
        }
        .scrollIndicators(.hidden)
    }
}
