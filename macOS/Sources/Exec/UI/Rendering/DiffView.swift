import AppKit
import SwiftUI

struct DiffView: View {
    let source: String
    var isApprovalPreview = false
    var isFileRead = false

    static let lineHeight: CGFloat = 22
    @State private var cache = RenderCache()

    @ViewBuilder var body: some View {
        let diff = cache.value(for: source, showsLaterHunkHeaders: isApprovalPreview, isFileRead: isFileRead)
        let code = DiffCodeView(diff: diff)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if isApprovalPreview {
            let height = CGFloat(diff.lineCount) * Self.lineHeight - RenderedDiff.interlineSpacing + 2 * DiffCodeSurface.codeInset
            // Keep horizontal scrolling inside the inset, with a pinned gutter.
            ScrollView(.vertical) {
                code.padding(.horizontal, DiffCodeSurface.codeInset)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: min(220, max(60, height)))
        } else {
            code
        }
    }

    @MainActor final class RenderCache {
        private var source: String?
        private var showsLaterHunkHeaders = false
        private var isFileRead = false
        private var rendered: RenderedDiff?

        func value(for source: String, showsLaterHunkHeaders: Bool = false, isFileRead: Bool = false) -> RenderedDiff {
            if self.source == source, self.showsLaterHunkHeaders == showsLaterHunkHeaders,
               self.isFileRead == isFileRead, let rendered { return rendered }
            let value = isFileRead ? RenderedDiff(fileRead: source)
                : RenderedDiff(source, showsLaterHunkHeaders: showsLaterHunkHeaders)
            self.source = source
            self.showsLaterHunkHeaders = showsLaterHunkHeaders
            self.isFileRead = isFileRead
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
        let lineCount: Int
        let showsChangeMarkers: Bool

        static let interlineSpacing = max(0, DiffView.lineHeight - NSLayoutManager().defaultLineHeight(for: font))

        convenience init(_ source: String, showsLaterHunkHeaders: Bool = false) {
            self.init(lines: DiffDocument(source, showsLaterHunkHeaders: showsLaterHunkHeaders).lines,
                      showsChangeMarkers: true)
        }

        convenience init(fileRead output: String) {
            var rows = output.components(separatedBy: "\n")
            if rows.last == "" { rows.removeLast() }
            let hasRevision = rows.first?.hasPrefix("Revision: ") == true
            var previous: Int?
            var readingNumberedRows = hasRevision
            let lines = rows.dropFirst(hasRevision ? 1 : 0).map { row -> DiffDocument.Line in
                let raw = row.last == "\r" ? String(row.dropLast()) : row
                if readingNumberedRows, let colon = raw.firstIndex(of: ":"),
                   let number = Int(raw[..<colon]), number > 0,
                   previous.map({ number > $0 && number - $0 == 1 }) ?? true {
                    previous = number
                    let body = raw[raw.index(after: colon)...]
                    // Only remove the one space added by the backend, not file indentation.
                    let text = body.first == " " ? body.dropFirst() : body
                    return .init(text: String(text), kind: .context, number: number)
                }
                readingNumberedRows = false
                return .init(text: raw, kind: .note, number: nil)
            }
            self.init(lines: lines, showsChangeMarkers: false)
        }

        private init(lines: [DiffDocument.Line], showsChangeMarkers: Bool) {
            self.showsChangeMarkers = showsChangeMarkers
            lineCount = lines.count
            let styled = NSMutableAttributedString(string: "")
            let paragraph = NSMutableParagraphStyle()
            // Put extra leading between rows, not above the first glyphs.
            paragraph.paragraphSpacing = Self.interlineSpacing
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
