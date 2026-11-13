import AppKit
import Observation

/// Window-local controls targeting one existing conversation. The library still
/// owns all runners, account state, persistence, and application-wide shutdown.
@MainActor @Observable final class ChatPanel {
    let library: ChatLibrary
    let current: ChatStore

    typealias WorkspacePicker = @MainActor (NSWindow, URL?, @escaping @MainActor (URL?) -> Void) -> Void
    private let presentWorkspacePicker: WorkspacePicker
    weak var window: NSWindow?

    init(library: ChatLibrary, conversation: ChatStore,
         presentWorkspacePicker: @escaping WorkspacePicker = ChatPanel.presentWorkspacePicker) {
        self.library = library
        current = conversation
        self.presentWorkspacePicker = presentWorkspacePicker
    }

    var title: String {
        guard hasConversation else { return "" }
        return library.sessionList.first { $0.id == current.currentSessionID }?.title ?? "Untitled"
    }
    var hasConversation: Bool { library.hasConversation(current) }
    var navigating: Bool { library.navigating }
    var canNavigate: Bool {
        !library.navigating && !library.authenticating && library.openConversations.contains { $0 === current }
    }
    var busy: Bool { !canNavigate || current.busy }
    // Account restoration blocks edits, but is not conversation activity.
    var isWorking: Bool { !library.authenticating && current.isWorking }
    var isSending: Bool { current.isSending }
    var canEditDraft: Bool { canNavigate && current.canEditDraft }
    var models: [ChatModel] { library.models }
    var modelUnavailableReason: String? {
        if !library.hasConnectedProvider { return "Connect a provider in settings" }
        return models.contains { $0.id == current.selectedModel } ? nil : "Model unavailable"
    }
    var canSend: Bool {
        canNavigate && current.hasUsableModel && modelUnavailableReason == nil && !isChoosingWorkspace
    }
    var account: String? { current.account }
    var accountUsage: AccountUsage? { library.accountUsage }
    var workspace: Workspace? { current.workspace }
    var autoApproveTools: Bool { current.autoApproveTools }
    var canCompact: Bool { canNavigate && current.canCompact }
    var canSelectWorkspace: Bool { canNavigate && current.canSelectWorkspace }
    var draft: String {
        get { current.draft }
        set { if canNavigate { current.draft = newValue } }
    }
    var selectedModel: String {
        get { models.contains(where: { $0.id == current.selectedModel }) ? current.selectedModel : "" }
        set {
            guard canNavigate, !current.busy, models.contains(where: { $0.id == newValue }), newValue != current.selectedModel else { return }
            current.selectedModel = newValue
            current.scheduleSave()
        }
    }
    var selectedEffort: String? {
        get { current.effectiveEffort }
        set {
            guard canNavigate, !current.busy, newValue == nil || current.model?.efforts.contains(where: { $0.id == newValue }) == true else { return }
            current.selectedEffort = newValue
            current.scheduleSave()
        }
    }

    private(set) var isChoosingWorkspace = false
    var canChooseWorkspace: Bool { canSelectWorkspace && !isChoosingWorkspace }

    func openWorkspaceInFinder() {
        guard canNavigate, let workspace else { return }
        NSWorkspace.shared.open(workspace.root)
    }

    func openWorkspaceInTerminal() {
        guard canNavigate, let workspace,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([workspace.root], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    var shouldChooseInitialWorkspace: Bool {
        current.needsInitialWorkspaceSelection && workspace == nil && canChooseWorkspace && window != nil
    }

    func chooseInitialWorkspaceIfNeeded() {
        guard shouldChooseInitialWorkspace else { return }
        chooseWorkspace()
    }

    func chooseWorkspace() {
        guard canChooseWorkspace, let window else { return }
        // Do not consume the request until the conversation has its own window.
        // Presenting against NSApp.keyWindow can attach to Settings or an old sheet.
        current.consumeInitialWorkspaceSelection()
        isChoosingWorkspace = true
        presentWorkspacePicker(window, workspace?.root) { [self] url in
            isChoosingWorkspace = false
            guard let url, canSelectWorkspace else { return }
            selectWorkspace(url)
        }
    }

    private static func presentWorkspacePicker(in window: NSWindow, directory: URL?,
                                               completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        panel.prompt = "Choose Workspace"
        panel.accessoryView = makeWorkspacePickerExplanation()
        panel.isAccessoryViewDisclosed = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    private static func makeWorkspacePickerExplanation() -> NSView {
        let heading = NSTextField(wrappingLabelWithString: "Choose a workspace folder")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let explanation = NSTextField(wrappingLabelWithString:
            "A workspace is the folder Exec uses for this conversation. Choose your project folder, or a folder containing the files you want help with.")
        explanation.font = .systemFont(ofSize: NSFont.systemFontSize)

        let disclosure = NSTextField(wrappingLabelWithString:
            "Exec can read, create, and edit files in the folder you choose.")
        disclosure.font = .systemFont(ofSize: NSFont.systemFontSize)
        disclosure.textColor = .secondaryLabelColor

        // Bound the wrapping width rather than using the panel message, which
        // can stretch the native folder picker to fit its text.
        let content = NSStackView(views: [heading, explanation, disclosure])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(12, after: explanation)
        content.translatesAutoresizingMaskIntoConstraints = false
        for label in [heading, explanation, disclosure] {
            label.preferredMaxLayoutWidth = 420
            label.widthAnchor.constraint(equalToConstant: 420).isActive = true
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        container.layoutSubtreeIfNeeded()
        container.setFrameSize(container.fittingSize)
        return container
    }

    func send() {
        guard canSend else { return }
        if workspace == nil && current.messages.isEmpty {
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !current.draftImages.isEmpty else { return }
            chooseWorkspace()
            return
        }
        library.send(in: current)
    }
    func selectWorkspace(_ url: URL) { library.selectWorkspace(url, in: current) }
    func compact() { if canCompact { current.compact() } }
    func setAutoApproveTools(_ enabled: Bool) { if canNavigate { current.setAutoApproveTools(enabled) } }
    func stop() {
        guard !navigating else { return }
        if library.authenticating { library.stop() }
        else { current.stop() }
    }
}
