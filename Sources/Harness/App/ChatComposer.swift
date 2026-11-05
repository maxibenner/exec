import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    @Bindable var store: ChatLibrary
    @FocusState.Binding var focused: Bool
    @State private var imageDropTargeted = false
    @State private var dismissedDraft: String?
    @State private var highlighted = 0

    private struct Choice: Identifiable {
        let id: String
        let title: String
        var detail = ""
        var selected = false
        var enabled = true
    }

    private var command: ComposerCommand? { ComposerCommand(store.draft) }
    private var paletteVisible: Bool {
        store.canNavigate && command != nil && dismissedDraft != store.draft && focused
    }
    private var page: ComposerCommand.Page? { command?.page }
    private var query: String { command?.query ?? "" }
    private var modelName: String { store.models.first { $0.id == store.selectedModel }?.name ?? store.selectedModel }
    private var effortName: String {
        let model = store.current.model
        return model?.efforts.first { $0.id == (store.selectedEffort ?? model?.defaultEffort) }?.name ?? "Default"
    }
    private var canApprove: Bool {
        store.canNavigate && store.workspace != nil && store.account != nil && (!store.isWorking || store.isSending)
    }
    private var choices: [Choice] {
        let items: [Choice]
        switch page {
        case nil:
            items = [Choice(id: "model", title: "Model", detail: modelName),
                     Choice(id: "effort", title: "Reasoning", detail: effortName),
                     Choice(id: "approve", title: "Auto-approve", detail: store.autoApproveTools ? "On" : "Off")]
        case .model:
            var models = store.models.map { Choice(id: $0.id, title: $0.name, selected: $0.id == store.selectedModel, enabled: !store.busy) }
            if !store.selectedModel.isEmpty && !models.contains(where: { $0.id == store.selectedModel }) {
                models.append(Choice(id: store.selectedModel, title: store.selectedModel, selected: true, enabled: !store.busy))
            }
            items = models
        case .effort:
            let available = !store.busy && store.current.model?.efforts.isEmpty == false
            items = [Choice(id: "", title: "Default", selected: store.current.selectedEffort == nil, enabled: available)] + (store.current.model?.efforts ?? []).map {
                Choice(id: $0.id, title: $0.name, selected: store.current.selectedEffort == $0.id, enabled: available)
            }
        case .approve:
            items = [Choice(id: "off", title: "Off", detail: "Ask before edits and shell commands", selected: !store.autoApproveTools, enabled: canApprove),
                     Choice(id: "on", title: "On", detail: "Approve edits and shell commands in this conversation", selected: store.autoApproveTools, enabled: canApprove)]
        }
        return items.filter {
            if page == nil { return ComposerCommand.Page(rawValue: $0.id)?.matches(query) == true }
            return query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            input
                .overlay(alignment: .topLeading) {
                    if paletteVisible {
                        palette
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                            .frame(height: 0, alignment: .bottom)
                    }
                }
                .zIndex(1)
            information
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .onChange(of: store.draft) { _, _ in highlighted = 0; dismissedDraft = nil }
        .onChange(of: ObjectIdentifier(store.current)) { _, _ in close() }
        .onChange(of: store.canNavigate) { _, allowed in if !allowed { close() } }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onExitCommand {
            if paletteVisible { close(); focused = true }
            else if store.isWorking { store.stop() }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.current.queuedMessages.isEmpty {
                QueuedMessagesView(store: store)
                    .anchorPreference(key: ComposerControlBounds.self, value: .bounds) { [$0] }
            }
            if !store.current.draftImages.isEmpty {
                AttachmentStrip(images: store.current.draftImages) { id in
                    store.current.draftImages.removeAll { $0.id == id }
                }
                .disabled(!store.canNavigate)
                .anchorPreference(key: ComposerControlBounds.self, value: .bounds) { [$0] }
            }
            TextField("Message", text: $store.draft, axis: .vertical)
                .lineLimit(1...8).textFieldStyle(.plain).font(.body)
                .focused($focused)
                .disabled(store.isWorking && !store.isSending).allowsHitTesting(!store.navigating)
                .accessibilityLabel("Message")
                .onSubmit {
                    if paletteVisible { chooseHighlighted() }
                    else if command != nil { dismissedDraft = nil }
                    else { store.send() }
                }
                .padding(.vertical, 8)
            HStack(spacing: 6) {
                Text(modelName.isEmpty ? "Model" : modelName)
                    .accessibilityLabel("Model: \(modelName)")
                Text("·")
                Text(effortName).accessibilityLabel("Reasoning: \(effortName)")
                Spacer(minLength: 8)
                Text(store.autoApproveTools ? "Auto-approve on" : "Auto-approve off")
                    .foregroundStyle(store.autoApproveTools ? Color.accentColor : Color.secondary)
                    .layoutPriority(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).allowsHitTesting(false)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(.background.secondary)
                .contentShape(Rectangle()).onTapGesture {
                    guard store.canNavigate, !store.isWorking || store.isSending else { return }
                    focused = true
                }
        }
        .overlayPreferenceValue(ComposerControlBounds.self) { anchors in
            GeometryReader { geometry in ComposerCursor(exclusions: anchors.map { geometry[$0] }) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(imageDropTargeted || focused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.18), lineWidth: imageDropTargeted ? 2 : 1)
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $imageDropTargeted) { providers in
            guard store.canNavigate else { return false }
            let destination = store.current
            return destination.importImages { try await ImageDrop.load(providers) } != nil
        }
    }

    private var information: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                workingControl
                Spacer(minLength: 0)
                sessionInformation
            }
            VStack(alignment: .leading, spacing: 6) {
                workingControl
                sessionInformation.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var workingControl: some View {
        if store.isWorking {
            Button(action: store.stop) {
                HStack(spacing: 8) {
                    WorkingIndicator()
                    Text("esc").font(.system(.caption, design: .monospaced))
                }
            }
            .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command)
            .help("Stop (Esc or ⌘.)").accessibilityLabel("Stop")
            .fixedSize()
        }
    }

    private var sessionInformation: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                usageInformation
                workspaceInformation
            }
            VStack(alignment: .trailing, spacing: 6) {
                usageInformation
                workspaceInformation
            }
        }
    }

    private var workspaceInformation: some View {
        WorkspaceBar(store: store)
            .frame(maxWidth: 300, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var usageInformation: some View {
        HStack(spacing: 16) {
            if let usage = store.accountUsage { AccountUsageLabel(usage: usage) }
            if let usage = store.current.contextUsage {
                Text("Context \(usage.isEstimated ? "~" : "")\(usage.percent)%")
                    .monospacedDigit().fixedSize()
                    .help("\(usage.isEstimated ? "Estimated" : "Reported") context: \(usage.tokens.formatted()) / \(usage.limit.formatted()) tokens. Excludes unsent drafts and unfinished responses.")
                    .accessibilityLabel("Context usage, \(usage.percent) percent")
            }
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                            Button { choose(choice) } label: {
                                HStack(spacing: 10) {
                                    Text(choice.title)
                                    Spacer(minLength: 4)
                                    Text(choice.detail).foregroundStyle(.secondary).lineLimit(1)
                                    Image(systemName: page == nil ? "chevron.right" : choice.selected ? "checkmark" : "")
                                        .frame(width: 12)
                                }
                                .padding(8).contentShape(Rectangle())
                                .background(index == highlighted ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).disabled(!choice.enabled).id(index)
                            .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                        }
                    }
                }
                .frame(height: CGFloat(max(1, min(choices.count, 6))) * 34)
                .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
            }
        }
        .padding(6).font(.callout)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityLabel("Composer commands")
    }

    private func close() {
        dismissedDraft = store.draft; highlighted = 0
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard paletteVisible else { return .ignored }
        highlighted = min(max(0, highlighted + delta), max(0, choices.count - 1))
        return .handled
    }

    private func chooseHighlighted() {
        guard choices.indices.contains(highlighted) else { return }
        choose(choices[highlighted])
    }

    private func choose(_ choice: Choice) {
        guard store.canNavigate, choice.enabled else { return }
        guard let page else {
            guard let destination = ComposerCommand.Page(rawValue: choice.id) else { return }
            store.draft = "/\(destination.commandName) "
            focused = true
            highlighted = 0
            return
        }
        switch page {
        case .model: guard !store.busy else { return }; store.selectedModel = choice.id
        case .effort: guard !store.busy else { return }; store.selectedEffort = choice.id.isEmpty ? nil : choice.id
        case .approve: guard canApprove else { return }; store.setAutoApproveTools(choice.id == "on")
        }
        store.draft = ""
        close(); focused = true
    }
}
