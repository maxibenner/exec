import AppKit
import SwiftUI

@MainActor struct AttachmentRemoveButtonTests {
    func marksStayCentered() throws {
        for scale: CGFloat in [1, 2] {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: AttachmentRemoveButton(name: "Attachment", action: {})
                    .environment(\.colorScheme, scheme))
                renderer.scale = scale
                guard let image = renderer.cgImage else {
                    throw CheckFailure(description: "Missing attachment remove button rendering")
                }
                let bitmap = NSBitmapImageRep(cgImage: image)
                try expect(bitmap.pixelsWide == Int(25 * scale))
                try expect(bitmap.pixelsHigh == Int(25 * scale))
                let fill = bitmap.colorAt(x: Int(8 * scale), y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                var mass: CGFloat = 0
                var xMoment: CGFloat = 0
                var yMoment: CGFloat = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        // Measure the white mark relative to the gray fill.
                        let weight = max(0, color.redComponent - fill.redComponent) * color.alphaComponent
                        mass += weight
                        xMoment += (CGFloat(x) + 0.5) * weight
                        yMoment += (CGFloat(y) + 0.5) * weight
                    }
                }
                try expect(mass > 3 * scale * scale)
                try expect(abs(xMoment / mass - CGFloat(bitmap.pixelsWide) / 2) < 0.2)
                try expect(abs(yMoment / mass - CGFloat(bitmap.pixelsHigh) / 2) < 0.2)
            }
        }
    }
}
