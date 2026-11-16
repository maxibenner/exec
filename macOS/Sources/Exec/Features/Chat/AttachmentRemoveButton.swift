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
                    // Draw around the same center as the circle, without symbol
                    // alignment metrics shifting the tiny mark at 1× scale.
                    AttachmentRemoveMark()
                        .stroke(.white, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: 5, height: 5)
                }
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove \(name)")
        .accessibilityLabel("Remove \(name)")
    }
}

private struct AttachmentRemoveMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
    }
}
