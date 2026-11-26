import SwiftUI

struct AttachmentRemoveButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        ChatRemoveButton(label: "Remove \(name)", action: action)
    }
}

struct ChatRemoveButton: View {
    let label: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role, action: action) {
            Circle()
                .fill(.gray)
                .frame(width: 13, height: 13)
                .overlay {
                    // Draw around the same center as the circle, without symbol
                    // alignment metrics shifting the tiny mark at 1× scale.
                    RemoveMark()
                        .stroke(.white, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: 5, height: 5)
                }
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.5)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct RemoveMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
    }
}
