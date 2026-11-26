import SwiftUI

struct PairingQRCodePopup: View {
    let code: PairingQRCode
    var pasteboard: NSPasteboard = .general
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: code.image)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Pairing QR code")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Copy to clipboard", action: copyToClipboard)
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.blue)
            }
        }
        .buttonStyle(.bordered)
        .tint(nil)
        .accentColor(nil)
        .padding(24)
        .frame(width: 292) // 220-point code, 12-point white border, 24-point card insets.
        .background {
            let shape = RoundedRectangle(cornerRadius: 20)
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .onExitCommand(perform: dismiss)
    }

    func copyToClipboard() {
        pasteboard.clearContents()
        pasteboard.setString(code.text, forType: .string)
    }
}
