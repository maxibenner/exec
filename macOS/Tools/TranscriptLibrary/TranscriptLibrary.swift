import AppKit
import SwiftUI

@main struct TranscriptLibraryApp: App {
    var body: some Scene {
        Window("Transcript Component Library", id: "transcript-library") {
            TranscriptGallery()
                .frame(minWidth: 480, minHeight: 400)
        }
        .defaultSize(width: 860, height: 760)
    }
}

private struct TranscriptGallery: View {
    private enum Appearance: String, CaseIterable {
        case light = "Light", dark = "Dark"
    }

    @State private var appearance: Appearance = .light
    @State private var fixtures = TranscriptFixtures()
    @State private var approvalState = ToolApprovalState()
    @State private var showsQueuedMessage = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript Components").font(.headline)
                Spacer()
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    section("Messages") {
                        rows(fixtures.messages)
                        if showsQueuedMessage {
                            QueuedMessagesView(messages: [fixtures.queued], canCancel: true) { _ in
                                showsQueuedMessage = false
                            }
                        }
                    }
                    section("Connected Tool Calls") {
                        let calls = fixtures.connectedTools
                        VStack(spacing: 0) {
                            ForEach(calls.indices, id: \.self) { index in
                                MessageView(message: calls[index], state: fixtures.state,
                                            roundsTop: index == calls.startIndex,
                                            roundsBottom: index == calls.index(before: calls.endIndex))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    section("Tool Calls") {
                        rows(fixtures.tools)
                    }
                    section("Tool Approval") {
                        ForEach(fixtures.approvals) { approval in
                            // The controls are visual samples; no resolver or service is installed.
                            ToolApprovalView(approval: approval, executor: approvalState)
                        }
                    }
                    section("Activity") {
                        rows(fixtures.activity)
                        WorkingIndicator()
                            .accessibilityLabel("Assistant working")
                    }
                }
                .frame(maxWidth: TranscriptColumn.maxWidth)
                .padding(TranscriptColumn.horizontalInset)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .preferredColorScheme(appearance == .dark ? .dark : .light)
        .onChange(of: appearance, initial: true) { _, value in
            // Set the native appearance too, for the AppKit text and code views.
            NSApp.appearance = NSAppearance(named: value == .dark ? .darkAqua : .aqua)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rows(_ messages: [Message]) -> some View {
        ForEach(messages) { message in
            MessageView(message: message, state: fixtures.state)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
