import AppKit
import SwiftUI

struct DiffView: View {
    let source: String

    @State private var cache = RenderCache()

    var body: some View {
        DiffCodeView(diff: cache.value(for: source))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor final class RenderCache {
        private var source: String?
        private var rendered: RenderedDiff?

        func value(for source: String) -> RenderedDiff {
            if self.source == source, let rendered { return rendered }
            let value = RenderedDiff(source)
            self.source = source
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

        init(_ source: String) {
            let lines = DiffDocument(source).lines
            let styled = NSMutableAttributedString(string: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 22
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
                styled.append(NSAttributedString(string: line.text + newline, attributes: [
                    .font: Self.font, .paragraphStyle: paragraph,
                    .foregroundColor: line.kind == .note ? NSColor.secondaryLabelColor : NSColor.labelColor
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

    // Before approval, show the raw patch, including the file it would change.
    static func highlighted(_ source: String) -> AttributedString {
        let lines = DiffDocument.sourceLines(source)
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var text = AttributedString(line.text)
            switch line.kind {
            case .added: text.backgroundColor = Color.green.opacity(0.24)
            case .removed: text.backgroundColor = AppColors.subduedRed
            case .header: text.foregroundColor = Color.secondary
            case .note where line.text.hasPrefix("\\"): text.foregroundColor = Color.secondary
            default: break
            }
            result.append(text)
            if index < lines.count - 1 || source.utf8.last == 0x0A {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }
}
