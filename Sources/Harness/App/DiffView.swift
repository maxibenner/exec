import AppKit
import SwiftUI

struct DiffView: View {
    let source: String

    var body: some View {
        let document = DiffDocument(source)
        VStack(alignment: .trailing, spacing: 8) {
            Button("Copy Diff") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
            }
            .buttonStyle(.borderless).font(.caption)
            ViewThatFits(in: .horizontal) {
                pane(document, sideBySide: true).frame(minWidth: 680)
                pane(document, sideBySide: false)
            }
        }
    }

    private func pane(_ document: DiffDocument, sideBySide: Bool) -> some View {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return ScrollView(.vertical) {
            if sideBySide {
                HStack(alignment: .top, spacing: 0) {
                    column("Before", lines: document.pairs.map(\.before))
                    Divider()
                    column("After", lines: document.pairs.map(\.after))
                }
            } else {
                code(document.unified.map(Optional.some), numbers: false)
            }
        }
        .frame(height: min(340, CGFloat(sideBySide ? document.pairs.count : document.unified.count) * lineHeight + (sideBySide ? 46 : 20)))
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private func column(_ title: String, lines: [DiffDocument.Line?]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
            code(lines, numbers: true)
        }
        .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func code(_ lines: [DiffDocument.Line?], numbers: Bool) -> some View {
        ScrollView(.horizontal) {
            Text(Self.styled(lines, numbers: numbers)).font(.system(.body, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func highlighted(_ source: String) -> AttributedString {
        var result = styled(DiffDocument(source).unified.map(Optional.some), numbers: false)
        if source.hasSuffix("\n") { result.append(AttributedString("\n")) }
        return result
    }

    private static func styled(_ lines: [DiffDocument.Line?], numbers: Bool) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if numbers {
                let number = line?.number.map(String.init) ?? ""
                var gutter = AttributedString(String(repeating: " ", count: max(0, 4 - number.count)) + number + "  ")
                gutter.foregroundColor = Color.secondary
                result.append(gutter)
            }
            let content = line?.text ?? ""
            var text = AttributedString(numbers && content.isEmpty ? " " : content)
            switch line?.kind {
            case .added: text.backgroundColor = Color.green.opacity(0.24)
            case .removed: text.backgroundColor = Color.red.opacity(0.22)
            case .header: text.foregroundColor = Color.secondary
            default: break
            }
            result.append(text)
            if index < lines.count - 1 { result.append(AttributedString("\n")) }
        }
        return result
    }
}
