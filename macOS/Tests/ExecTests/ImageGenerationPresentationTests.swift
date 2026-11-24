import AppKit
import SwiftUI

@MainActor struct ImageGenerationPresentationTests {
    func showsOnlyPromptInputsWithoutChangingTheHeader() throws {
        let references = ["", ",\"input_image_ids\":null", ",\"input_image_ids\":[]",
                          ",\"input_image_ids\":[\"\(UUID())\"]"]
        for reference in references {
            for transparent in [false, true] {
                let arguments = "{\"prompt\":\"Draw a tree\",\"transparent_background\":\(transparent)\(reference)}"
                for outcome in [nil, "running", "completed", "failed"] as [String?] {
                    let result = outcome.map { ToolDisplayResult(text: "Result", outcome: $0) }
                    let presentation = ToolPresentation(name: "generate_image", arguments: arguments, result: result)
                    try expect(presentation.summary == "Draw a tree")
                    try expect(presentation.inputs == [.init(title: "Prompt", text: "Draw a tree")])
                    try expect(presentation.detail == (outcome == "failed" ? "Error" : nil))
                }
            }
        }
    }

    func preservesPromptWhenOutputArrivesWithoutReferenceViews() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = ImageAttachment(name: "generated.png", mediaType: "image/png", data: bitmap.representation(using: .png, properties: [:])!)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for completed in [false, true] {
            var heights: [Bool: CGFloat] = [:]
            for reference in ["", ",\"input_image_ids\":[\"\(UUID())\"]"] {
                let call = ToolCall(id: "image", name: "generate_image", arguments:
                    "{\"prompt\":\"Draw a tree\",\"transparent_background\":true\(reference)}")
                var result: ToolResult?
                if completed {
                    var output = ToolResult(call: call, text: "Generated image asset metadata")
                    output.outcome = "completed"
                    output.generatedImage = image
                    result = output
                }
                for expanded in [false, true] {
                    let state = TranscriptState(), id = UUID()
                    state.expanded[id] = expanded
                    let host = NSHostingView(rootView: ToolMessageView(call: call, result: result,
                        isAwaitingApproval: false, state: state, messageID: id).frame(width: 600))
                    host.frame.size = host.fittingSize
                    let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    defer { window.orderOut(nil); window.contentView = nil }
                    window.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(50))
                    host.layoutSubtreeIfNeeded()
                    let views = descendants(host)
                    let text = views.compactMap { ($0 as? NSTextView)?.string }
                    try expect(text == (expanded ? ["Draw a tree"] : []))
                    try expect(!views.contains { $0 is HorizontalContentScrollView })
                    let height = host.fittingSize.height
                    if let previous = heights[expanded] { try expect(abs(height - previous) < 1) }
                    heights[expanded] = height
                }
            }
        }
    }
}
