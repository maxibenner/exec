import SwiftUI

/// Shared tool disclosure/header. Its owner keeps expansion state by stable row
/// identity, so both AppKit and UIKit virtualized lists may recycle the view.
public struct ToolCard<Content: View>: View {
    let presentation: ToolPresentation
    @Binding var isExpanded: Bool
    let awaitingApproval: Bool
    let content: Content
    public init(presentation: ToolPresentation, isExpanded: Binding<Bool>, awaitingApproval: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.presentation = presentation; _isExpanded = isExpanded
        self.awaitingApproval = awaitingApproval; self.content = content()
    }
    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) { content } label: {
            HStack(spacing: 8) {
                ToolCallHeader(presentation: presentation)
                Color.clear.frame(width: 16, height: 16).overlay {
                    if awaitingApproval {
                        Image(systemName: "hand.raised").foregroundStyle(.secondary).accessibilityLabel("Awaiting approval")
                    }
                }
            }
        }
        .disclosureGroupStyle(InstantToolDisclosureStyle())
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

public struct ToolCallHeader: View {
    let presentation: ToolPresentation
    public init(presentation: ToolPresentation) { self.presentation = presentation }
    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.icon).frame(width: 16)
            Text(verbatim: presentation.title).fontWeight(.medium).fixedSize()
            if let summary = presentation.singleLineSummary {
                Text(verbatim: summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    #if os(macOS)
                    .help(presentation.summary ?? summary)
                    #endif
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

private struct ToolHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
private struct InstantToolDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
            }
            .buttonStyle(ToolHeaderButtonStyle())
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
