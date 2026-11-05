import AppKit
import SwiftUI

struct TranscriptView: View {
    let messages: [Message]
    let sessionID: UUID?
    @State private var followsLatest = true
    @State private var scrollTask: Task<Void, Never>?
    @State private var scrollTarget: UUID?
    private var visibleMessages: [Message] {
        messages.filter { $0.role != .assistant || !$0.text.isEmpty || $0.toolCalls.isEmpty }
    }

    var body: some View {
        let visible = visibleMessages
        ScrollViewReader { proxy in
            ScrollView {
                // Stable measured heights avoid lazy-stack jumps as streamed Markdown changes layout.
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(visible) { message in
                        MessageView(message: message, followsLatest: $followsLatest)
                            .equatable()
                            .padding(.bottom, message.id == visible.last?.id ? 12 : 0)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in follow(proxy) }
                .background(ScrollTrackingView { nearBottom in followsLatest = nearBottom })
            }
            .modifier(InitialTranscriptAnchor())
            .clipped()
            .onDisappear { scrollTask?.cancel(); scrollTask = nil }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in follow(proxy) }
            .onChange(of: sessionID) {
                followsLatest = true
                follow(proxy)
            }
            .onChange(of: messages.last?.id) {
                if messages.last?.role == .user { followsLatest = true }
                follow(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        follow(proxy)
                    } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .help("Jump to latest message").accessibilityLabel("Jump to latest message")
                    .padding(16)
                }
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        scrollTarget = visibleMessages.last?.id
        guard followsLatest, scrollTask == nil else { return }
        scrollTask = Task { @MainActor in
            // Coalesce layout changes into at most one follow per display frame.
            do { try await Task.sleep(for: .milliseconds(16)) }
            catch { return }
            scrollTask = nil
            if followsLatest, let id = scrollTarget {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

/// Establish the initial position during layout, before the first frame is shown.
/// On newer systems only the initial offset is affected: short transcripts stay
/// top-aligned and reading older messages still opts out of following new content.
private struct InitialTranscriptAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// Track user scrolling, not content growth or programmatic scrollTo calls (macOS 14+).
/// This keeps streaming from pulling the reader away from an earlier message.
private struct ScrollTrackingView: NSViewRepresentable {
    var scrolled: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.scrolled = scrolled }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { NotificationCenter.default.removeObserver(view) }

    final class TrackingView: NSView {
        var scrolled: ((Bool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if window != nil, let scroll = enclosingScrollView {
                NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                                       name: NSScrollView.didLiveScrollNotification, object: scroll)
            }
        }

        @objc private func didScroll(_ notification: Notification) {
            guard let scroll = notification.object as? NSScrollView, let document = scroll.documentView else { return }
            scrolled?(document.bounds.height - scroll.contentView.bounds.maxY <= 40)
        }
    }
}

private struct MessageView: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
    }

    let message: Message
    @Binding var followsLatest: Bool
    var body: some View {
        if let result = message.toolResult {
            ToolMessageView(result: result, followsLatest: $followsLatest)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.images.isEmpty { AttachmentStrip(images: message.images) }
                    if !message.text.isEmpty {
                        Text(verbatim: message.text).lineSpacing(3).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 600, alignment: .trailing)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("You: \(message.text)")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.status == .interrupted {
                    Label("Stopped · excluded from context", systemImage: "stop.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if message.status == .failed {
                    Label("Failed · excluded from context", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
                if !message.text.isEmpty { MarkdownView(source: message.text) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel("Assistant reply")
        }
    }
}

// Keep disclosure state outside the equatable message wrapper so local interactions
// never depend on changes to the persisted message value.
private struct ToolMessageView: View {
    let result: ToolResult
    @Binding var followsLatest: Bool
    @State private var expanded: Bool

    init(result: ToolResult, followsLatest: Binding<Bool>) {
        self.result = result
        _followsLatest = followsLatest
        _expanded = State(initialValue: result.edit != nil || result.webSearch != nil)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let edit = result.edit {
                DiffView(source: edit.diff).padding(.top, 8)
            } else if let search = result.webSearch {
                WebSearchView(result: search).padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: result.call.arguments).font(.system(.caption, design: .monospaced))
                    Text(verbatim: result.text).font(.system(.body, design: .monospaced))
                }
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let edit = result.edit {
                    Label("Edited \(edit.path)", systemImage: "pencil").font(.callout.weight(.medium))
                } else if let search = result.webSearch {
                    Label("Web search", systemImage: "magnifyingglass").font(.callout.weight(.medium))
                    Text(verbatim: search.query).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let read = ReadFileSummary(result) {
                    HStack(spacing: 8) {
                        Label("Read \(read.path)", systemImage: "doc.text")
                            .font(.callout.weight(.medium))
                            .lineLimit(1).truncationMode(.middle).help(read.path)
                        if let lines = read.lineLabel {
                            Text(lines).font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                } else {
                    Label(result.call.name, systemImage: result.call.name == "shell" ? "terminal" : "doc.text").font(.callout.weight(.medium))
                    Text(verbatim: String(result.text.split(separator: "\n").first ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .disclosureGroupStyle(InstantToolDisclosureStyle())
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onChange(of: expanded) { if expanded { followsLatest = false } }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A full-width hit target without the system disclosure control's implicit animation.
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
                        .labelStyle(ToolHeaderLabelStyle())
                    Spacer(minLength: 0)
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

private struct ToolHeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}
