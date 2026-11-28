import AppKit

@MainActor struct TranscriptFixtures {
    let state = TranscriptState()
    let messages: [Message]
    let tools: [Message]
    let approvals: [ToolApprovalState.Approval]
    let activity: [Message]
    let queued = Message(role: .user, text: "Please add a short caption for the cover illustration.")

    init() {
        let cover = Self.image(name: "coastal-trails.png", screenshot: false)
        messages = [
            Message(role: .user, text: "Could you turn these notes into a field guide for the coastal trails?",
                    images: [cover], files: [FileAttachment(name: "trail-notes.md")]),
            Message(role: .assistant, text: Self.markdown),
            Message(role: .assistant, text: "I’ve drafted the introduction and am adding the route notes…", status: .streaming),
            Message(role: .assistant, text: "The elevation chart didn’t finish. The route notes are still available.", status: .interrupted),
            Message(role: .assistant, text: "I couldn’t load the tide chart. The rest of the guide is ready.", status: .failed),
        ]

        let read = Self.call("read_file", #"{"path":"guides/coastal-trails.md","start_line":1,"end_line":4}"#)
        let edit = Self.call("edit_file", #"{"path":"guides/coastal-trails.md"}"#)
        let search = Self.call("web_search", #"{"query":"coastal trail planning and tide safety"}"#)
        let fetch = Self.call("fetch_content", #"{"url":"https://example.com/parks/coastal-trails"}"#)
        let generate = Self.call("generate_image", #"{"prompt":"A flat illustration of coastal hills at sunset, in indigo and sage."}"#)
        let capture = Self.call("take_screenshot", #"{"target":"window","window_id":42}"#)
        let delegate = Self.call("delegate", #"{"tasks":[{"title":"Review route notes","task":"Check the route descriptions for clarity."},{"title":"Review packing list","task":"Suggest one item for a windy day at the coast."}]}"#)
        let pending = Self.call("shell", #"{"command":"wc -l guides/coastal-trails.md"}"#)
        let wait = Self.call("wait", #"{"duration_seconds":15,"description":"Wait for the preview to refresh","wake_prompt":"Inspect the updated guide preview."}"#)
        tools = [
            Self.result(.init(call: Self.call("shell", #"{"command":"wc -w guides/coastal-trails.md","description":"Count guide words"}"#),
                              text: "     248 guides/coastal-trails.md")),
            Self.result(.init(call: Self.call("list_files", #"{"path":"guides"}"#),
                              text: "coastal-trails.md\npacking-list.md\nroute-map.png")),
            Self.result(.init(call: read, text: "Revision: 6ab49e21\n1: # Coastal Trails\n2:\n3: Follow the bluff path to the lookout.\n4: Check the tide before taking the beach route.")),
            Self.result(.init(call: Self.call("search_text", #"{"path":"guides","query":"lookout"}"#),
                              text: "guides/coastal-trails.md:3:Follow the bluff path to the lookout.")),
            Self.result(.init(call: edit, text: "Updated the trail guide.",
                              edit: .init(path: "guides/coastal-trails.md", diff: Self.diff))),
            Self.result(.init(call: search, text: "Two sources found.", webSearch: .init(
                query: "coastal trail planning and tide safety",
                answer: "Check the **tide forecast** before leaving, and favor the bluff route if the beach is narrow.",
                sources: [.init(title: "NOAA Tides & Currents", url: "https://tidesandcurrents.noaa.gov/"),
                          .init(title: "National Park Service", url: "https://www.nps.gov/")]))),
            Self.result(.init(call: fetch, text: "Fetched page", pageText: "Coastal Trails Park\n\nThe bluff trail is open year-round. Bring water; there are no refill stations beyond the trailhead.")),
            Self.result(.init(call: delegate, text: "**Route notes:** Use the bluff path at high tide.\n\n**Packing list:** Add a lightweight windbreaker.")),
            Self.result(.init(call: generate, text: "Created the cover illustration.", generatedImage: cover)),
            Self.result(.init(call: capture, text: "Captured the guide preview.", screenshot: Self.image(name: "guide-preview.png", screenshot: true))),
            Message(role: .tool, text: "", status: .streaming, pendingTool: .init(call: wait)),
            Message(role: .tool, text: "", pendingTool: .init(call: pending, isAwaitingApproval: true)),
            Self.result(.init(call: edit, text: "User denied this file edit.", outcome: "denied")),
            Self.result(.init(call: fetch, text: "Tool error: The page didn’t respond in time.", outcome: "failed")),
            Self.result(.init(call: search, text: "Interrupted. The search ended before it returned sources.", outcome: "interrupted")),
            Self.result(.init(call: read, text: "Not executed: An earlier action was canceled.", outcome: "not_executed")),
        ]
        // Reveal representative result bodies at launch while keeping the cards interactive.
        for message in tools where message.pendingTool?.isAwaitingApproval != true {
            state.expanded[message.id] = true
        }

        let directory = URL(fileURLWithPath: "/preview")
        approvals = [
            .init(id: UUID(), kind: .shell, content: "wc -l guides/coastal-trails.md", directory: directory, filePath: nil),
            .init(id: UUID(), kind: .edit, content: Self.diff, directory: directory, filePath: "guides/coastal-trails.md"),
            .init(id: UUID(), kind: .screenshot, content: "Share the window ‘Coastal Trails — Preview’ in this conversation?",
                  directory: directory, filePath: nil),
        ]
        activity = [
            Message(role: .assistant, text: "", status: .streaming, compaction: .automatic),
            Message(role: .assistant, text: "", compaction: .manual),
        ]
    }

    private static func call(_ name: String, _ arguments: String) -> ToolCall {
        ToolCall(id: UUID().uuidString, name: name, arguments: arguments)
    }

    private static func result(_ result: ToolResult) -> Message {
        Message(role: .tool, text: "", toolResult: result)
    }

    private static let markdown = """
    # Coastal Trails

    Start at the **north trailhead** and follow the _bluff path_. The `west-loop` marker leads to the overlook. Check the [tide forecast](https://tidesandcurrents.noaa.gov/) before taking the beach route.

    ## Route Notes

    > At high tide, stay on the bluff path. The beach route can disappear under water.

    1. Start at the visitor center.
    2. Follow the markers to Seal Point.

    ### What to Bring

    - Water and a windbreaker
      - Pack a dry layer for the overlook.
    - A downloaded map

    | Route | Terrain | Distance |
    | :--- | :---: | ---: |
    | Bluff path | Gravel | 3.2 km |
    | Beach route | Sand | 1.8 km |

    ---

    ```swift
    struct Trail {
        let name: String
        let distanceInKilometers: Double
    }

    // Main route from the visitor center
    let recommended = Trail(name: "Bluff path", distanceInKilometers: 3.2)
    ```
    """

    private static let diff = """
    --- a/guides/coastal-trails.md
    +++ b/guides/coastal-trails.md
    @@ -1,4 +1,5 @@
     # Coastal Trails
    \u{20}
    -Follow the coastal path to the lookout.
    +Follow the bluff path to the lookout.
     Check the tide before taking the beach route.
    +Bring a windbreaker for the exposed ridge.
    """

    // Draw fixture art locally; no image generation or screen capture takes place.
    private static func image(name: String, screenshot: Bool) -> ImageAttachment {
        let image = NSImage(size: NSSize(width: 360, height: 160), flipped: true) { bounds in
            if screenshot {
                NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1).setFill()
                bounds.fill()
                NSColor.white.setFill()
                NSRect(x: 12, y: 12, width: 336, height: 136).fill()
                NSColor.lightGray.setFill()
                NSRect(x: 12, y: 12, width: 336, height: 20).fill()
                let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 21), .foregroundColor: NSColor.black]
                let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray]
                ("Coastal Trails" as NSString).draw(at: NSPoint(x: 28, y: 49), withAttributes: heading)
                ("Bluff path · 3.2 km\nStart at the north trailhead and follow the ridge." as NSString)
                    .draw(at: NSPoint(x: 28, y: 85), withAttributes: body)
            } else {
                NSColor(srgbRed: 0.98, green: 0.79, blue: 0.59, alpha: 1).setFill()
                bounds.fill()
                NSColor(srgbRed: 0.995, green: 0.91, blue: 0.71, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 247, y: 22, width: 54, height: 54)).fill()
                NSColor(srgbRed: 0.35, green: 0.55, blue: 0.52, alpha: 1).setFill()
                let hills = NSBezierPath()
                hills.move(to: NSPoint(x: 0, y: 90))
                hills.curve(to: NSPoint(x: 360, y: 106), controlPoint1: NSPoint(x: 125, y: 10), controlPoint2: NSPoint(x: 225, y: 170))
                hills.line(to: NSPoint(x: 360, y: 160))
                hills.line(to: NSPoint(x: 0, y: 160))
                hills.close()
                hills.fill()
                NSColor(srgbRed: 0.22, green: 0.28, blue: 0.43, alpha: 1).setFill()
                let coast = NSBezierPath()
                coast.move(to: NSPoint(x: 0, y: 140))
                coast.curve(to: NSPoint(x: 360, y: 97), controlPoint1: NSPoint(x: 134, y: 190), controlPoint2: NSPoint(x: 260, y: 71))
                coast.line(to: NSPoint(x: 360, y: 160))
                coast.line(to: NSPoint(x: 0, y: 160))
                coast.close()
                coast.fill()
            }
            return true
        }
        let png = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        return ImageAttachment(name: name, mediaType: "image/png", data: png ?? Data())
    }
}
