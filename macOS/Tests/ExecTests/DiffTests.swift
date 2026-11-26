import AppKit
import SwiftUI

struct DiffTests {
    @MainActor func compactGutterAndInlineChanges() throws {
        let source = """
        --- "file"
        +++ "file"
        @@ -132,3 +132,4 @@
          context
        -  let value = "👩🏾‍💻old"
        +  let value = "👩🏾‍💻new"
        +++counter
         tail
        @@ -900 +901,0 @@
        -    only
        \\ No newline at end of file
        [Diff preview truncated; not a complete patch.]
        """ + "\n"
        let document = DiffDocument(source)
        try expect(document.lines.map(\.number) == [132, 133, 133, 134, 135, nil, 900, nil, nil])
        try expect(document.lines.map(\.kind) == [.context, .removed, .added, .added, .context,
                                                  .context, .removed, .note, .note])

        let cache = DiffView.RenderCache()
        let rendered = cache.value(for: source)
        try expect(cache.value(for: source) === rendered)
        try expect(rendered.text.string == " context\n  let value = \"👩🏾‍💻old\"\n  let value = \"👩🏾‍💻new\"\n"
                   + "++counter\ntail\n\n    only\n\\ No newline at end of file\n[Diff preview truncated; not a complete patch.]")
        var highlights: [String] = []
        rendered.text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: rendered.text.length)) { color, range, _ in
            if color != nil { highlights.append((rendered.text.string as NSString).substring(with: range)) }
        }
        try expect(highlights == ["old", "new", "++counter", "only"])
        try expect(String(DiffView.highlighted(source).characters) == source)

        let blank = cache.value(for: "@@ -0,0 +1,2 @@\r\n+first\r\n+\r\n")
        try expect(blank.text.string == "first\n\n" && blank.gutter[6]?.number == 2)
        let newlineEdit = DiffDocument("@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+old\n")
        try expect(newlineEdit.lines.map(\.number) == [1, nil, 1] && newlineEdit.lines.allSatisfy { $0.emphasis == nil })

        let restored = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(
            ToolResult(call: ToolCall(id: "edit", name: "edit_file", arguments: "{}"), text: "Edited file",
                       edit: .init(path: "file", diff: source))))
        // Restored edits have content on their first layout, at any viewport width.
        let view = NSHostingView(rootView: DiffView(source: restored.edit!.diff).frame(width: 800))
        try expect(view.fittingSize.height > 40)
        try fullHeightAndScrollRouting()
    }

    @MainActor private func fullHeightAndScrollRouting() throws {
        let source = "@@ -0,0 +1,100 @@\n" + (0..<100).map {
            "+line \($0) " + String(repeating: "wide content ", count: 20)
        }.joined(separator: "\n")
        let diff = DiffView.RenderedDiff(source)
        let narrow = NSHostingView(rootView: DiffCodeView(diff: diff).frame(width: 200))
        let wide = NSHostingView(rootView: DiffCodeView(diff: diff).frame(width: 800))
        // Neither viewport width nor the transcript's height may wrap/cap the diff.
        try expect(narrow.fittingSize.height > 1_000)
        try expect(abs(narrow.fittingSize.height - wide.fittingSize.height) < 1)

        let outer = ScrollRecorder()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 3_000))
        outer.documentView = document
        let surface = DiffCodeSurface(diff: diff)
        surface.frame = NSRect(x: 0, y: 0, width: 200, height: surface.codeSize.height)
        document.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        let code = surface.scrollView
        try expect(surface.codeSize.width > 200 && surface.codeSize.height > 1_000)
        try expect(code.documentView?.frame.height == surface.codeSize.height)
        try expect(!code.hasVerticalScroller && code.hasHorizontalScroller)
        let viewport = code.frame
        try expect(viewport.minX > 0 && viewport.maxX == surface.bounds.maxX)
        code.contentView.scroll(to: NSPoint(x: 40, y: 100))
        try expect(code.contentView.bounds.origin == NSPoint(x: 40, y: 0) && code.frame == viewport)
        let selectable = code.documentView?.subviews.first as? NSTextView
        try expect(selectable?.isSelectable == true && selectable?.string == diff.text.string)

        func wheel(x: Int32, y: Int32) -> NSEvent {
            NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!)!
        }
        code.scrollWheel(with: wheel(x: 0, y: 20))
        code.scrollWheel(with: wheel(x: 2, y: -20))
        try expect(outer.events == 2)
        code.scrollWheel(with: wheel(x: 20, y: 0))
        try expect(outer.events == 2) // Horizontal scrolling remains local.
        surface.update(DiffView.RenderedDiff("+short"))
        try expect(surface.codeSize.height < 100) // Replacing content remeasures.
    }

    @MainActor private final class ScrollRecorder: NSScrollView {
        var events = 0
        override func scrollWheel(with event: NSEvent) { events += 1 }
    }
}
