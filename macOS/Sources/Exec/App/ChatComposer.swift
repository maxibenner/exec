import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    @Bindable var store: ChatPanel
    var overlayScrollerInset: CGFloat = 0
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
    private var page: ComposerCommand.Page? { command?.page.flatMap { $0.hasOptions ? $0 : nil } }
    private var query: String {
        if let action = command?.page, !action.hasOptions { return action.commandName }
        return command?.query ?? ""
    }
    private var modelName: String { store.models.first { $0.id == store.selectedModel }?.name ?? "Model unavailable" }
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
            items = [Choice(id: "model", title: "model", detail: modelName, enabled: !store.models.isEmpty),
                     Choice(id: "effort", title: "reasoning", detail: effortName, enabled: store.current.model?.efforts.isEmpty == false),
                     Choice(id: "approve", title: "auto-approve", detail: store.autoApproveTools ? "On" : "Off", enabled: canApprove),
                     Choice(id: "compact", title: "compact", enabled: store.canCompact),
                     Choice(id: "workspace", title: "workspace", detail: "Change workspace…", enabled: store.canChooseWorkspace),
                     Choice(id: "finder", title: "finder", detail: "Open workspace in Finder", enabled: store.workspace != nil),
                     Choice(id: "terminal", title: "terminal", detail: "Open workspace in Terminal", enabled: store.workspace != nil)]
        case .model:
            items = store.models.map {
                Choice(id: $0.id, title: $0.name, detail: store.library.modelGroups.count > 1 ? store.library.providerName(for: $0.id) : "",
                       selected: $0.id == store.selectedModel, enabled: store.canNavigate)
            }
        case .effort:
            let available = store.canNavigate && store.current.model?.efforts.isEmpty == false
            items = [Choice(id: "", title: "Default", selected: store.current.selectedEffort == nil, enabled: available)] + (store.current.model?.efforts ?? []).map {
                Choice(id: $0.id, title: $0.name, selected: store.current.selectedEffort == $0.id, enabled: available)
            }
        case .approve, .compact, .workspace, .finder, .terminal:
            items = [] // Actions stay in the root command list.

        }
        return items.filter {
            if page == nil { return ComposerCommand.Page(rawValue: $0.id)?.matches(query) == true }
            return query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            input
                .overlay(alignment: .topLeading) {
                    if paletteVisible {
                        palette
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                            .frame(height: 0, alignment: .bottom)
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 20).padding(.top, 12)
                .frame(maxWidth: .infinity)
                .background(alignment: .bottom) {
                    // Join the footer background behind the input's rounded bottom corners.
                    footerBackground.frame(height: 12)
                }
                .zIndex(1)
            information
                .frame(maxWidth: 820)
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .background { footerBackground }
        }
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

    private var footerBackground: some View {
        Rectangle().fill(.background)
            .padding(.trailing, overlayScrollerInset)
            .allowsHitTesting(false)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.current.draftImages.isEmpty {
                AttachmentStrip(images: store.current.draftImages) { id in
                    store.current.draftImages.removeAll { $0.id == id }
                }
                .disabled(!store.canNavigate)
                .anchorPreference(key: ComposerControlBounds.self, value: .bounds) { [$0] }
            }
            TextField("Message or / for commands", text: $store.draft, axis: .vertical)
                .lineLimit(1...8).textFieldStyle(.plain).font(.body)
                .focused($focused)
                .disabled(!store.canEditDraft).allowsHitTesting(!store.navigating)
                .accessibilityLabel("Message")
                .onSubmit {
                    if paletteVisible { chooseHighlighted() }
                    else if command != nil { dismissedDraft = nil }
                    else { store.send() }
                }
                .padding(.vertical, 8)
            HStack(spacing: 6) {
                if let reason = store.modelUnavailableReason {
                    Text(reason).foregroundStyle(AppColors.unavailableRed)
                } else {
                    Text(modelName).accessibilityLabel("Model: \(modelName)")
                    Text("·")
                    Text(effortName).accessibilityLabel("Reasoning: \(effortName)")
                }
                Spacer(minLength: 8)
                Text(store.autoApproveTools ? "Auto on" : "Auto off")
                    .foregroundStyle(store.autoApproveTools ? Color.accentColor : Color.secondary)
                    .layoutPriority(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).allowsHitTesting(false)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle()).onTapGesture {
                    guard store.canEditDraft else { return }
                    focused = true
                }
        }
        .overlayPreferenceValue(ComposerControlBounds.self) { anchors in
            GeometryReader { geometry in ComposerCursor(exclusions: anchors.map { geometry[$0] }) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(imageDropTargeted || focused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.18), lineWidth: imageDropTargeted ? 4 : 2)
                .allowsHitTesting(false)
        }
        .overlay {
            // Keep file/image drops above the native text field so its default
            // drop handling cannot insert a file path into the draft. Leave the
            // clear layer without a contentShape so clicks and selection pass through.
            Color.clear
                .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $imageDropTargeted) { providers in
                    guard store.canNavigate else { return false }
                    let destination = store.current
                    return destination.importImages { try await ImageDrop.load(providers) } != nil
                }
                .accessibilityHidden(true)
        }
    }

    private var information: some View {
        HStack(spacing: 0) {
            workingControl
            Spacer(minLength: 0)
            let usage = store.current.contextUsage
            Text(usage.map { "Context \($0.percent)%" } ?? "Context —")
                .monospacedDigit().fixedSize()
                .help(usage.map { "Last reported context: \($0.tokens.formatted()) / \($0.limit.formatted()) tokens. Excludes unsent drafts and unfinished responses." } ?? "Context usage has not been reported yet.")
                .accessibilityLabel(usage.map { "Context usage, \($0.percent) percent" } ?? "Context usage unavailable")
        }
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: 20)
    }

    @ViewBuilder private var workingControl: some View {
        if store.isWorking {
            HStack(spacing: 8) {
                Button(action: store.stop) {
                    WorkingIndicator()
                }
                .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command)
                .help("Stop (Esc or ⌘.)").accessibilityLabel("Stop")
                Text("esc").font(.system(.caption, design: .monospaced))
                    .allowsHitTesting(false)
            }
            .fixedSize()
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
                                    Group {
                                        if page == nil, ComposerCommand.Page(rawValue: choice.id)?.hasOptions == true {
                                            Image(systemName: "chevron.right")
                                        } else if choice.selected {
                                            Image(systemName: "checkmark")
                                        } else { Color.clear }
                                    }
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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
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
            switch destination {
            case .approve:
                guard canApprove else { return }
                store.setAutoApproveTools(!store.autoApproveTools)
                store.draft = ""
                close()
            case .compact:
                guard store.canCompact else { return }
                store.draft = ""
                close()
                store.compact()
            case .workspace:
                guard store.canChooseWorkspace else { return }
                store.draft = ""
                close()
                store.chooseWorkspace()
            case .finder:
                guard store.workspace != nil else { return }
                store.draft = ""
                close()
                store.openWorkspaceInFinder()
            case .terminal:
                guard store.workspace != nil else { return }
                store.draft = ""
                close()
                store.openWorkspaceInTerminal()
            case .model, .effort:
                store.draft = "/\(destination.commandName) "
                highlighted = 0
            }
            focused = true
            return
        }
        switch page {
        case .model: store.selectedModel = choice.id
        case .effort: store.selectedEffort = choice.id.isEmpty ? nil : choice.id
        case .approve, .compact, .workspace, .finder, .terminal: return
        }
        store.draft = ""
        close(); focused = true
    }
}
