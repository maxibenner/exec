import SwiftUI

public enum ToolCardAppearance {
    public static var fill: some ShapeStyle { HierarchicalShapeStyle.quaternary.opacity(0.25) }

    public static var outline: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }
}

/// Shared tool disclosure/header. Its owner keeps expansion state by stable row
/// identity, so both AppKit and UIKit virtualized lists may recycle the view.
public struct ToolCard<Content: View>: View {
    let presentation: ToolPresentation
    @Binding var isExpanded: Bool
    let awaitingApproval: Bool
    let isRunning: Bool
    let roundsTop: Bool
    let roundsBottom: Bool
    let showsBackground: Bool
    let content: Content
    public init(presentation: ToolPresentation, isExpanded: Binding<Bool>, awaitingApproval: Bool = false, isRunning: Bool = false,
                roundsTop: Bool = true, roundsBottom: Bool = true, showsBackground: Bool = true,
                @ViewBuilder content: () -> Content) {
        self.presentation = presentation; _isExpanded = isExpanded
        self.awaitingApproval = awaitingApproval
        self.isRunning = isRunning || presentation.isRunning
        self.roundsTop = roundsTop
        self.roundsBottom = roundsBottom
        self.showsBackground = showsBackground
        self.content = content()
    }
    public var body: some View {
        let disclosure = DisclosureGroup(isExpanded: $isExpanded) { content } label: {
            HStack(spacing: 8) {
                ToolCallHeader(presentation: presentation)
                Color.clear.frame(width: 16, height: 16).overlay {
                    if isRunning {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Running")
                    } else if awaitingApproval {
                        Image(systemName: "hand.raised").foregroundStyle(.secondary).accessibilityLabel("Awaiting approval")
                    }
                }
            }
        }
        .disclosureGroupStyle(InstantToolDisclosureStyle(
            headerShape: showsBackground ? shape(roundsBottom: roundsBottom && !isExpanded) : nil))

        Group {
            if showsBackground {
                let outline = shape(roundsBottom: roundsBottom)
                disclosure.clipShape(outline).overlay {
                    outline.strokeBorder(ToolCardAppearance.outline)
                        // The preceding card already draws the shared edge.
                        .padding(.top, roundsTop ? 0 : -1)
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            } else {
                disclosure
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func shape(roundsBottom: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: roundsTop ? 8 : 0,
            bottomLeadingRadius: roundsBottom ? 8 : 0,
            bottomTrailingRadius: roundsBottom ? 8 : 0,
            topTrailingRadius: roundsTop ? 8 : 0)
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
    let headerShape: UnevenRoundedRectangle?

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolDisclosureHeader(label: configuration.label, isExpanded: configuration.isExpanded, shape: headerShape) {
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.isExpanded.toggle() }
            }
            if configuration.isExpanded {
                configuration.content.padding(.top, headerShape == nil ? 0 : 12)
            }
        }
    }
}

private struct ToolDisclosureHeader<Label: View>: View {
    let label: Label
    let isExpanded: Bool
    let shape: UnevenRoundedRectangle?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                label
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
        }
        .buttonStyle(ToolHeaderButtonStyle())
        .background {
            if let shape { shape.fill(ToolCardAppearance.fill) }
        }
        .overlay(alignment: .bottom) {
            if shape != nil && isExpanded {
                // Match the collapsed outline, drawn inside the header's bottom edge.
                Rectangle().fill(ToolCardAppearance.outline)
                    .frame(height: 1)
                    .padding(.horizontal, 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
