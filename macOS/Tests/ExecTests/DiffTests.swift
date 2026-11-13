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
        try fullHeightAndScrollRouting()
    }

    @MainActor private func fullHeightAndScrollRouting() throws {
        let source = (0..<100).map { "+line \($0) " + String(repeating: "wide content ", count: 20) }.joined(separator: "\n")
        let text = DiffView.highlighted(source)
        let narrow = NSHostingView(rootView: DiffCodeView(text: text).frame(width: 200))
        let wide = NSHostingView(rootView: DiffCodeView(text: text).frame(width: 700))
        // Neither viewport width nor the transcript's height may wrap/cap the diff.
        try expect(narrow.fittingSize.height > 1_000)
        try expect(abs(narrow.fittingSize.height - wide.fittingSize.height) < 1)
        let unified = NSHostingView(rootView: DiffView(source: source).frame(width: 400))
        let split = NSHostingView(rootView: DiffView(source: source).frame(width: 800))
        try expect(unified.fittingSize.height > 1_000 && split.fittingSize.height > 1_000)

        let outer = ScrollRecorder()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 3_000))
        outer.documentView = document
        let code = DiffCodeScrollView(text: text)
        code.frame = NSRect(x: 0, y: 0, width: 200, height: code.codeSize.height)
        document.addSubview(code)
        code.layoutSubtreeIfNeeded()
        try expect(code.codeSize.width > 200 && code.codeSize.height > 1_000)
        try expect(code.documentView?.frame.height == code.codeSize.height)
        try expect(!code.hasVerticalScroller && code.hasHorizontalScroller)
        func wheel(x: Int32, y: Int32) -> NSEvent {
            NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!)!
        }
        code.scrollWheel(with: wheel(x: 0, y: 20))
        code.scrollWheel(with: wheel(x: 2, y: -20))
        try expect(outer.events == 2)
        code.scrollWheel(with: wheel(x: 20, y: 0))
        try expect(outer.events == 2) // Horizontal scrolling remains local.
        code.update(DiffView.highlighted("+short"))
        try expect(code.codeSize.height < 100) // Collapsing/replacing content remeasures.
    }

    @MainActor private final class ScrollRecorder: NSScrollView {
        var events = 0
        override func scrollWheel(with event: NSEvent) { events += 1 }
    }
}
