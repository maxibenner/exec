#if canImport(UIKit)
import UIKit

/// UIKit TextKit counterpart to the Mac's AppKit renderer. Both consume the
/// same bounded MarkdownDocument tree and link policy; no WebView or HTML.
@MainActor public enum UIKitMarkdownText {
    public static func render(_ blocks: [MarkdownBlock], width: CGFloat) -> NSAttributedString {
        let renderer = Renderer(width: max(100, width))
        for block in blocks { renderer.append(block) }
        if renderer.text.string.hasSuffix("\n") {
            renderer.text.deleteCharacters(in: NSRange(location: renderer.text.length - 1, length: 1))
        }
        return renderer.text
    }
    private final class Renderer {
        let text = NSMutableAttributedString(string: "")
        let width: CGFloat
        init(width: CGFloat) { self.width = width }
        func append(_ block: MarkdownBlock, indent: CGFloat = 0, marker: String? = nil, quote: Bool = false) {
            switch block.kind {
            case .header(let level):
                paragraph(block.text, indent: indent, marker: marker, style: level == 1 ? .title1 : level == 2 ? .title2 : .headline, bold: true, quote: quote)
            case .orderedList, .unorderedList:
                for item in block.children {
                    guard case .listItem(let ordinal) = item.kind else { continue }
                    for (index, child) in item.children.enumerated() {
                        append(child, indent: indent + 24, marker: index == 0 ? (block.kind == .orderedList ? "\(ordinal).\t" : "•\t") : nil, quote: quote)
                    }
                }
            case .blockQuote:
                for child in block.children { append(child, indent: indent + 16, quote: true) }
            case .codeBlock(let language):
                if let language, !language.isEmpty { paragraph(AttributedString(language), indent: indent, style: .caption1, quote: true) }
                paragraph(block.text, indent: indent, marker: marker, style: .footnote, code: true, quote: quote)
            case .thematicBreak:
                paragraph(AttributedString("────────"), indent: indent, quote: true)
            case .table(let columns):
                guard !columns.isEmpty else { return }
                for row in block.children {
                    let content = NSMutableAttributedString(string: "")
                    for column in columns.indices {
                        if column > 0 { content.append(NSAttributedString(string: "\t")) }
                        let cell = row.children.first { $0.kind == .tableCell(columnIndex: column) }?.text ?? AttributedString()
                        content.append(inline(cell, style: .footnote, bold: row.kind == .tableHeaderRow))
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
                if block.children.isEmpty { paragraph(block.text, indent: indent, marker: marker, quote: quote) }
                else {
                    for (index, child) in block.children.enumerated() { append(child, indent: indent, marker: index == 0 ? marker : nil, quote: quote) }
                }
            }
        }
        private func paragraph(_ source: AttributedString, indent: CGFloat, marker: String? = nil,
                               style: UIFont.TextStyle = .body, bold: Bool = false, code: Bool = false, quote: Bool = false) {
            let content = inline(source, style: style, bold: bold, code: code, quote: quote)
            if let marker { content.insert(NSAttributedString(string: marker, attributes: [.font:UIFont.preferredFont(forTextStyle: style), .foregroundColor:UIColor.label]), at: 0) }
            if !content.string.hasSuffix("\n") { content.append(NSAttributedString(string: "\n")) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 10
            paragraph.headIndent = indent; paragraph.firstLineHeadIndent = marker == nil ? indent : max(0, indent - 24)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
            text.append(content)
        }
        private func inline(_ source: AttributedString, style: UIFont.TextStyle, bold: Bool = false, code: Bool = false, quote: Bool = false) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(string: "")
            let base = UIFont.preferredFont(forTextStyle: style)
            for run in source.runs {
                let intent = run.inlinePresentationIntent ?? []
                let monospaced = code || intent.contains(.code)
                var font = monospaced ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
                var traits = font.fontDescriptor.symbolicTraits
                if bold || intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
                var attributes: [NSAttributedString.Key:Any] = [.font:font, .foregroundColor:quote ? UIColor.secondaryLabel : UIColor.label]
                if monospaced { attributes[.backgroundColor] = UIColor.tertiarySystemFill }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if !code, let link = run.link, MarkdownDocument.allowsLink(link) { attributes[.link] = link }
                result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
            }
            return result
        }
    }
}
#endif
