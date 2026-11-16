import SwiftUI

struct AttachmentRemoveButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(.black.opacity(0.8))
                .frame(width: 13, height: 13)
                .overlay {
                    Image(systemName: "xmark")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 6, height: 6)
                }
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove \(name)")
        .accessibilityLabel("Remove \(name)")
    }
}
