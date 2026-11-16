import SwiftUI

struct AttachmentRemoveButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.8))
                .font(.system(size: 13))
                .frame(width: 13, height: 13)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove \(name)")
        .accessibilityLabel("Remove \(name)")
    }
}
