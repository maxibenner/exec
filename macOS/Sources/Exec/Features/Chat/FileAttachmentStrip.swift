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
                    }
                    .padding(.trailing, remove == nil ? 0 : 12)
                    .padding(10)
                    .frame(height: 60)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        if let remove {
                            AttachmentRemoveButton(name: file.name) { remove(file.id) }
                        }
                    }
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
