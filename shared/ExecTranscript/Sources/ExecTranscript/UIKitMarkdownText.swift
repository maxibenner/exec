#if canImport(UIKit)
import UIKit

/// TextKit styling shared by ordinary message text and native scroll blocks.
/// Use UIKitMarkdownView for messages containing tables or fenced code.
@MainActor public enum UIKitMarkdownText {
    public static func render(_ blocks: [MarkdownBlock], width: CGFloat, traits: UITraitCollection? = nil) -> NSAttributedString {
        render(MarkdownBlockLayout.elements(blocks), width: width, traits: traits)
    }

    static func render(_ elements: [MarkdownBlockLayout.Element], width: CGFloat, traits: UITraitCollection?) -> NSAttributedString {
        let renderer = Renderer(width: max(100, width), traits: traits)
        for element in elements { renderer.append(element) }
        if renderer.text.string.hasSuffix("\n") {
            renderer.text.deleteCharacters(in: NSRange(location: renderer.text.length - 1, length: 1))
        }
        return renderer.text
    }

    static func inline(_ source: AttributedString, style: UIFont.TextStyle, bold: Bool = false,
                       code: Bool = false, quote: Bool = false, traits: UITraitCollection?) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            let monospaced = code || intent.contains(.code)
            var font = monospaced ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
            var fontTraits = font.fontDescriptor.symbolicTraits
            if bold || intent.contains(.stronglyEmphasized) { fontTraits.insert(.traitBold) }
            if intent.contains(.emphasized) { fontTraits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(fontTraits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: quote ? UIColor.secondaryLabel : UIColor.label]
            // Fenced code has one continuous native surface, not a background per run/line.
            if monospaced && !code { attributes[.backgroundColor] = UIColor.tertiarySystemFill }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if !code, let link = run.link, MarkdownDocument.allowsLink(link) { attributes[.link] = link }
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        return result
    }

    @MainActor private final class Renderer {
        let text = NSMutableAttributedString(string: "")
        let width: CGFloat
        let traits: UITraitCollection?
        init(width: CGFloat, traits: UITraitCollection?) { self.width = width; self.traits = traits }
        func append(_ element: MarkdownBlockLayout.Element) {
            let block = element.block
            let indent = CGFloat(element.indent), marker = element.marker, quote = element.quoted
            switch block.kind {
            case .header(let level):
                paragraph(block.text, indent: indent, marker: marker, style: level == 1 ? .title1 : level == 2 ? .title2 : .headline, bold: true, quote: quote)
            case .codeBlock(let language):
                if let language, !language.isEmpty { paragraph(AttributedString(language), indent: indent, style: .caption1, quote: true) }
                paragraph(block.text, indent: indent, marker: marker, style: .footnote, code: true, quote: quote)
            case .thematicBreak:
                paragraph(AttributedString("────────"), indent: indent, quote: true)
            case .table(let columns):
                // Plain attributed-text fallback. Production messages use a native grid.
                guard !columns.isEmpty else { return }
                for row in block.children {
                    let content = NSMutableAttributedString(string: "")
                    for column in columns.indices {
                        if column > 0 { content.append(NSAttributedString(string: "\t")) }
                        let cell = row.children.first { $0.kind == .tableCell(columnIndex: column) }?.text ?? AttributedString()
                        content.append(UIKitMarkdownText.inline(cell, style: .footnote, bold: row.kind == .tableHeaderRow, traits: traits))
                    }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.paragraphSpacing = 8
                    paragraph.tabStops = columns.indices.dropFirst().map { index in
                        let alignment: NSTextAlignment = columns[index].alignment == .right ? .right : columns[index].alignment == .center ? .center : .left
                        return NSTextTab(textAlignment: alignment, location: width * CGFloat(index) / CGFloat(columns.count))
                    }
                    content.append(NSAttributedString(string: "\n"))
                    content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
                    text.append(content)
                }
            default:
                paragraph(block.text, indent: indent, marker: marker, quote: quote)
            }
        }
        private func paragraph(_ source: AttributedString, indent: CGFloat, marker: String? = nil,
                               style: UIFont.TextStyle = .body, bold: Bool = false, code: Bool = false, quote: Bool = false) {
            let content = UIKitMarkdownText.inline(source, style: style, bold: bold, code: code, quote: quote, traits: traits)
            if let marker { content.insert(NSAttributedString(string: marker, attributes: [.font: UIFont.preferredFont(forTextStyle: style, compatibleWith: traits), .foregroundColor: UIColor.label]), at: 0) }
            if !content.string.hasSuffix("\n") { content.append(NSAttributedString(string: "\n")) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 10
            paragraph.headIndent = indent; paragraph.firstLineHeadIndent = marker == nil ? indent : max(0, indent - 24)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
            text.append(content)
        }
    }
}
#endif
