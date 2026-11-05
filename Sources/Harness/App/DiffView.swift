import AppKit
import SwiftUI

struct DiffView: View {
    let source: String

    @State private var cache = RenderCache()

    var body: some View {
        let rendered = cache.value(for: source)
        ViewThatFits(in: .horizontal) {
            pane(rendered, sideBySide: true).frame(minWidth: 680)
            pane(rendered, sideBySide: false)
        }
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
    @MainActor struct RenderedDiff {
        let before: AttributedString
        let after: AttributedString
        let unified: AttributedString

        init(_ source: String) {
            let document = DiffDocument(source)
            before = DiffView.styled(document.pairs.map(\.before), numbers: true)
            after = DiffView.styled(document.pairs.map(\.after), numbers: true)
            unified = DiffView.styled(document.unified.map(Optional.some), numbers: false)
        }
    }

    private func pane(_ rendered: RenderedDiff, sideBySide: Bool) -> some View {
        Group {
            if sideBySide {
                HStack(alignment: .top, spacing: 0) {
                    column("Before", text: rendered.before)
                    Divider()
                    column("After", text: rendered.after)
                }
            } else {
                code(rendered.unified)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private func column(_ title: String, text: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
            code(text)
        }
        .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func code(_ text: AttributedString) -> some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(.body, design: .monospaced))
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
