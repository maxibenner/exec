import Foundation

/// Leaves in reading order, retaining list/quote context when a native scroll
/// block interrupts a run of ordinary text. Parsing stays in MarkdownDocument.
struct MarkdownBlockLayout {
    enum Kind: Hashable { case text, code, table }
    struct Element {
        let block: MarkdownBlock
        let indent: Int
        let marker: String?
        let quoted: Bool
        var kind: Kind {
            switch block.kind {
            case .codeBlock: .code
            case .table: .table
            default: .text
            }
        }
    }

    static func elements(_ blocks: [MarkdownBlock]) -> [Element] {
        var result: [Element] = []
        func append(_ block: MarkdownBlock, indent: Int = 0, marker: String? = nil, quoted: Bool = false) {
            switch block.kind {
            case .orderedList, .unorderedList:
                for item in block.children {
                    guard case .listItem(let ordinal) = item.kind else { continue }
                    for (index, child) in item.children.enumerated() {
                        append(child, indent: indent + 24,
                               marker: index == 0 ? (block.kind == .orderedList ? "\(ordinal).\t" : "•\t") : nil,
                               quoted: quoted)
                    }
                }
            case .blockQuote:
                for (index, child) in block.children.enumerated() {
                    append(child, indent: indent + 16, marker: index == 0 ? marker : nil, quoted: true)
                }
            case .codeBlock, .table:
                result.append(Element(block: block, indent: indent, marker: marker, quoted: quoted))
            default:
                if block.children.isEmpty {
                    result.append(Element(block: block, indent: indent, marker: marker, quoted: quoted))
                } else {
                    for (index, child) in block.children.enumerated() {
                        append(child, indent: indent, marker: index == 0 ? marker : nil, quoted: quoted)
                    }
                }
            }
        }
        for block in blocks { append(block) }
        return result
    }
}
