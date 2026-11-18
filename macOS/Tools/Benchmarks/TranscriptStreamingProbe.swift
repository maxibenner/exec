import AppKit

/// A real native transcript and compositor, with synthetic messages only. No
/// providers, stores, screen capture or preferences. Bitmaps draw TextKit offscreen.
@main @MainActor struct TranscriptStreamingProbe {
    static var reduceMotion = CommandLine.arguments.contains("--reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    // Deliver through NSApplication's real local monitors, but stop at the
    // window boundary so synthetic presses never open URLs or native menus.
    final class ProbeWindow: NSWindow {
        var inspectPress: (() -> Void)?
        override func sendEvent(_ event: NSEvent) {
            if [.leftMouseDown, .rightMouseDown, .leftMouseDragged].contains(event.type), event.eventNumber == 4242 {
                inspectPress?()
                return
            }
            super.sendEvent(event)
        }
    }
    struct Interaction: Codable {
        let kind: String
        let displayedOffset: Double
        let pendingPinDelta: Double
        let anchorError: Double
        let expectedCharacter: Int
        let oldIncorrectCharacter: Int
        let actualCharacter: Int
    }
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
        var interactions: [Interaction] = []
        var completionOffset: Double = 0
        var completionBeginTime: Double = 0
        var completionSettledOffset: Double = 0
        var completionMetadataPendingCleanup = false
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
        cases: for dark in [false, true] {
            for width: CGFloat in [430, 900] {
                for cadence in ["fast", "slow", "bursty"] {
                    if let requested = CommandLine.arguments.first(where: { $0.hasPrefix("--case=") }),
                       requested != "--case=\(dark ? "dark" : "light")-\(Int(width))-\(cadence)" { continue }
                    let report = try await exercise(dark: dark, width: width, cadence: cadence, reduced: reduced, output: output)
                    reports.append(report)
                    let error = report.samples.map { abs($0.y - $0.maximum) }.max() ?? 0
                    let offset = report.samples.map(\.offset).max() ?? 0
                    print("PASS \(report.name): samples=\(report.samples.count) arrivals=\(report.arrivals) overlaps=\(report.overlaps) capped=\(report.capped) pinError=\(error) maxOffset=\(offset) continuityError=\(report.maxContinuityError) interactions=\(report.interactions.count) pixels=\(report.pixelComparisons) checks=\(report.checks.joined(separator: ","))")
                    if CommandLine.arguments.contains("--smoke") { break cases }
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
        let window = ProbeWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: 540),
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
        // Status-only completion during a REAL nonzero presentation must keep
        // the original start/from/duration and expire at the original deadline.
        grow()
        let started = CACurrentMediaTime()
        try await Task.sleep(for: .milliseconds(70))
        let beforeCompletion = layer.animation(forKey: TranscriptGrowthMotion.animationKey) as? CABasicAnimation
        report.completionOffset = offset()
        report.completionBeginTime = beforeCompletion?.beginTime ?? 0
        if !reduced { try require(offset() > 1 && active(), "Completion fixture has no displayed motion") }
        let completedHeight = state.layout.totalHeight
        messages[messages.count - 1].status = .complete
        update()
        if !reduced {
            let after = layer.animation(forKey: TranscriptGrowthMotion.animationKey) as? CABasicAnimation
            try require(after != nil && after?.beginTime == beforeCompletion?.beginTime &&
                after?.fromValue as? Double == beforeCompletion?.fromValue as? Double &&
                after?.duration == beforeCompletion?.duration, "Completion cancelled/restarted motion")
        }
        try require(state.layout.totalHeight == completedHeight, "Plain completion changed geometry")
        // Use Core Animation's assigned start, not the time the animation was
        // submitted: transaction/compositor startup can lag submission under load.
        let deadline = beforeCompletion.map { layer.convertTime($0.beginTime + $0.duration, to: nil) } ?? started
        while CACurrentMediaTime() < deadline + 0.04 {
            try await Task.sleep(for: .milliseconds(8))
        }
        report.completionSettledOffset = offset()
        let expired = layer.animation(forKey: TranscriptGrowthMotion.animationKey)
        report.completionMetadataPendingCleanup = expired != nil
        // CA may retain expired model metadata until a later transaction. The
        // presentation must already be zero at the ORIGINAL deadline, and any
        // retained animation must still have its original start and duration.
        try require(abs(offset()) < 0.01 && (expired == nil ||
            (expired?.beginTime == beforeCompletion?.beginTime && expired?.duration == beforeCompletion?.duration)),
            "Completion extended original presentation lifetime")
        messages[messages.count - 1].status = .streaming
        messages[messages.count - 1].text += "\n\n```swift"
        update()
        try await Task.sleep(for: .milliseconds(30))
        let provisionalHeight = state.layout.totalHeight
        messages[messages.count - 1].status = .complete
        update()
        try require(!active() && state.layout.totalHeight != provisionalHeight, "Final Markdown correction did not settle immediately")
        try pinned()
        messages[messages.count - 1].text += "\nlet final = 1\n```"
        messages[messages.count - 1].status = .streaming
        update()
        view.cancelGrowthMotion()
        report.checks.append("completion-lifetime/final-markdown")

        let document = view.documentView!
        let clip = view.contentView
        func nativeHit(_ point: NSPoint) -> NSView? {
            view.hitTest(view.superview?.convert(point, from: nil) ?? point)
        }
        for kind in ["press", "context-menu", "control-click", "drag", "prepaint", "pending-only", "selection", "control"] {
            state.jumpToLatest(); update()
            try await Task.sleep(for: .milliseconds(25))
            if kind != "pending-only" {
                messages[messages.count - 1].text += String(repeating: "\n\nAnother [arrived link](https://example.com/arrived) paragraph.", count: 3)
                update()
                try await Task.sleep(for: .milliseconds(35))
            }
            // Freeze only this diagnostic phase at a sampled native presentation;
            // settling/overlap/completion above run on the normal compositor clock.
            let time = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0; layer.timeOffset = time
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(20))
            let displayedOffset = offset()
            if !reduced && kind != "pending-only" { try require(displayedOffset > 1, "No presentation for \(kind)") }
            let pinBeforePending = clip.bounds.minY
            if kind == "prepaint" || kind == "pending-only" {
                messages[messages.count - 1].text += "\n\nPending, not displayed.\n\nSecond pending paragraph."
                update(paint: false)
                try require(clip.bounds.minY > pinBeforePending, "Prepaint fixture did not change model pin")
            }
            let pendingDelta = clip.bounds.minY - pinBeforePending
            if reduced && pendingDelta != 0 {
                // Reduce Motion intentionally applies layout immediately; there
                // is no displayed compensation to preserve before paint.
                window.displayIfNeeded(); CATransaction.flush()
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let presentedDocument = layer.presentation(), let presentedClip = clip.layer?.presentation(),
                  let text = texts(view).last, let storage = text.textStorage, let layout = text.layoutManager,
                  let container = text.textContainer else { throw Failure(description: "Missing native presentation/text") }
            // Convert a real link glyph through the document/clip presentation
            // hierarchy. This independently measures the displayed character,
            // not the animation's fromValue or the logical pinned viewport.
            var target: (point: NSPoint, character: Int, wrong: Int, documentPoint: NSPoint, visibleY: CGFloat)?
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard value != nil else { return }
                let glyph = layout.glyphIndexForCharacter(at: range.location)
                let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                let local = NSPoint(x: rect.minX + text.textContainerOrigin.x + 1, y: rect.midY + text.textContainerOrigin.y)
                let pointInDocument = text.convert(local, to: document)
                let visible = presentedDocument.convert(pointInDocument, to: presentedClip)
                guard presentedClip.bounds.insetBy(dx: 20, dy: 20).contains(visible) else { return }
                let point = clip.convert(NSPoint(x: visible.x - presentedClip.bounds.minX + clip.bounds.minX,
                    y: visible.y - presentedClip.bounds.minY + clip.bounds.minY), to: nil)
                let expected = text.characterIndexForInsertion(at: local)
                let wrong = text.characterIndexForInsertion(at: text.convert(point, from: nil))
                guard reduced || wrong != expected else { return }
                target = (point, expected, wrong, pointInDocument, visible.y - presentedClip.bounds.minY); stop.pointee = true
            }
            guard let target else { throw Failure(description: "No displayed link target for \(kind)") }
            let wasActive = active()
            _ = nativeHit(target.point)
            _ = view.hitTest(NSPoint(x: -100, y: -100))
            try require(active() == wasActive && offset() == displayedOffset && clip.bounds.minY == pinBeforePending + pendingDelta,
                        "Passive/rejected hit test mutated motion")
            // A real event outside this transcript must be just as inert.
            let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: -100, y: -100), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 4242, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(outside)
            try require(active() == wasActive && clip.bounds.minY == pinBeforePending + pendingDelta, "Outside press mutated motion")
            var delivered = false
            var deliveredHit: NSView?
            let type: NSEvent.EventType = kind == "context-menu" ? .rightMouseDown : kind == "drag" ? .leftMouseDragged : .leftMouseDown
            let event = NSEvent.mouseEvent(with: type, location: target.point, modifierFlags: kind == "control-click" ? .control : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 4242, clickCount: 1, pressure: 1)!
            var control: NSButton?
            if kind == "control" {
                let button = NSButton(title: "Synthetic control", target: nil, action: nil)
                let center = text.convert(text.convert(target.point, from: nil), to: document)
                // Position in the displayed source area, not the old logical target.
                button.frame = NSRect(x: center.x - 10, y: center.y - displayedOffset - 10, width: 100, height: 20)
                document.addSubview(button); control = button
                window.displayIfNeeded(); CATransaction.flush()
                try await Task.sleep(for: .milliseconds(20))
                guard let presentedButton = button.layer?.presentation(), let buttonClip = clip.layer?.presentation() else {
                    throw Failure(description: "Missing displayed native control")
                }
                let visiblePoint = clip.convert(target.point, from: nil)
                try require(presentedButton.bounds.contains(presentedButton.convert(visiblePoint, from: buttonClip)),
                            "Control fixture is not actually displayed at the event point")
                if !reduced { try require(nativeHit(target.point) !== button, "Control fixture lacks the old incorrect target") }
            }
            window.inspectPress = {
                delivered = true
                // NSApplication's production monitor must already have rebased.
                deliveredHit = nativeHit(target.point)
            }
            if kind == "selection" {
                // Also covers programmatic/accessibility selected-range changes.
                text.setSelectedRange(NSRange(location: target.character, length: 5))
                delivered = true
                deliveredHit = nativeHit(target.point)
            } else { NSApp.sendEvent(event) }
            try require(delivered, "Synthetic event never reached the native window")
            let actual = text.characterIndexForInsertion(at: text.convert(target.point, from: nil))
            let docPoint = text.convert(text.convert(target.point, from: nil), to: document)
            // Snapshot numbers, not retained presentation-layer objects: AppKit
            // can replace/detach that tree on the next transaction (the button
            // fixture deliberately commits a display before delivering its press).
            let error = abs(docPoint.y - target.documentPoint.y)
            try require(error < 1.01 && actual == target.character,
                "\(kind) displayed anchor/target jumped: error=\(error), expected=\(target.character), oldWrong=\(target.wrong), actual=\(actual)")
            if let control { try require(deliveredHit === control, "Displayed control target lost before native delivery"); control.removeFromSuperview() }
            else { try require(deliveredHit === text, "Native link/text target lost before native delivery") }
            try require(storage.attribute(.link, at: actual, effectiveRange: nil) != nil, "Displayed link lost")
            if !reduced {
                try require(!active() && !state.followsLatest && state.anchor == state.layout.anchor(at: clip.bounds.minY), "Interaction failed to preserve reader intent/anchor")
                if kind == "prepaint" { try require(abs(clip.bounds.minY - (pinBeforePending - displayedOffset)) < 1.01, "Used pending rather than displayed geometry") }
            }
            // Verify the next committed presentation too, not just model math
            // or animation removal. No screen/window capture is involved.
            let visibleY = target.visibleY
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(20))
            guard let settledDocument = layer.presentation(), let settledClip = clip.layer?.presentation() else {
                throw Failure(description: "Missing post-interaction presentation")
            }
            let settledY = settledDocument.convert(docPoint, to: settledClip).y - settledClip.bounds.minY
            try require(abs(settledY - visibleY) < 1.01, "Committed presentation jumped after \(kind): \(settledY - visibleY)")
            report.interactions.append(Interaction(kind: kind, displayedOffset: displayedOffset, pendingPinDelta: pendingDelta,
                anchorError: error, expectedCharacter: target.character, oldIncorrectCharacter: target.wrong, actualCharacter: actual))
            if kind == "selection" {
                grow(); try require(!active(), "Selection allowed new motion")
                text.setSelectedRange(NSRange(location: 0, length: 0))
            }
            layer.speed = 1; layer.timeOffset = 0
            window.inspectPress = nil
        }
        state.jumpToLatest(); update()
        report.checks.append("passive-hit/press/menu/drag/prepaint/selection/control")
        if !reduced {
            grow()
            try await Task.sleep(for: .milliseconds(30))
            try require(offset() > 0, "Clamp fixture has no presentation")
            // Simulate a native document correction arriving before paint.
            // Preserving the old anchor is impossible outside the new range.
            document.setFrameSize(NSSize(width: document.frame.width, height: clip.bounds.height + 5))
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(NSPoint(x: 40, y: 80), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 4242, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(event)
            try require(!active() && clip.bounds.minY.isFinite && (0...5).contains(clip.bounds.minY), "Rebase escaped corrected native range")
            state.jumpToLatest(); update()
            report.checks.append("clamped-rebase")
        }
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
