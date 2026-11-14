import SwiftUI
#if canImport(ExecTranscript)
import ExecTranscript
typealias ToolCard<Content: View> = ExecTranscript.ToolCard<Content>
typealias ToolCallHeader = ExecTranscript.ToolCallHeader
#endif

// Disclosure state belongs to the conversation, not to a recycled row host.
struct ToolMessageView: View {
    let call: ToolCall
    let result: ToolResult?
    let isAwaitingApproval: Bool
    let state: TranscriptState
    let messageID: UUID
    @AppStorage(ToolDisplayPreferences.descriptiveShellTitlesKey) private var descriptiveShellTitles = false
    @State private var expanded: Bool?

    init(call: ToolCall, result: ToolResult?, isAwaitingApproval: Bool,
         state: TranscriptState, messageID: UUID) {
        self.call = call
        self.result = result
        self.isAwaitingApproval = isAwaitingApproval
        self.state = state
        self.messageID = messageID
        _expanded = State(initialValue: state.expanded[messageID])
    }

    var body: some View {
        let presentation = ToolPresentation(call: call, result: result, descriptiveShellTitles: descriptiveShellTitles)
        ToolCard(presentation: presentation, isExpanded: Binding(get: { expanded ?? (result?.edit != nil || result?.generatedImage != nil) }, set: { value in
            state.followsLatest = false
            state.expanded[messageID] = value
            expanded = value
        }), awaitingApproval: result == nil && isAwaitingApproval) {
            VStack(alignment: .leading, spacing: 12) {
                if let generated = result?.generatedImage {
                    GeneratedImageView(attachment: generated)
                } else if let screenshot = result?.screenshot, let image = NSImage(data: screenshot.data) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxHeight: 480)
                        .accessibilityLabel("Captured screenshot")
                } else if let edit = result?.edit {
                    DiffView(source: edit.diff)
                } else {
                    ForEach(presentation.inputs.indices, id: \.self) { index in
                        let field = presentation.inputs[index]
                        ToolTextSection(title: field.title, text: field.text)
                    }
                    if let search = result?.webSearch {
                        WebSearchView(result: search)
                    } else if result != nil {
                        ToolTextSection(title: presentation.outputTitle, text: presentation.output, emptyText: "No output")
                            // Match the inner code inset used by edit diffs.
                            .padding(call.name == "read_file" ? 10 : 0)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

struct ToolSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolTextSection: View {
    let title: String?
    let text: String
    var emptyText = "(empty)"

    var body: some View {
        ToolSection(title: title) {
            LinkedText(text: NSAttributedString(
                string: text.isEmpty ? emptyText : text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
        }
    }
}
