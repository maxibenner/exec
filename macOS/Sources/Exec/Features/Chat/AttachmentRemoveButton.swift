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
    var delaysDimming = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Circle()
                .fill(.black.opacity(0.42))
                .frame(width: 13, height: 13)
                .overlay {
                    // Draw around the same center as the circle, without symbol
                    // alignment metrics shifting the tiny mark at 1× scale.
                    RemoveMark()
                        .stroke(.white, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: 5, height: 5)
                }
                // Shared inset when anchored in the top-trailing corner.
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoveButtonStyle(delaysDimming: delaysDimming))
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct RemoveButtonStyle: ButtonStyle {
    let delaysDimming: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.5)
            // The button is disabled immediately, but ignore short queue locks visually.
            .animation(delaysDimming && !isEnabled ? .easeIn(duration: 0.12).delay(0.18) : nil,
                       value: isEnabled)
            .opacity(isEnabled && configuration.isPressed ? 0.75 : 1)
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
