import AppKit
import ExecTranscript

@MainActor struct CodeSyntaxTests {
    func metadataKeepsCodeSeparateFromProseAndLabels() throws {
        let code = "let café = \"👩🏽‍💻\""
        let text = MarkdownText.render(MarkdownDocument.parse("Before `inline`.\n\n```swift\n\(code)\n```\n\nAfter."))
        var ranges: [NSRange] = []
        var exactSource = true
        text.enumerateAttribute(MarkdownText.codeLanguage, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            ranges.append(range)
            // The parser owns whether the code retains a trailing newline.
            let source = text.attribute(MarkdownText.codeSnippet, at: range.location, effectiveRange: nil) as? String
            exactSource = exactSource && source?.utf16.elementsEqual((text.string as NSString).substring(with: range).utf16) == true
        }
        try expect(exactSource && ranges.count == 1)
        let range = ranges[0]
        try expect((text.string as NSString).substring(with: range).trimmingCharacters(in: .newlines) == code)
        let label = (text.string as NSString).range(of: "swift")
        let inline = (text.string as NSString).range(of: "inline")
        try expect(NSIntersectionRange(label, range).length == 0)
        try expect(NSIntersectionRange(inline, range).length == 0)
        try expect(text.attribute(MarkdownText.codeLanguage, at: inline.location, effectiveRange: nil) == nil)
    }

    func highlightingChangesOnlyDisplayColors() async throws {
        let source = "Before.\n\n```swift\nlet café = \"😀\"\n```\n\nAfter."
        let text = MarkdownText.render(MarkdownDocument.parse(source))
        let view = makeView()
        view.update(text)
        let keyword = (view.string as NSString).range(of: "let")
        let selection = (view.string as NSString).range(of: "café")
        view.setSelectedRange(selection)
        let layout = view.layoutManager!, container = view.textContainer!
        let geometry = layout.usedRect(for: container)
        let measurement = LinkedTextMeasurement()
        measurement.update(text)
        let measured = measurement.size(width: 440)
        let edits = StorageEdits()
        view.textStorage?.delegate = edits
        // Capture after TextKit's initial font fallback (emoji). Highlighting
        // must not make any further storage changes.
        let baseline = NSAttributedString(attributedString: view.attributedString())
        try await waitForColor(in: view, at: keyword.location)
        try expect(edits.count == 0)
        try expect(view.attributedString().isEqual(to: baseline))
        try expect(view.selectedRange() == selection)
        try expect(layout.usedRect(for: container) == geometry)
        try expect(measurement.size(width: 440) == measured)
        try expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        let copy = view.textStorage?.attribute(MarkdownText.codeSnippet, at: keyword.location, effectiveRange: nil) as? String
        try expect(copy?.contains("let café = \"😀\"") == true)
        // Resizing/reconfiguration retain the colors without editing the document.
        view.setFrameSize(NSSize(width: 280, height: 1000))
        view.update(text)
        try expect(edits.count == 0)
        try expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil) != nil)
    }

    func streamedCodeAndReuseRejectOldColors() async throws {
        let view = makeView()
        func render(_ source: String) -> NSAttributedString { MarkdownText.render(StreamingMarkdown.parse(source)) }
        view.update(render("```swift\nlet café = \"par"))
        view.setSelectedRange((view.string as NSString).range(of: "café"))
        view.update(render("```swift\nlet café = \"partial 😀\"\nlet answer = 42"))
        let keyword = (view.string as NSString).range(of: "let")
        try await waitForColor(in: view, at: keyword.location)
        try expect((view.string as NSString).substring(with: view.selectedRange()) == "café")
        let number = (view.string as NSString).range(of: "42")
        try expect(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: number.location, effectiveRange: nil) != nil)

        // Reuse the same native view while a request is pending. Unsupported and
        // unlabeled code must remain plain; late results cannot color the next row.
        view.update(render("```swift\nfunc pending() { return 1 }"))
        let plain = render("```unknown\nlet plain = 42\n```\n\n```\nlet unlabeled = 7\n```")
        view.update(plain)
        try await Task.sleep(for: .milliseconds(180))
        try expect(view.attributedString().isEqual(to: plain))
        for index in 0..<view.string.utf16.count {
            try expect(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) == nil)
        }
    }

    private func makeView() -> LinkedText.TextView {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = LinkedText.TextView(frame: NSRect(x: 0, y: 0, width: 440, height: 1000), textContainer: container)
        view.textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        view.isEditable = false; view.isSelectable = true
        return view
    }

    private func waitForColor(in view: LinkedText.TextView, at index: Int) async throws {
        for _ in 0..<100 {
            if view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure(description: "Syntax colors did not arrive")
    }

    private final class StorageEdits: NSObject, NSTextStorageDelegate {
        var count = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) { count += 1 }
    }
}
