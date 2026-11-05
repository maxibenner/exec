import AppKit
import SwiftUI

struct DiffTests {
    @MainActor func pairsReplacementsWithoutLosingMarkersOrPlusSigns() throws {
        let source = "--- \"file\"\n+++ \"file\"\n@@ -3,2 +3,3 @@\n context\n-old\n\\ No newline at end of file\n+++counter\n+second\n\\ No newline at end of file\n"
        let document = DiffDocument(source)
        let cache = DiffView.RenderCache()
        let rendered = cache.value(for: source)
        try expect(cache.value(for: source).unified == rendered.unified)
        try expect(String(cache.value(for: "@@ -1 +1 @@\n-old\n+new").after.characters).contains("new"))
        let restored = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(
            ToolResult(call: ToolCall(id: "edit", name: "edit_file", arguments: "{}"), text: "Edited file",
                       edit: .init(path: "file", diff: source))))
        // A restored diff must have content on its very first layout, without an
        // onChange callback on an empty Group being required to populate it.
        let view = NSHostingView(rootView: DiffView(source: restored.edit!.diff).frame(width: 800))
        try expect(view.fittingSize.height > 40)
        try expect(String(rendered.unified.characters) + "\n" == source)
        try expect(String(rendered.before.characters).contains("old"))
        try expect(String(rendered.after.characters).contains("++counter"))
        try expect(document.unified.map(\.text).joined(separator: "\n") + "\n" == source)
        try expect(document.unified[6].kind == .added)
        try expect(document.pairs[1].before?.number == 3 && document.pairs[1].after?.number == 3)
        try expect(document.pairs[2].before?.text == "old" && document.pairs[2].after?.text == "++counter")
        try expect(document.pairs[3].before?.text == "\\ No newline at end of file")
        try expect(document.pairs[3].after?.number == 5)
        try expect(document.pairs.last?.before == nil && document.pairs.last?.after?.text == "\\ No newline at end of file")
    }
}
