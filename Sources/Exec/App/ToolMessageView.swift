import SwiftUI

// Disclosure state belongs to the conversation, not to a recycled row host.
struct ToolMessageView: View {
    let result: ToolResult
    let state: TranscriptState
    let messageID: UUID
    @State private var expanded: Bool

    init(result: ToolResult, state: TranscriptState, messageID: UUID) {
        self.result = result
        self.state = state
        self.messageID = messageID
        _expanded = State(initialValue: state.expanded[messageID] ?? (result.edit != nil || result.webSearch != nil))
    }

    var body: some View {
        let presentation = ToolPresentation(result)
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in
            state.followsLatest = false
            state.expanded[messageID] = value
            expanded = value
        })) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(presentation.inputs.indices, id: \.self) { index in
                    let field = presentation.inputs[index]
                    ToolTextSection(title: field.title, text: field.text)
                }
                if let search = result.webSearch {
                    WebSearchView(result: search)
                } else {
                    ToolTextSection(title: presentation.outputTitle, text: presentation.output, emptyText: "No output")
                    if let edit = result.edit {
                        ToolSection(title: "Changes") { DiffView(source: edit.diff) }
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            ToolCallHeader(presentation: presentation)
        }
        .disclosureGroupStyle(InstantToolDisclosureStyle())
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ToolCallHeader: View {
    let presentation: ToolPresentation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.icon).frame(width: 16)
            Text(verbatim: presentation.title).fontWeight(.medium).fixedSize()
            if let summary = presentation.singleLineSummary {
                Text(verbatim: summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(presentation.summary ?? summary)
            }
            if let detail = presentation.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolTextSection: View {
    let title: String
    let text: String
    var emptyText = "(empty)"

    var body: some View {
        ToolSection(title: title) {
            Text(verbatim: text.isEmpty ? emptyText : text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Keep the full header clickable, with no implicit disclosure animation.
private struct InstantToolDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 12)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
