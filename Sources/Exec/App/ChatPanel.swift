import AppKit
import Observation

/// Window-local controls targeting one existing conversation. The library still
/// owns all runners, account state, persistence, and application-wide shutdown.
@MainActor @Observable final class ChatPanel {
    let library: ChatLibrary
    let current: ChatStore

    init(library: ChatLibrary, conversation: ChatStore) {
        self.library = library
        current = conversation
    }

    var navigating: Bool { library.navigating }
    var canNavigate: Bool {
        !library.navigating && !library.authenticating && library.openConversations.contains { $0 === current }
    }
    var busy: Bool { !canNavigate || current.busy }
    var isWorking: Bool { library.authenticating || current.busy }
    var isSending: Bool { current.isSending }
    var canEditDraft: Bool { canNavigate && current.canEditDraft }
    var models: [ChatModel] { library.models }
    var account: String? { current.account }
    var accountUsage: AccountUsage? { library.accountUsage }
    var workspace: Workspace? { current.workspace }
    var autoApproveTools: Bool { current.autoApproveTools }
    var canCompact: Bool { canNavigate && current.canCompact }
    var canSelectWorkspace: Bool { canNavigate && !current.busy && current.messages.isEmpty }
    var draft: String {
        get { current.draft }
        set { if canNavigate { current.draft = newValue } }
    }
    var selectedModel: String {
        get { current.selectedModel }
        set {
            guard !busy, newValue != current.selectedModel else { return }
            current.selectedModel = newValue
            current.scheduleSave()
        }
    }
    var selectedEffort: String? {
        get { current.effectiveEffort }
        set {
            guard !busy, newValue == nil || current.model?.efforts.contains(where: { $0.id == newValue }) == true else { return }
            current.selectedEffort = newValue
            current.scheduleSave()
        }
    }

    private var folderPanel: NSOpenPanel?
    var canChooseWorkspace: Bool { canSelectWorkspace && folderPanel == nil }

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

    func chooseWorkspace() {
        guard canChooseWorkspace else { return }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let panel = NSOpenPanel()
        folderPanel = panel
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = workspace?.root
        panel.prompt = "Choose Workspace"
        // Keep the disclosure out of the panel message, whose intrinsic width
        // can stretch the native folder picker.
        let notice = NSTextField(wrappingLabelWithString: "The model can read, write, and edit files in this directory.")
        notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notice.textColor = .secondaryLabelColor
        notice.preferredMaxLayoutWidth = 420
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.widthAnchor.constraint(equalToConstant: 420).isActive = true
        notice.setContentCompressionResistancePriority(.required, for: .vertical)
        panel.accessoryView = notice
        panel.isAccessoryViewDisclosed = true
        let completion: (NSApplication.ModalResponse) -> Void = { [self] response in
            folderPanel = nil
            guard response == .OK, let url = panel.url, canSelectWorkspace else { return }
            selectWorkspace(url)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    func send() { if canNavigate { library.send(in: current) } }
    func resumeQueuedMessages() { if canNavigate { library.resumeQueuedMessages(in: current) } }
    func selectWorkspace(_ url: URL) { library.selectWorkspace(url, in: current) }
    func compact() { if canCompact { current.compact() } }
    func setAutoApproveTools(_ enabled: Bool) { if canNavigate { current.setAutoApproveTools(enabled) } }
    func stop() {
        guard !navigating else { return }
        if library.authenticating { library.stop() }
        else { current.stop() }
    }
}
