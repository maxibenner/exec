import AppKit

/// Render a reply into one TextKit document so selection can cross every block.
@MainActor enum MarkdownText {
    static let codeSnippet = NSAttributedString.Key("ExecCodeSnippet")

    static func render(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let renderer = Renderer()
        for block in blocks { renderer.append(block) }
        // Paragraph separators belong between blocks, not after the reply. A
        // trailing newline creates an empty TextKit line on top of row spacing.
        // Boxed content (especially table cells) still needs its terminator.
        let text = renderer.text
        if text.length > 0, text.string.hasSuffix("\n"),
           let style = text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil) as? NSParagraphStyle,
           style.textBlocks.isEmpty {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
            if text.length > 0 {
                let finalStyle = style.mutableCopy() as! NSMutableParagraphStyle
                finalStyle.paragraphSpacing = 0
                let range = (text.string as NSString).paragraphRange(for: NSRange(location: text.length - 1, length: 0))
                text.addAttribute(.paragraphStyle, value: finalStyle, range: range)
            }
        }
        return text
    }

    @MainActor private final class Renderer {
        let text = NSMutableAttributedString(string: "")

        func append(_ block: MarkdownBlock, indent: CGFloat = 0, containers: [NSTextBlock] = [], marker: String? = nil) {
            switch block.kind {
            case .header(let level):
                paragraph(block.text, indent: indent, containers: containers, marker: marker,
                          size: level == 1 ? 24 : level == 2 ? 20 : 16, weight: .semibold)
            case .orderedList, .unorderedList:
                for item in block.children {
                    guard case .listItem(let ordinal) = item.kind else { continue }
                    for (index, child) in item.children.enumerated() {
                        append(child, indent: indent + 24, containers: containers,
                               marker: index == 0 ? (block.kind == .orderedList ? "\(ordinal).\t" : "•\t") : nil)
                    }
                }
            case .blockQuote:
                let quote = NSTextBlock()
                quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                quote.setBorderColor(.separatorColor, for: .minX)
                quote.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                for (index, child) in block.children.enumerated() {
                    append(child, indent: indent, containers: containers + [quote], marker: index == 0 ? marker : nil)
                }
            case .codeBlock(let language):
                // AppKit lays out table cells but ignores standalone text-block
                // padding/backgrounds. A single cell keeps code native/selectable.
                let table = NSTextTable()
                table.numberOfColumns = 1
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                table.setContentWidth(100, type: .percentageValueType)
                table.collapsesBorders = false
                let panel = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                             startingColumn: 0, columnSpan: 1)
                panel.backgroundColor = .quaternarySystemFill
                panel.setWidth(10, type: .absoluteValueType, for: .padding)
                panel.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
                if let language, !language.isEmpty {
                    paragraph(AttributedString(language), indent: indent, containers: containers + [panel], size: 11)
                }
                paragraph(block.text, indent: indent, containers: containers + [panel], marker: marker, code: true)
            case .thematicBreak:
                let rule = NSTextBlock()
                rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                rule.setBorderColor(.separatorColor, for: .minY)
                paragraph(AttributedString(), indent: indent, containers: containers + [rule], size: 2)
            case .table(let columns):
                guard !columns.isEmpty else { return }
                let table = NSTextTable()
                table.numberOfColumns = columns.count
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                table.setContentWidth(100, type: .percentageValueType)
                // Collapsed borders ignore cell margins and can paint the last
                // border outside the text container. Separate borders keep both
                // the outer stroke and the space below the last row in layout.
                table.collapsesBorders = false
                for (rowIndex, row) in block.children.enumerated() {
                    for column in columns.indices {
                        let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                                    startingColumn: column, columnSpan: 1)
                        // Let fixed layout divide the available width, including cell
                        // padding and borders. Percentage content widths add those
                        // insets on top and push the last column outside the view.
                        cell.setWidth(8, type: .absoluteValueType, for: .padding)
                        // TextKit applies outer spacing to cells, not the table.
                        if rowIndex == block.children.count - 1 {
                            cell.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
                        }
                        cell.verticalAlignment = .top
                        if row.kind == .tableHeaderRow {
                            cell.backgroundColor = .quaternarySystemFill
                        }
                        // Give each shared edge one owner so separate-border layout
                        // keeps the same stroke thickness inside and around the table.
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .minX)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .minY)
                        if column == columns.count - 1 {
                            cell.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxX)
                        }
                        if rowIndex == block.children.count - 1 {
                            cell.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                        }
                        cell.setBorderColor(.separatorColor)
                        let alignment: NSTextAlignment
                        switch columns[column].alignment {
                        case .center: alignment = .center
                        case .right: alignment = .right
                        default: alignment = .left
                        }
                        let content = row.children.first { $0.kind == .tableCell(columnIndex: column) }?.text ?? AttributedString()
                        paragraph(content, indent: indent, containers: containers + [cell],
                                  weight: row.kind == .tableHeaderRow ? .semibold : .regular, alignment: alignment)
                    }
                }
            default:
                if block.children.isEmpty {
                    paragraph(block.text, indent: indent, containers: containers, marker: marker)
                } else {
                    for (index, child) in block.children.enumerated() {
                        append(child, indent: indent, containers: containers, marker: index == 0 ? marker : nil)
                    }
                }
            }
        }

        private func paragraph(_ source: AttributedString, indent: CGFloat, containers: [NSTextBlock],
                               marker: String? = nil, size: CGFloat = NSFont.systemFontSize,
                               weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left, code: Bool = false) {
            let content: NSMutableAttributedString
            if code {
                content = NSMutableAttributedString(string: String(source.characters), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
                    .foregroundColor: NSColor.labelColor, Self.codeKey: String(source.characters)
                ])
            } else {
                content = NSMutableAttributedString(attributedString: LinkedText.attributed(source, fontSize: size, weight: weight))
            }
            if let marker {
                content.insert(NSAttributedString(string: marker, attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.labelColor
                ]), at: 0)
            }
            // A real paragraph terminator is essential for selection/copy across
            // blocks and for TextKit table cells, including empty cells.
            if !content.string.hasSuffix("\n") {
                content.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.labelColor
                ]))
            }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = code ? 0 : 10
            style.headIndent = indent
            style.firstLineHeadIndent = marker == nil ? indent : max(0, indent - 24)
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.alignment = alignment
            style.textBlocks = containers
            content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
            text.append(content)
        }

        private static let codeKey = MarkdownText.codeSnippet
    }
}
