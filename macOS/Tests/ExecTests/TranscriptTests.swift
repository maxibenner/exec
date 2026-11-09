import AppKit
import SwiftUI

@MainActor struct TranscriptTests {
    private struct ComposerPreview: View {
        let panel: ChatPanel
        let overlayScrollerInset: CGFloat
        @FocusState private var focused: Bool

        var body: some View {
            ChatComposer(store: panel, overlayScrollerInset: overlayScrollerInset, focused: $focused)
        }
    }

    func compactionRowsRemainVisibleWithoutAssistantText() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        defer { view.detach() }
        var activity = Message(role: .assistant, text: "", status: .streaming, compaction: .automatic)
        let placeholder = Message(role: .assistant, text: "", status: .streaming)
        for status in [Message.Status.streaming, .complete, .interrupted, .failed] {
            activity.status = status
            view.update(messages: [activity, placeholder], jumpRequest: 0)
            view.layoutSubtreeIfNeeded()
            view.refresh()
            try expect(state.layout.ids == [activity.id])
            try expect(view.mountedRowCount == 1 && state.layout.heights[0] >= 30)
        }
    }

    func geometryPreservesAnchors() throws {
        let messages = (0..<1_000).map { Message(role: .user, text: "Message \($0)") }
        var layout = TranscriptLayout()
        layout.update(messages: messages, width: 700)
        let originalY = layout.offsets[500] + 10
        let anchor = layout.anchor(at: originalY)!
        try expect(anchor.id == messages[500].id && anchor.offset == 10)
        let gapY = layout.offsets[500] + layout.heights[500] + 12
        try expect(layout.position(of: layout.anchor(at: gapY)!) == gapY)
        let originalHeight = layout.heights[100]
        layout.measure(messages[100].id, height: originalHeight + 200)
        try expect(layout.position(of: anchor) == originalY + 200)
        let range = layout.visibleRange(y: originalY + 200, height: 600, overscan: 300)
        try expect(range.contains(500) && range.count < 40)
        layout.update(messages: messages + [Message(role: .assistant, text: "New")], width: 700)
        try expect(layout.position(of: anchor) == originalY + 200)
        layout.update(messages: messages, width: 400)
        try expect(layout.anchor(at: layout.position(of: anchor)!) == anchor)
        layout.update(messages: [], width: 400)
        try expect(layout.visibleRange(y: 0, height: 600, overscan: 300).isEmpty && layout.anchor(at: 0) == nil)
    }

    func batchedMeasurementsPreserveGeometryAcrossResizeAndEdits() throws {
        var messages = (0..<100).map { Message(role: .user, text: "Message \($0)") }
        var layout = TranscriptLayout()
        layout.update(messages: messages, width: 700)
        let anchor = layout.anchor(at: layout.offsets[50] + 8)!
        let corrections = [(id: messages[2].id, height: CGFloat(200)),
                           (id: messages[20].id, height: CGFloat(300)),
                           (id: messages[70].id, height: CGFloat(150))]
        var individually = layout
        for (id, height) in corrections { individually.measure(id, height: height) }
        try expect(layout.measure(corrections))
        try expect(layout.offsets == individually.offsets && layout.totalHeight == individually.totalHeight)
        try expect(layout.position(of: anchor) == individually.position(of: anchor))
        try expect(!layout.measure(corrections + [(UUID(), 100), (messages[0].id, .nan)]))

        layout.resize(to: 700)
        try expect(layout.heights[2] == 200) // Same-width callbacks retain measurements.
        layout.resize(to: 400)
        // Last-known heights remain estimates until rows are measured at the new
        // width. Do not replace good geometry with rough character-count guesses.
        try expect(layout.width == 400 && layout.offsets == individually.offsets)
        let oldPosition = layout.position(of: anchor)!
        try expect(layout.measure(messages[2].id, height: 250))
        try expect(layout.position(of: anchor) == oldPosition + 50)
        try expect(layout.anchor(at: layout.position(of: anchor)!) == anchor)
        messages.removeFirst(10)
        messages.append(Message(role: .assistant, text: "New reply"))
        layout.update(messages: messages, width: 400)
        try expect(layout.ids == messages.map(\.id) && layout.heights[10] == 300)
        try expect(layout.anchor(at: layout.position(of: anchor)!) == anchor)
        try expect(!layout.measure(corrections[0].id, height: 900)) // Deleted ID has no index.
    }

    func reusesMeasurementsWithoutLosingStreamingOrSelection() async throws {
        _ = NSApplication.shared
        var messages = (0..<30).map { Message(role: .user, text: "Message \($0)") }
        let source = "A **formatted** reply with [a link](https://example.com)."
        messages.append(Message(role: .assistant, text: source, status: .streaming))
        let state = TranscriptState()
        state.markdown.insert(MarkdownDocument.parse(source), for: source)
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 600)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.detach(); window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        view.update(messages: messages, jumpRequest: 0)
        try await settle(view)
        let count = view.rowMeasurementCount
        try expect(count > 0)
        for _ in 0..<5 {
            view.update(messages: messages, jumpRequest: 0)
            view.layoutSubtreeIfNeeded()
            view.refresh()
        }
        try await settle(view)
        try expect(view.rowMeasurementCount == count)

        // A wider viewport above the text-width cap only recenters existing rows.
        window.setContentSize(NSSize(width: 1_020, height: 600))
        try await settle(view)
        try expect(view.rowMeasurementCount == count)
        guard let text = textViews(in: view).first(where: { $0.string.contains("formatted") }) else {
            throw CheckFailure(description: "Missing formatted reply")
        }
        let selection = NSRange(location: 2, length: 9)
        text.setSelectedRange(selection)
        window.setContentSize(NSSize(width: 580, height: 600))
        try await settle(view)
        try expect(view.rowMeasurementCount > count && text.selectedRange() == selection)
        let narrowHeight = state.layout.heights.last!

        messages[messages.count - 1].text += String(repeating: "\n\nMore streamed **text** that wraps at this width.", count: 6)
        view.update(messages: messages, jumpRequest: 0)
        try await settle(view)
        try expect(text.string.contains("More streamed text")) // Async Markdown completed, not just its placeholder.
        guard text.selectedRange() == selection && state.layout.heights.last! > narrowHeight else {
            throw CheckFailure(description: "Streaming selection=\(text.selectedRange()), height=\(state.layout.heights.last!), previous=\(narrowHeight), measurements=\(view.rowMeasurementCount)")
        }
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 1)
        let settledCount = view.rowMeasurementCount
        try await settle(view)
        try expect(view.rowMeasurementCount == settledCount)
    }

    func resizingFormattedRowsKeepsHostsAndMeasuresOnce() async throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let messages = (0..<30).map { index -> Message in
            let source = "```swift\n" + (0..<24).map { "let value\($0) = \(index)" }.joined(separator: "\n") + "\n```"
            state.markdown.insert(MarkdownDocument.parse(source), for: source)
            return Message(role: .assistant, text: source)
        }
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 850, height: 650)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.detach(); window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        view.update(messages: messages, jumpRequest: 0)
        try await settle(view)
        let originalRows = Set(view.documentView!.subviews.map(ObjectIdentifier.init))
        let text = textViews(in: view).first { $0.string.contains("= 29") }!
        let selection = NSRange(location: 6, length: 10)
        text.setSelectedRange(selection)
        for width in [CGFloat(800), 650, 480, 600, 850] {
            let before = view.rowMeasurementCount
            window.setContentSize(NSSize(width: width, height: 650))
            view.layoutSubtreeIfNeeded()
            // The short code lines do not wrap at these widths. A geometry reset
            // must not mount extra rows or repeatedly measure existing ones.
            try expect(Set(view.documentView!.subviews.map(ObjectIdentifier.init)) == originalRows)
            try expect(view.rowMeasurementCount - before == originalRows.count)
            for row in view.documentView!.subviews {
                try expect(abs(row.frame.height - ceil(row.fittingSize.height)) < 1)
            }
            try await settle(view)
            try expect(view.rowMeasurementCount - before == originalRows.count)
            try expect(text.selectedRange() == selection)
            // TextKit can scroll a selection slightly into view during resize
            // (also on the baseline build); retain normal near-bottom following.
            try expect(state.followsLatest && abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) <= 40)
        }
        // Rows outside the viewport must still be measured when revisited after
        // a width change, rather than treating retained estimates as final sizes.
        view.contentView.scroll(to: NSPoint(x: 0, y: state.layout.offsets[10] + 8))
        view.refresh()
        try await settle(view)
        try expect(!state.followsLatest)
        let anchor = state.layout.anchor(at: view.contentView.bounds.minY)!
        try expect(anchor.id == messages[10].id && abs(anchor.offset - 8) < 1)
        for row in view.documentView!.subviews {
            try expect(abs(row.frame.height - ceil(row.fittingSize.height)) < 1)
        }
    }

    func localDisclosureChangesInvalidateMeasuredHeight() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let output = (0..<12).map { "Output line \($0)" }.joined(separator: "\n")
        let result = ToolResult(call: ToolCall(id: "shell", name: "shell", arguments: "{}"), text: output)
        let tool = Message(role: .tool, text: output, toolResult: result)
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.detach(); window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        view.update(messages: [tool, Message(role: .user, text: "Neighbor")], jumpRequest: 0)
        try await settle(view)
        let collapsed = state.layout.heights[0]
        let toolHost = view.documentView!.subviews.min { $0.frame.minY < $1.frame.minY }!.subviews[0]
        for expand in [true, false, true] {
            let location = toolHost.convert(NSPoint(x: 100, y: 20), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            // No Message update or explicit refresh: the host must detect local
            // SwiftUI state changes, including shrinkage, on its own.
            try await settle(view)
            try expect(state.expanded[tool.id] == expand && !state.followsLatest)
            try expect(expand ? state.layout.heights[0] > collapsed + 200 : state.layout.heights[0] == collapsed)
            let rows = view.documentView!.subviews.sorted { $0.frame.minY < $1.frame.minY }
            try expect(rows.count == 2 && rows[1].frame.minY >= rows[0].frame.maxY)
            try expect(abs(rows[0].frame.height - rows[0].fittingSize.height) < 1)
        }
    }

    func userBubblesSupportTextAndImagesInBothAppearances() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<8 { for x in 0..<8 { pixels.setColor(.systemRed, atX: x, y: y) } }
        let image = ImageAttachment(name: "attachment.png", mediaType: "image/png",
                                   data: pixels.representation(using: .png, properties: [:])!)
        let other = ImageAttachment(name: "second.png", mediaType: "image/png", data: image.data)
        let messages = [
            Message(role: .user, text: "Hello 👋"),
            Message(role: .user, text: "Multiline text\n```swift\nlet value = 42\n```\n日本語 · مرحبا\n" + String(repeating: "https://example.com/long-path/", count: 8)),
            Message(role: .user, text: "", images: [image]),
            Message(role: .user, text: "Two attached images", images: [image, other])
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(420), 860] {
                let state = TranscriptState()
                let view = TranscriptScrollView(state: state)
                view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                defer { view.detach(); window.orderOut(nil); window.contentView = nil }
                window.orderFront(nil)
                for message in messages {
                    view.update(messages: [message], jumpRequest: 0)
                    try await settle(view)
                    let rows = view.documentView!.subviews
                    try expect(rows.count == 1)
                    let row = rows[0]
                    try expect(row.frame.width <= view.contentView.bounds.width)
                    try expect(abs(row.frame.height - ceil(row.fittingSize.height)) < 1)
                    let texts = textViews(in: row)
                    try expect(texts.map(\.string) == (message.text.isEmpty ? [] : [message.text]))
                    if let text = texts.first {
                        let range = NSRange(location: 0, length: (message.text as NSString).length)
                        text.setSelectedRange(range)
                        try expect(text.selectedRange() == range)
                        text.setSelectedRange(NSRange(location: 0, length: 0))
                    }
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw CheckFailure(description: "Could not render user bubble")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    // Red attachment fixtures cannot satisfy this check: the blue
                    // must come from the shared bubble, including image-only rows.
                    var bluePixels = 0
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            if color.blueComponent > color.redComponent + 0.04,
                               color.blueComponent > color.greenComponent + 0.02 {
                                bluePixels += 1
                            }
                        }
                    }
                    try expect(bluePixels > 20)
                }
            }
        }
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func textViews(in view: NSView) -> [LinkedText.TextView] {
        if let text = view as? LinkedText.TextView { return [text] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    func composerInsetMatchesTranscriptViewport() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ChatLibrary(provider: FakeProvider(), sessions: SessionStore(directory: root))
        let panel = ChatPanel(library: library, conversation: library.current)
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        view.autohidesScrollers = false
        let message = Message(role: .user, text: "Alignment")
        for width in [CGFloat(600), 1_000] {
            for style in [NSScroller.Style.legacy, .overlay] {
                view.scrollerStyle = style
                view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                view.tile()
                view.update(messages: [message], jumpRequest: 0)
                view.layoutSubtreeIfNeeded(); view.refresh()
                // The viewport inset is delivered after the native layout pass.
                try await Task.sleep(for: .milliseconds(20))
                try expect(abs(state.trailingInset - (width - view.contentSize.width)) < 0.5)
                try expect(style == .overlay ? state.trailingInset == 0 : state.trailingInset > 0)
                let availableWidth = width - state.trailingInset
                let composerWidth = min(820, availableWidth - 40)
                let composerLeft = (availableWidth - composerWidth) / 2
                guard let row = view.documentView?.subviews.first else {
                    throw CheckFailure(description: "Expected a mounted transcript row")
                }
                try expect(abs(row.frame.minX - composerLeft) < 0.5)
                try expect(abs(row.frame.maxX - (composerLeft + composerWidth)) < 0.5)
                try expect(style == .overlay ? state.overlayScrollerInset > 0 : state.overlayScrollerInset == 0)
                if style == .overlay {
                    try expect(state.overlayScrollerInset >= (view.verticalScroller?.frame.width ?? 0))
                }

                // Check the actual painted footer, not just the input's alignment:
                // an overlay scroller needs a transparent strip inside the viewport.
                let renderer = ImageRenderer(content: ComposerPreview(panel: panel, overlayScrollerInset: state.overlayScrollerInset)
                    .frame(width: availableWidth).environment(\.colorScheme, .light))
                guard let image = renderer.cgImage else { throw CheckFailure(description: "Missing composer rendering") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                func maximumAlpha(at x: Int) -> CGFloat {
                    (0..<bitmap.pixelsHigh).map { bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0 }.max() ?? 0
                }
                try expect(maximumAlpha(at: 1) > 0.99)
                let rightAlpha = maximumAlpha(at: bitmap.pixelsWide - 2)
                try expect(style == .overlay ? rightAlpha < 0.01 : rightAlpha > 0.99)
            }
        }
    }

    func resizingCommitsRowsBeforeDisplay() throws {
        _ = NSApplication.shared
        for style in [NSScroller.Style.overlay, .legacy] {
            let state = TranscriptState()
            let view = TranscriptScrollView(state: state)
            defer { view.detach() }
            view.scrollerStyle = style
            view.frame = NSRect(x: 0, y: 0, width: 980, height: 600)
            view.update(messages: (0..<30).map {
                Message(role: $0.isMultiple(of: 2) ? .user : .assistant,
                        text: String(repeating: "A paragraph that reflows while the sidebar moves. ", count: 8))
            }, jumpRequest: 0)
            for width in [900, 820, 740, 680, 600, 540, 600, 740, 900, 980] {
                view.setFrameSize(NSSize(width: width, height: 600))
                view.layoutSubtreeIfNeeded()
                // No run-loop yield or explicit refresh: the next displayed frame
                // must already use the new viewport, including mounted row hosts.
                let expectedWidth = min(820, view.contentSize.width - 40)
                try expect(abs(state.layout.width - expectedWidth) < 1)
                let rows = view.documentView!.subviews
                try expect(!rows.isEmpty && rows.count < 30)
                for row in rows {
                    try expect(abs(row.frame.width - expectedWidth) < 1)
                    try expect(abs(row.frame.midX - view.contentSize.width / 2) < 1)
                    try expect(abs(row.subviews[0].frame.width - expectedWidth) < 1)
                    // Retained geometry is only an estimate: mounted wrapped
                    // paragraphs must already have their new measured height.
                    try expect(abs(row.frame.height - ceil(row.fittingSize.height)) < 1)
                }
                let maximum = max(0, view.documentView!.bounds.height - view.contentView.bounds.height)
                try expect(abs(view.contentView.bounds.minY - maximum) < 1)
            }
        }
    }

    func preservesNearBottomScrolling() throws {
        _ = NSApplication.shared
        let messages = (0..<100).map { Message(role: .user, text: "Message \($0)") }
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.update(messages: messages, jumpRequest: 0)
        view.layoutSubtreeIfNeeded(); view.refresh()
        let bottom = view.documentView!.bounds.height - view.contentView.bounds.height
        // Being near the bottom should enable following future content without
        // snapping the current gesture to the edge.
        view.contentView.setBoundsOrigin(NSPoint(x: 0, y: bottom - 15))
        view.refresh()
        let remaining = view.documentView!.bounds.height - view.contentView.bounds.maxY
        try expect(state.followsLatest && abs(remaining - 15) < 1)
        // Explicit navigation must still reach the edge after a user scroll.
        state.jumpToLatest()
        view.update(messages: messages, jumpRequest: state.jumpRequest)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 1)
    }

    func emptyToolStepsDoNotMoveTranscript() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        var messages = (0..<30).map { Message(role: .user, text: "Message \($0)") }
        func update() {
            view.update(messages: messages, jumpRequest: 0, bottomInset: 140)
            view.layoutSubtreeIfNeeded(); view.refresh()
        }
        update()
        for index in 0..<3 {
            let height = state.layout.totalHeight
            let origin = view.contentView.bounds.origin
            let ids = state.layout.ids
            messages.append(Message(role: .assistant, text: "", status: .streaming))
            update()
            try expect(state.layout.ids == ids && state.layout.totalHeight == height)
            try expect(view.contentView.bounds.origin == origin)

            let call = ToolCall(id: "call-\(index)", name: "shell", arguments: "{}")
            messages[messages.count - 1].status = .complete
            messages[messages.count - 1].toolCalls = [call]
            update()
            try expect(state.layout.ids == ids && view.contentView.bounds.origin == origin)

            let result = ToolResult(call: call, text: "Done")
            messages.append(Message(role: .tool, text: result.text, toolResult: result))
            update()
            try expect(state.layout.ids == ids + [messages.last!.id])
            try expect(abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 1)
        }
        // Text and failures remain visible; stopping adds no label or empty row.
        messages.append(Message(role: .assistant, text: "", status: .streaming))
        update()
        let count = state.layout.ids.count
        messages[messages.count - 1].text = "Reply"
        update()
        try expect(state.layout.ids.count == count + 1)
        messages[messages.count - 1].status = .interrupted
        update()
        try expect(state.layout.ids.last == messages.last!.id)
        messages[messages.count - 1].text = ""
        update()
        try expect(state.layout.ids.count == count)
        messages[messages.count - 1].status = .failed
        update()
        try expect(state.layout.ids.last == messages.last!.id)
    }

    func expandedToolContentStaysInsideCommittedRowBounds() throws {
        _ = NSApplication.shared
        let output = (0..<12).map { "Output line \($0)" }.joined(separator: "\n")
        let result = ToolResult(call: ToolCall(id: "shell", name: "shell", arguments: "{}"), text: output)
        let shell = Message(role: .tool, text: output, toolResult: result)
        let messages = [shell, Message(role: .assistant, text: "This reply must never be covered by shell output.")]
        let state = TranscriptState()
        state.followsLatest = false
        state.expanded[shell.id] = true
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.update(messages: messages, jumpRequest: 0)
        view.layoutSubtreeIfNeeded(); view.refresh()
        let rows = view.documentView!.subviews.sorted { $0.frame.minY < $1.frame.minY }
        try expect(rows.count == 2)
        let row = rows[0]
        let fullFrame = row.frame
        let neighborFrame = rows[1].frame
        try expect(fullFrame.height > 200 && neighborFrame.minY >= fullFrame.maxY)
        try expect(row.clipsToBounds && row.layer?.masksToBounds == true)
        try expect(row.subviews.count == 1)
        let hosted = row.subviews[0]
        func textViews(in view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView { return [text] }
            return view.subviews.flatMap { textViews(in: $0) }
        }
        func bodyFrames() throws -> (arguments: NSRect, output: NSRect) {
            let texts = textViews(in: hosted)
            guard let arguments = texts.first(where: { $0.string == "{}" }),
                  let outputField = texts.first(where: { $0.string == output }) else {
                throw CheckFailure(description: "Expected selectable shell arguments and output")
            }
            return (arguments.convert(arguments.bounds, to: row), outputField.convert(outputField.bounds, to: row))
        }
        let fullBody = try bodyFrames()

        // Reproduce the interval between SwiftUI expanding/measuring its content
        // and the transcript committing a larger row frame. The native boundary
        // must remain small even if the hosted view uses its full natural height.
        // The hosting view can also receive the stale, collapsed height while
        // SwiftUI has already inserted the expanded body. Its text must stay
        // below the header rather than centering/overlapping within that height.
        for height in [CGFloat(60), fullFrame.height] {
            hosted.setFrameSize(NSSize(width: fullFrame.width, height: height))
            hosted.layoutSubtreeIfNeeded()
            let body = try bodyFrames()
            try expect(abs(body.arguments.minY - fullBody.arguments.minY) < 1)
            try expect(body.output.minY >= body.arguments.maxY)
            try expect(abs(body.output.height - fullBody.output.height) < 1)
        }
        row.setFrameSize(NSSize(width: fullFrame.width, height: 60))
        hosted.frame = NSRect(origin: .zero, size: fullFrame.size)
        let measured = row.fittingSize
        try expect(measured.height > 200 && row.frame.height == 60)
        try expect(hosted.visibleRect.height <= 60)
        try expect(rows[1].frame == neighborFrame)

        view.refresh()
        view.layoutSubtreeIfNeeded(); view.refresh()
        try expect(abs(row.frame.height - measured.height) < 1)
        try expect(rows[1].frame.minY >= row.frame.maxY)
        try expect(!state.followsLatest && state.expanded[shell.id] == true)
    }

    func mountsBoundedRowsAndRestoresPosition() async throws {
        _ = NSApplication.shared
        let messages = (0..<1_000).map { Message(role: .user, text: "Message \($0): a small stable row") }
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.update(messages: messages, jumpRequest: 0)
        view.layoutSubtreeIfNeeded(); view.refresh()
        try expect(view.mountedRowCount > 0 && view.mountedRowCount < 40)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 2)
        view.contentView.scroll(to: NSPoint(x: 0, y: state.layout.offsets[500] + 8))
        view.refresh()
        try expect(!state.followsLatest)
        let anchor = state.layout.anchor(at: view.contentView.bounds.minY)!
        try expect(anchor.id == messages[500].id && abs(anchor.offset - 8) < 1)
        for width in [CGFloat(420), 800] {
            view.setFrameSize(NSSize(width: width, height: 600))
            view.layoutSubtreeIfNeeded(); view.refresh()
            try expect(state.layout.anchor(at: view.contentView.bounds.minY) == anchor && !state.followsLatest)
        }
        view.update(messages: messages + [Message(role: .assistant, text: "A new response")], jumpRequest: 0)
        try expect(state.layout.anchor(at: view.contentView.bounds.minY) == anchor)
        view.detach()
        try expect(view.mountedRowCount == 0)
        let restored = TranscriptScrollView(state: state)
        restored.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        restored.update(messages: messages, jumpRequest: 0)
        restored.layoutSubtreeIfNeeded(); restored.refresh()
        try expect(state.layout.anchor(at: restored.contentView.bounds.minY) == anchor)
        try expect(restored.mountedRowCount < 40)
        restored.update(messages: messages, jumpRequest: 0, bottomInset: 180)
        try expect(state.layout.anchor(at: restored.contentView.bounds.minY) == anchor)
        state.jumpToLatest()
        restored.update(messages: messages, jumpRequest: state.jumpRequest, bottomInset: 180)
        try expect(abs(restored.contentView.bounds.maxY - restored.documentView!.bounds.height) < 2)
        let lastBottom = state.layout.offsets.last! + state.layout.heights.last!
        try expect(lastBottom <= restored.contentView.bounds.maxY - 180)
        restored.detach()
    }
}
