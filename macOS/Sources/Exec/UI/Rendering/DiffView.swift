import AppKit
import SwiftUI

struct DiffView: View {
    let source: String
    var showsPatchHeaders = false

    static let lineHeight: CGFloat = 22
    @State private var cache = RenderCache()

    var body: some View {
        DiffCodeView(diff: cache.value(for: source, showsPatchHeaders: showsPatchHeaders))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor final class RenderCache {
        private var source: String?
        private var showsPatchHeaders = false
        private var rendered: RenderedDiff?

        func value(for source: String, showsPatchHeaders: Bool = false) -> RenderedDiff {
            if self.source == source, self.showsPatchHeaders == showsPatchHeaders, let rendered { return rendered }
            let value = RenderedDiff(source, showsPatchHeaders: showsPatchHeaders)
            self.source = source
            self.showsPatchHeaders = showsPatchHeaders
            rendered = value
            return value
        }
    }

    // Kept with the view, not in a global cache retaining conversation contents.
    @MainActor final class RenderedDiff {
        struct GutterEntry {
            let number: Int?
            let kind: DiffDocument.Kind
        }

        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Primer's success/danger foregrounds and diffBlob word fills are separate tokens.
        static let addition = color(light: 0x1A7F37, dark: 0x3FB950)
        static let removal = color(light: 0xD1242F, dark: 0xF85149)
        private static let additionHighlight = color(light: 0xACEEBB, dark: 0x2EA043, darkAlpha: 0.40)
        private static let removalHighlight = color(light: 0xFFCECB, dark: 0xF85149, darkAlpha: 0.40)

        let text: NSAttributedString
        // Keys are UTF-16 offsets in the selectable code, not in the raw patch.
        let gutter: [Int: GutterEntry]
        let numberDigits: Int

        init(_ source: String, showsPatchHeaders: Bool = false) {
            let lines = DiffDocument(source, showsPatchHeaders: showsPatchHeaders).lines
            let styled = NSMutableAttributedString(string: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = DiffView.lineHeight
            var gutter: [Int: GutterEntry] = [:]
            var highestNumber = 0
            for (index, line) in lines.enumerated() {
                let offset = styled.length
                if line.number != nil || line.kind == .added || line.kind == .removed {
                    gutter[offset] = GutterEntry(number: line.number, kind: line.kind)
                    highestNumber = max(highestNumber, line.number ?? 0)
                }
                // A final blank row still needs a glyph to align its number and marker.
                let newline = index < lines.count - 1 || line.text.isEmpty ? "\n" : ""
                let isAnnotation = line.kind == .note || line.kind == .header
                styled.append(NSAttributedString(string: line.text + newline, attributes: [
                    .font: Self.font, .paragraphStyle: paragraph,
                    .foregroundColor: isAnnotation ? NSColor.secondaryLabelColor : NSColor.labelColor
                ]))
                if let span = line.emphasis {
                    styled.addAttribute(.backgroundColor,
                                        value: line.kind == .added ? Self.additionHighlight : Self.removalHighlight,
                                        range: NSRange(location: offset + span.location, length: span.length))
                }
            }
            text = styled
            self.gutter = gutter
            numberDigits = String(highestNumber).count
        }

        private static func color(light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let rgb = isDark ? dark : light
                return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                               green: CGFloat((rgb >> 8) & 0xFF) / 255,
                               blue: CGFloat(rgb & 0xFF) / 255,
                               alpha: isDark ? darkAlpha : 1)
            }
        }
    }
}
