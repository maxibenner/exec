import SwiftUI

struct PairingQRCodePopup: View {
    let code: PairingQRCode
    var pasteboard: NSPasteboard = .general
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pairing QR Code").font(.headline)
            Image(nsImage: code.image)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Pairing QR code")
            HStack {
                Button("Copy", action: copyToClipboard)
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(.bordered)
        .tint(nil)
        .accentColor(nil)
        .padding(24)
        .frame(width: 320)
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
