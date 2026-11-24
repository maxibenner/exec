import AppKit
import SwiftUI

@MainActor struct ImageReferencePreviewTests {
    func presentationKeepsReferencesOutOfHeadersAndTextFields() throws {
        let first = UUID(), second = UUID()
        let prompt = "Edit the reference images"
        let baseline = ToolPresentation(name: "generate_image", arguments: "{\"prompt\":\"\(prompt)\",\"transparent_background\":false}")
        let cases: [(String, [UUID])] = [
            ("", []), (",\"input_image_ids\":null", []), (",\"input_image_ids\":[]", []),
            (",\"input_image_ids\":[\"\(second)\",\"\(first)\"]", [second, first]),
            (",\"input_image_ids\":[\"https://example.com/image.png\"]", []),
            (",\"input_image_ids\":[\"/tmp/image.png\"]", [])
        ]
        for (references, ids) in cases {
            let arguments = "{\"prompt\":\"\(prompt)\",\"transparent_background\":false\(references)}"
            for outcome in [nil, "running", "completed", "failed"] as [String?] {
                let result = outcome.map { ToolDisplayResult(text: "Result", outcome: $0) }
                let presentation = ToolPresentation(name: "generate_image", arguments: arguments, result: result)
                try expect(presentation.referenceImageIDs == ids)
                try expect(presentation.title == baseline.title && presentation.icon == baseline.icon)
                try expect(presentation.summary == prompt && presentation.singleLineSummary == baseline.singleLineSummary)
                try expect(presentation.detail == (outcome == "failed" ? "Error" : nil))
                try expect(presentation.inputs == [.init(title: "Prompt", text: prompt), .init(title: "Background", text: "Opaque")])
            }
        }
        let promptOnly = ToolPresentation(name: "generate_image", arguments: #"{"prompt":"Draw a tree","input_image_ids":[]}"#)
        try expect(promptOnly.inputs == [.init(title: "Prompt", text: "Draw a tree")])
        let noPrompt = ToolPresentation(name: "generate_image", arguments: #"{"input_image_ids":[]}"#)
        try expect(noPrompt.inputs.isEmpty && noPrompt.referenceImageIDs.isEmpty)
        let otherTool = ToolPresentation(name: "shell", arguments: "{\"command\":\"true\",\"input_image_ids\":[\"\(first)\"]}")
        try expect(otherTool.referenceImageIDs.isEmpty)
    }

    func resolvesOnlyEarlierManagedTranscriptImagesInInputOrder() throws {
        func image(_ name: String) -> ImageAttachment {
            ImageAttachment(name: name, mediaType: "image/png", data: Data([1]))
        }
        let user = image("user.png"), generated = image("generated.png"), screenshot = image("screenshot.png")
        let failed = image("failed.png"), running = image("running.png"), external = image("other-session.png")
        let missing = image("not-loaded.png"), future = image("future.png"), queued = image("queued.png"), output = image("output.png")
        let cache = Dictionary(uniqueKeysWithValues: [user, generated, screenshot, failed, running, external, future, queued, output].map { ($0.id, $0) })
        func reference(_ image: ImageAttachment) -> AgentJSON {
            .object(["id": .string(image.id.uuidString), "name": .string(image.name), "mediaType": .string(image.mediaType),
                     "width": .number(1), "height": .number(1), "byteCount": .number(1), "sha256": .string(String(repeating: "0", count: 64))])
        }
        func message(_ role: String, _ fields: [String: AgentJSON]) -> AgentJSON {
            .object(["id": .string(UUID().uuidString), "role": .string(role), "text": .string("")].merging(fields) { _, value in value })
        }
        func call(_ id: String, _ arguments: AgentJSON, name: String = "generate_image") -> AgentJSON {
            .object(["id": .string(id), "name": .string(name), "arguments": arguments])
        }
        func imageDetails(_ image: ImageAttachment, origin: String = "generated") -> AgentJSON {
            .object(["type": .string("image"), "origin": .string(origin), "image": reference(image)])
        }
        var history = [message("user", ["images": .array([reference(user), reference(missing)])])]
        for (asset, origin, outcome) in [(generated, "generated", "completed"), (screenshot, "screenshot", "completed"),
                                          (failed, "generated", "failed"), (running, "generated", "running")] {
            let id = asset.id.uuidString
            history.append(message("assistant", ["calls": .array([call(id, .object([:]), name: origin == "screenshot" ? "take_screenshot" : "generate_image")])]))
            history.append(message("tool", ["callID": .string(id), "outcome": .string(outcome), "details": imageDetails(asset, origin: origin)]))
        }
        // All are valid UUIDs, but only three belong to eligible, loaded history.
        let requested = [screenshot, external, failed, user, missing, running, generated, future, queued, output]
        let cases: [(AgentJSON?, [ImageAttachment])] = [
            (nil, []), (.null, []), (.array([]), []),
            (.array(requested.map { .string($0.id.uuidString) }), [screenshot, user, generated])
        ]
        for (references, expected) in cases {
            var arguments: [String: AgentJSON] = ["prompt": .string("Edit images"), "transparent_background": .bool(false)]
            if let references { arguments["input_image_ids"] = references }
            var pendingIDs: [String: UUID] = [:]
            for outcome in [nil, "completed", "failed"] as [String?] {
                guard case .object(var fixture) = try AgentIntegrationTests.fixture(state: "running", result: true) else {
                    throw CheckFailure(description: "Expected snapshot fixture")
                }
                var messages = history + [message("assistant", ["calls": .array([call("edit", .object(arguments))])])]
                if let outcome {
                    messages.append(message("tool", ["callID": .string("edit"), "outcome": .string(outcome),
                                                       "details": outcome == "completed" ? imageDetails(output) : .null]))
                }
                messages.append(message("user", ["images": .array([reference(future)])]))
                fixture["messages"] = .array(messages)
                fixture["pendingInput"] = .array([message("user", ["images": .array([reference(queued)])])])
                fixture["activeToolCallID"] = outcome == nil ? .string("edit") : .null
                fixture["approval"] = .null
                let snapshot = try AgentJSON.object(fixture).decoded(AgentSnapshot.self)
                let rows = try snapshot.transcript(images: cache, pendingIDs: &pendingIDs)
                guard let row = rows.first(where: { ($0.pendingTool?.call.id ?? $0.toolResult?.call.id) == "edit" }) else {
                    throw CheckFailure(description: "Missing image tool row")
                }
                try expect(row.images == expected && row.id == pendingIDs["edit"])
                try expect((row.pendingTool != nil) == (outcome == nil))
                try expect(row.toolResult?.generatedImage == (outcome == "completed" ? output : nil))
            }
        }
    }

    func referencePreviewsAppearOnlyInExpandedCards() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = ImageAttachment(name: "reference.png", mediaType: "image/png", data: bitmap.representation(using: .png, properties: [:])!)
        func previewStrips(in view: NSView) -> [HorizontalContentScrollView] {
            (view as? HorizontalContentScrollView).map { [$0] } ?? view.subviews.flatMap { previewStrips(in: $0) }
        }
        for completed in [false, true] {
            var collapsedHeight: CGFloat?
            var expandedWithoutReferences: CGFloat?
            for references in ["", ",\"input_image_ids\":null", ",\"input_image_ids\":[]", ",\"input_image_ids\":[\"\(image.id)\"]"] {
                let call = ToolCall(id: "edit", name: "generate_image", arguments: "{\"prompt\":\"Draw a tree\",\"transparent_background\":false\(references)}")
                let previews = ToolPresentation(call: call).referenceImageIDs.isEmpty ? [] : [image]
                var result: ToolResult?
                if completed {
                    var generated = ToolResult(call: call, text: "Generated image")
                    generated.outcome = "completed"
                    generated.generatedImage = image
                    result = generated
                }
                for expanded in [false, true] {
                    let state = TranscriptState(), id = UUID()
                    state.expanded[id] = expanded
                    let host = NSHostingView(rootView: ToolMessageView(call: call, result: result, referenceImages: previews,
                        isAwaitingApproval: false, state: state, messageID: id).frame(width: 600))
                    host.frame.size = host.fittingSize
                    let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    defer { window.orderOut(nil); window.contentView = nil }
                    window.orderFront(nil)
                    // Allow the thumbnail task to settle before checking native views and size.
                    try await Task.sleep(for: .milliseconds(50))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let showsReferences = expanded && !previews.isEmpty
                    let strips = previewStrips(in: host)
                    try expect(strips.count == (showsReferences ? 1 : 0))
                    if let strip = strips.first {
                        try expect(strip.documentView != nil && strip.frame.height >= 80)
                    }
                    let height = host.fittingSize.height
                    if !expanded {
                        if let collapsedHeight { try expect(abs(height - collapsedHeight) < 1) }
                        else { collapsedHeight = height }
                    } else if let baseline = expandedWithoutReferences {
                        // Empty/absent/null references add neither a label nor preview space.
                        try expect(showsReferences ? height >= baseline + 90 : abs(height - baseline) < 1)
                    } else {
                        expandedWithoutReferences = height
                    }
                }
            }
        }
    }
}
