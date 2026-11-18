import AppKit

/// A real native transcript and compositor, with synthetic messages only. No
/// providers, stores, screen capture or preferences. Bitmaps draw TextKit offscreen.
@main @MainActor struct TranscriptStreamingProbe {
    static var reduceMotion = CommandLine.arguments.contains("--reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    struct Sample: Codable {
        let time: Double
        let y: Double
        let maximum: Double
        let offset: Double
        let visualOriginY: Double
        let opacity: Float
    }
    struct Case: Codable {
        let name: String
        var samples: [Sample] = []
        var arrivals = 0
        var overlaps = 0
        var capped = 0
        var pixelComparisons = 0
        var maxContinuityError: Double = 0
        var toolOpacities: [Float] = []
        var checks: [String] = []
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                app.stop(nil)
                app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
            } catch { print("PROBE FAIL: \(error)"); exit(1) }
        }
        app.run()
    }

    static func texts(_ root: NSView) -> [LinkedText.TextView] {
        if let text = root as? LinkedText.TextView { return [text] }
        return root.subviews.flatMap { texts($0) }
    }

    static func bitmap(_ layout: NSLayoutManager, container: NSTextContainer, width: Int) -> NSBitmapImageRep {
        layout.ensureLayout(for: container)
        let height = max(1, Int(ceil(layout.usedRect(for: container).height)))
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: image)!
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let glyphs = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: glyphs, at: .zero)
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    static func checkPixels(_ text: LinkedText.TextView, output: URL?) throws {
        let storage = NSTextStorage(attributedString: text.attributedString())
        let reference = NSLayoutManager()
        let container = NSTextContainer(size: text.textContainer!.containerSize)
        container.lineFragmentPadding = text.textContainer!.lineFragmentPadding
        storage.addLayoutManager(reference); reference.addTextContainer(container)
        // Match AppKit's text-view drawing policy (including link decorations),
        // but use a fresh, ordinary NSLayoutManager with no production subclass.
        let referenceView = NSTextView(frame: text.bounds, textContainer: container)
        referenceView.isEditable = false
        referenceView.isSelectable = true
        referenceView.drawsBackground = false
        referenceView.textContainerInset = .zero
        referenceView.linkTextAttributes = text.linkTextAttributes
        referenceView.appearance = text.effectiveAppearance
        var actual: NSBitmapImageRep!, expected: NSBitmapImageRep!
        text.effectiveAppearance.performAsCurrentDrawingAppearance {
            actual = bitmap(text.layoutManager!, container: text.textContainer!, width: Int(ceil(text.bounds.width)))
            expected = bitmap(reference, container: container, width: Int(ceil(text.bounds.width)))
        }
        // NSTextView applies native link foreground colors as temporary drawing
        // attributes. Compare coverage/alpha, not those unrelated RGB overrides.
        func alphas(_ image: NSBitmapImageRep) -> [UInt8] {
            (0..<image.pixelsHigh).flatMap { y in
                (0..<image.pixelsWide).map { x in image.bitmapData![y * image.bytesPerRow + x * 4 + 3] }
            }
        }
        withExtendedLifetime(referenceView) {}
        let a = alphas(actual), b = alphas(expected)
        let differences = zip(a, b).filter { $0 != $1 }.count
        try require(a == b && a.contains(where: { $0 != 0 }),
            "First-paint alpha differs: actual=\(actual.size) reference=\(expected.size), pixels=\(differences), sums=\(a.reduce(0) { $0 + Int($1) })/\(b.reduce(0) { $0 + Int($1) })")
        if let output { try actual.representation(using: .png, properties: [:])!.write(to: output) }
    }

    static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? ".build/transcript-streaming-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reduced = reduceMotion
        var reports: [Case] = []
        for dark in [false, true] {
            for width: CGFloat in [430, 900] {
                for cadence in ["fast", "slow", "bursty"] {
                    let report = try await exercise(dark: dark, width: width, cadence: cadence, reduced: reduced, output: output)
                    reports.append(report)
                    let error = report.samples.map { abs($0.y - $0.maximum) }.max() ?? 0
                    let offset = report.samples.map(\.offset).max() ?? 0
                    print("PASS \(report.name): samples=\(report.samples.count) arrivals=\(report.arrivals) overlaps=\(report.overlaps) capped=\(report.capped) pinError=\(error) maxOffset=\(offset) continuityError=\(report.maxContinuityError) pixels=\(report.pixelComparisons) checks=\(report.checks.joined(separator: ","))")
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: output.appendingPathComponent("report.json"))
        print("ReduceMotion=\(reduced). Native presentation samples + offscreen TextKit PNGs: \(output.path)")
        print("LIMITS: no screen capture, physical gestures, live provider, GPU cadence or compositor pixel/clipping proof. Excess over 72pt snaps; every new paint settles in 180ms, sustained arrivals may keep a bounded offset.")
    }

    static func exercise(dark: Bool, width: CGFloat, cadence: String, reduced: Bool, output: URL) async throws -> Case {
        var report = Case(name: "\(dark ? "dark" : "light")-\(Int(width))-\(cadence)")
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: 540),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic transcript streaming probe"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.orderFront(nil)
        defer { view.detach(); window.orderOut(nil); window.contentView = nil }
        let history = (0..<12).map { Message(role: .user, text: "Unchanged history \($0)") }
        var reply = Message(role: .assistant, text: String(repeating:
            "## Native Markdown\n\nLong **formatted** text with `inline code` and [link](https://example.com). Unicode 👩🏽‍💻 café.\n\n", count: 8), status: .streaming)
        var messages = history + [reply]
        func update(paint: Bool = true) {
            view.update(messages: messages, jumpRequest: state.jumpRequest)
            view.layoutSubtreeIfNeeded()
            if paint { view.viewWillDraw(); window.displayIfNeeded(); CATransaction.flush() }
        }
        update()
        try await Task.sleep(for: .milliseconds(100))
        let historyHeights = Array(state.layout.heights.prefix(history.count))
        let layer = view.documentView!.layer!
        func offset() -> CGFloat { layer.presentation()?.transform.m42 ?? 0 }
        func active() -> Bool { layer.animation(forKey: TranscriptGrowthMotion.animationKey) != nil }
        func pinned() throws {
            try require(abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 0.01, "\(report.name): logical pin lost")
        }
        func sample(for seconds: Double) async throws {
            let start = CACurrentMediaTime()
            var previous = offset()
            var previousOrigin = layer.presentation()?.convert(.zero, to: view.contentView.layer?.presentation()).y
            while CACurrentMediaTime() - start < seconds {
                try await Task.sleep(for: .milliseconds(8))
                let current = offset()
                try pinned()
                try require(current >= -0.01 && current <= 72.01, "Offset out of bounds")
                try require(current <= previous + 0.5, "Backward/downward motion between arrivals: \(previous) -> \(current)")
                previous = current
                let visualOrigin = layer.presentation()?.convert(.zero, to: view.contentView.layer?.presentation()).y ?? 0
                if let previousOrigin { try require(visualOrigin <= previousOrigin + 0.5, "Native document moved down between arrivals") }
                previousOrigin = visualOrigin
                // Overscan must cover the source area exposed by compensation.
                // This checks native row geometry, not compositor raster tiles.
                let exposedTop = view.contentView.bounds.minY - current
                if let firstRow = view.documentView!.subviews.min(by: { $0.frame.minY < $1.frame.minY }) {
                    try require(firstRow.frame.minY <= exposedTop + 20, "Missing overscan above visual viewport")
                }
                if reduced { try require(!active() && current == 0, "Reduce Motion animated") }
                report.samples.append(Sample(time: CACurrentMediaTime(), y: view.contentView.bounds.minY,
                    maximum: view.documentView!.bounds.height - view.contentView.bounds.height,
                    offset: current, visualOriginY: visualOrigin, opacity: layer.presentation()?.opacity ?? layer.opacity))
            }
        }
        for index in 0..<12 {
            let oldY = view.contentView.bounds.minY
            // Include partial final lines, completed delimiters, and multi-line bursts.
            reply.text += index % 3 == 0 ? "\n\n- Arrived **strong** and `code` line \(index).\n- Second wrapped line.\n\n" :
                " Full-opacity partial final text \(index) with enough words to wrap naturally."
            if cadence == "bursty", index % 4 == 0 { reply.text += String(repeating: "\n\nBurst paragraph.", count: 7) }
            messages[messages.count - 1] = reply
            update(paint: false)
            if index == 2 {
                // A second arrival before paint shares the first pending offset.
                reply.text += "\n\nSame-frame second arrival."
                messages[messages.count - 1] = reply
                update(paint: false)
            }
            try pinned()
            // Repeated same-frame measure passes must not restart or double-count.
            for _ in 0..<3 { view.refresh() }
            let delta = view.contentView.bounds.minY - oldY
            let current = offset()
            view.viewWillDraw()
            if let animation = layer.animation(forKey: TranscriptGrowthMotion.animationKey) as? CABasicAnimation,
               let origin = animation.fromValue as? Double, delta > 0 {
                let expected = min(72, max(0, current) + delta)
                let error = abs(origin - expected)
                report.maxContinuityError = max(report.maxContinuityError, error)
                try require(error < 1, "Overlap failed: from=\(origin) current=\(current) growth=\(delta)")
                try require(animation.duration == 0.18, "Wrong duration")
                report.arrivals += 1
                if current > 0.5 { report.overlaps += 1 }
                if expected == 72 { report.capped += 1 }
            }
            window.displayIfNeeded(); CATransaction.flush()
            let delay = cadence == "slow" ? 0.24 : cadence == "fast" ? 0.024 : [0.016, 0.032, 0.048, 0.28][index % 4]
            try await sample(for: delay)
        }
        try await sample(for: 0.24)
        try require(abs(offset()) < 0.01 && !active(), "Motion did not settle")
        try JSONEncoder().encode(report).write(to: output.appendingPathComponent(report.name + ".json"))
        if !reduced {
            try require(report.samples.contains { $0.offset > 1 && $0.offset < 71 }, "No actual intermediate native presentation motion")
            if cadence != "slow" { try require(report.overlaps > 0, "Overlap scenario was not exercised") }
        }
        // Pixel rasterization is deliberately a separate phase: full-document
        // TextKit rendering must not consume the animation being sampled above.
        for (index, suffix) in [" partial final", " text", "\n\n```swift\nlet value = 1", "\n```"].enumerated() {
            messages[messages.count - 1].text += suffix
            // Completion with a partial final line must be just as immediate.
            messages[messages.count - 1].status = index == 1 ? .complete : .streaming
            view.update(messages: messages, jumpRequest: state.jumpRequest)
            view.layoutSubtreeIfNeeded()
            guard let text = texts(view).last else { throw Failure(description: "Missing native text") }
            try checkPixels(text, output: report.pixelComparisons == 3 ? output.appendingPathComponent(report.name + ".png") : nil)
            try require(text.alphaValue == 1 && (text.layer?.opacity ?? 1) == 1, "Text opacity changed")
            report.pixelComparisons += 1
            view.cancelGrowthMotion()
        }
        report.checks.append("settling")

        try require(Array(state.layout.heights.prefix(history.count)) == historyHeights, "Streaming changed history geometry")
        // Tool cards keep their independent entrance opacity.
        let call = ToolCall(id: "synthetic", name: "shell", arguments: "{}")
        let tool = Message(role: .tool, text: "Synthetic result", toolResult: ToolResult(call: call, text: "Synthetic result"))
        messages.append(tool); update()
        let toolRow = view.documentView!.subviews.last!
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(20))
            report.toolOpacities.append(toolRow.layer?.presentation()?.opacity ?? 1)
        }
        if !reduced { try require(report.toolOpacities.contains { $0 > 0.55 && $0 < 0.99 }, "Tool fade missing") }
        else { try require(report.toolOpacities.allSatisfy { $0 == 1 }, "Reduced-motion tool faded") }
        report.checks.append("tool-fade")
        messages.removeLast(); update()
        func grow() {
            messages[messages.count - 1].text += "\n\nAnother arrived paragraph."
            update()
        }
        grow()
        reduceMotion = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        try require(!active(), "Reduce Motion did not cancel immediately")
        grow(); try require(!active(), "Reduce Motion allowed growth animation")
        reduceMotion = reduced
        report.checks.append("reduce-motion")
        grow()
        _ = view.hitTest(NSPoint(x: view.frame.midX, y: view.frame.midY))
        try require(!active(), "Hit testing did not cancel before native selection")
        grow()
        if let text = texts(view).last {
            text.setSelectedRange(NSRange(location: 0, length: 5))
            try require(!active(), "Selection did not cancel")
            grow(); try require(!active(), "Selection allowed new motion")
            text.setSelectedRange(NSRange(location: 0, length: 0))
        }
        report.checks.append("hit-test/selection")
        grow()
        view.withReaderScroll { view.contentView.scroll(to: NSPoint(x: 0, y: view.contentView.bounds.minY - 2)) }
        let reading = view.contentView.bounds.minY
        try require(!active() && !state.followsLatest, "Near-bottom manual opt-out failed")
        grow()
        try require(view.contentView.bounds.minY == reading && !active(), "Manual reading moved")
        view.withReaderScroll { view.contentView.scroll(to: NSPoint(x: 0, y: view.documentView!.bounds.height - view.contentView.bounds.height)) }
        try require(state.followsLatest, "Downward bottom opt-in failed")
        grow(); try pinned()
        report.checks.append("pause/resume")
        window.setContentSize(NSSize(width: width == 430 ? 900 : 430, height: 580))
        update(); try pinned(); try require(!active(), "Resize animated")
        view.updateHeaderInset(52); view.refresh(); try pinned(); try require(!active(), "Inset animated")
        report.checks.append("resize/inset")
        view.navigateSentMessage(.previous)
        try require(!active(), "Navigation animated")
        try require(Array(messages.prefix(history.count)) == history, "History changed")
        state.jumpToLatest(); update(); try pinned(); try require(!active(), "Jump animated")
        view.detach(); try require(!active(), "Detach kept motion")
        let remount = TranscriptScrollView(state: state)
        window.contentView = remount
        remount.update(messages: messages, jumpRequest: state.jumpRequest)
        remount.layoutSubtreeIfNeeded(); remount.viewWillDraw()
        try require(remount.documentView?.layer?.animation(forKey: TranscriptGrowthMotion.animationKey) == nil, "History remount animated")
        remount.detach()
        report.checks.append("navigation/history/remount/detach")
        return report
    }
}
