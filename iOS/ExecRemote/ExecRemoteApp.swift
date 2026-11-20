import SwiftUI
import UIKit
import ExecRemote
import ExecTranscript

/// UIKit is confined to this adapter; store tests inject grants and expiration.
@MainActor private struct ApplicationSendBackgroundTime: SendBackgroundTime {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> (() -> Void)? {
        let application = UIApplication.shared
        let identifier = application.beginBackgroundTask(withName: "Send message") {
            MainActor.assumeIsolated { expiration() }
        }
        guard identifier != .invalid else { return nil }
        return { application.endBackgroundTask(identifier) }
    }
}

enum ToolDisplayPreferences {
    static let descriptiveShellTitlesKey = "descriptiveShellTitles"
}

@main struct ExecRemoteApp: App {
    private let preferences: UserDefaults = {
        #if DEBUG && targetEnvironment(simulator)
        if RemoteUIFixture.enabled { return RemoteUIFixture.preferences }
        #endif
        return .standard
    }()
    @State private var store: RemoteStore = {
        #if DEBUG && targetEnvironment(simulator)
        if RemoteUIFixture.enabled { return RemoteUIFixture.makeStore() }
        #endif
        return RemoteStore(backgroundTime: ApplicationSendBackgroundTime())
    }()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .defaultAppStorage(preferences)
                .onChange(of: phase, initial: true) { _, phase in
                    switch phase {
                    case .active: store.sceneChanged(.active)
                    case .inactive: store.sceneChanged(.inactive)
                    case .background: store.sceneChanged(.background)
                    @unknown default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @Bindable var store: RemoteStore
    @State private var scanning = false
    @State private var creating = false
    @State private var createdSession: String?
    var body: some View {
        NavigationStack {
            Group {
                if store.host == nil { pairing }
                else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        List {
                            ForEach(RemoteSessionListDay.group(store.conversations)) { group in
                                Section {
                                    ForEach(group.families) { family in
                                        sessionRow(family)
                                    }
                                } header: {
                                    Text(group.day.title(now: context.date))
                                        .font(.title3.bold())
                                        .foregroundStyle(Color(uiColor: .label))
                                        .textCase(nil)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .accessibilityIdentifier("session-list")
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .refreshable { await store.poll() }
                        .overlay {
                            if store.conversations.isEmpty {
                                if store.isLoadingConversations {
                                    ProgressView()
                                } else if store.hasLoadedConversations {
                                    VStack(spacing: 12) {
                                        Image(systemName: "bubble.left.and.bubble.right")
                                            .font(.system(size: 32))
                                            .accessibilityHidden(true)
                                        Text("No Sessions")
                                            .font(.subheadline)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(store.host == nil ? "" : "All Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(store.host == nil ? .hidden : .visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.host != nil {
                    SessionControls(canForget: store.canForget,
                                    settings: store.showSettings,
                                    forget: { Task { await store.forget() } },
                                    create: { creating = true })
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
            .background(Color(uiColor: store.host == nil ? .systemBackground : .systemGroupedBackground))
            .overlay(alignment: .bottom) {
                if !store.settings.isPresented && !creating && !scanning {
                    SessionNotice(message: Binding(get: { store.visibleError }, set: { store.error = $0 })).padding(.bottom, 72)
                }
            }
            .navigationDestination(item: $store.selected) { id in
                ConversationScreen(store: store, conversationID: id)
                    .id(id)
            }
            .sheet(isPresented: $scanning) {
                ScannerView { text in
                    scanning = false
                    Task { await store.pair(text) }
                }
            }
            .sheet(isPresented: $store.settings.isPresented, onDismiss: { store.settings.didDismiss() }) {
                SharedSettingsScreen(store: store)
            }
            .sheet(isPresented: $creating, onDismiss: {
                if let id = createdSession { createdSession = nil; store.selected = id }
            }) {
                NewChatScreen(store: store) { createdSession = $0 }
            }
        }
        .background { HostConnectionOverlay(isVisible: store.showsConnectionFailure) }
    }
    private func sessionRow(_ family: RemoteSessionListDay.Family) -> some View {
        let row = family.parent
        let conversation = row.conversation
        let title = conversation["metadata"]["title"].string ?? conversation["title"].string ?? "New Session"
        let workspace = conversation["workspace"].string.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let date = RemoteSessionDay.activityDate(conversation)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(row.isSubagent ? .subheadline : .headline)
                    .foregroundStyle(row.isSubagent ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                if !row.isSubagent {
                    Group {
                        if RemoteMessageSubmission.isActive(conversation) {
                            ProgressView().controlSize(.small)
                                .tint(Color(uiColor: .secondaryLabel))
                                .accessibilityLabel("Active")
                                .accessibilityIdentifier("session-active-\(conversation.id)")
                        } else {
                            Color.clear.accessibilityHidden(true)
                        }
                    }
                    .frame(width: 16, height: 20)
                }
            }
            .allowsHitTesting(false)
            ForEach(family.children) { child in
                Button { store.selected = child.id } label: {
                    Text(child.conversation["metadata"]["title"].string ?? "Sub-agent")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(child.conversation["unreadable"].bool)
                .accessibilityIdentifier("session-\(child.id)")
            }
            if !row.isSubagent {
                HStack(spacing: 8) {
                    Text(workspace).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(date, format: .dateTime.hour().minute()).fixedSize()
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(.vertical, row.isSubagent ? 2 : 6)
        .background {
            // Child buttons sit above this full-card target; all other content opens the parent.
            Button { store.selected = conversation.id } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(row.isSubagent ? "" : "\(workspace), \(date.formatted(date: .omitted, time: .shortened))")
            .accessibilityIdentifier("session-\(conversation.id)")
            .disabled(conversation["unreadable"].bool)
        }
        .accessibilityElement(children: .contain)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !row.isSubagent {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await store.deleteConversation(conversation.id) }
                }
                .disabled(!store.canDeleteConversation(conversation))
                .tint(.red)
            }
        }
    }

    private var pairing: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Pair Device")
                .font(.headline)
            Text("On your Mac, open Exec → Settings → Remote Access.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button { scanning = true } label: {
                Text("Scan Pairing QR Code")
                    .frame(maxWidth: .infinity)
            }
            .modifier(PrimaryActionButtonStyle())
            .controlSize(.large)
            .disabled(store.isConnecting)
            .padding()
        }
    }
}

/// Action errors remain separate from persistent connection state.
private struct SessionNotice: View {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let message {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.red)
                // Include padding and the empty column below the icon in a
                // multiline notice's drag target, not just its rendered text.
                .contentShape(Rectangle())
                // Begin alongside a sheet's pan without taking text selection
                // away. Only a clear downward drag dismisses the action error.
                .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { value in
                    if value.translation.height >= 40, value.translation.height > abs(value.translation.width) {
                        self.message = nil
                    }
                })
                .accessibilityElement(children: .contain)
                .accessibilityAction(.escape) { self.message = nil }
                .accessibilityIdentifier("session-notice")
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}

struct PrimaryActionButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent).tint(AppColors.blue).foregroundStyle(.white)
        } else {
            content.buttonStyle(.borderedProminent).tint(AppColors.blue).foregroundStyle(.white)
        }
    }
}

private struct SessionControls: View {
    let canForget: Bool
    let settings: () -> Void
    let forget: () -> Void
    let create: () -> Void

    var body: some View {
        HStack {
            if #available(iOS 26.0, *) {
                controls.buttonStyle(.glass)
            } else {
                controls.buttonStyle(.bordered)
            }
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.primary)
        .font(.body.weight(.semibold))
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    @ViewBuilder private var controls: some View {
        Menu {
            Button("Settings", systemImage: "gearshape", action: settings)
            Button("Forget Host", systemImage: "trash", role: .destructive, action: forget).disabled(!canForget)
        } label: {
            Label("Session Options", systemImage: "ellipsis")
                .frame(width: 24, height: 24)
        }
        Spacer()
        Button(action: create) {
            Label("New Session", systemImage: "plus")
                .frame(width: 24, height: 24)
        }
        .modifier(PrimaryActionButtonStyle())
    }
}

struct ConversationScreen: View {
    @Bindable var store: RemoteStore
    let conversationID: String
    @AppStorage(ToolDisplayPreferences.descriptiveShellTitlesKey) private var descriptiveShellTitles = false
    @State private var showsLoadingSpinner = false
    @State private var composerHeight: CGFloat = 68
    @State private var presentation: ConversationPresentation

    init(store: RemoteStore, conversationID: String) {
        self.store = store
        self.conversationID = conversationID
        _presentation = State(initialValue: ConversationPresentation(
            conversationID: conversationID, catalog: store.conversations, snapshot: store.displaySnapshot))
    }

    private var currentPresentation: ConversationPresentation {
        var current = presentation
        current.update(store.displaySnapshot)
        return current
    }

    var body: some View {
        let current = currentPresentation
        let queued = store.pendingMessage.flatMap { $0.conversationID == conversationID ? $0.transcriptMessage : nil } ?? .null
        let isLoading = current.snapshot == .null && store.selected == conversationID
            && store.loadingConversations.contains(conversationID)
        ZStack {
            NativeTranscript(conversationID: conversationID, snapshot: current.snapshot,
                             showsThinkingIndicator: store.thinking.visible.contains(conversationID),
                             queuedMessage: queued, cancelQueuedMessage: { store.cancelPendingMessage(rowID: $0) },
                             descriptiveShellTitles: descriptiveShellTitles,
                             viewState: store.transcriptViewState(for: conversationID),
                             saveViewState: { id, value in store.saveTranscriptViewState(value, for: id) },
                             bottomPadding: composerHeight, hasEarlier: store.selected == conversationID && store.hasEarlierMessages,
                             loadEarlier: { Task { if store.selected == conversationID { await store.loadEarlier() } } })
                // Replace only the empty UIKit transcript, not the composer's
                // focus-owning overlay, when a cold session receives history.
                .id(current.snapshot == .null && queued == .null)
            if isLoading && showsLoadingSpinner {
                ProgressView()
                    .tint(.secondary)
                    .accessibilityLabel("Loading conversation")
                    .accessibilityIdentifier("conversation-loading-spinner")
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .task(id: isLoading) {
            showsLoadingSpinner = false
            guard isLoading else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            showsLoadingSpinner = true
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar(.hidden, for: .bottomBar)
        .onChange(of: conversationID, initial: true) { _, id in
            if store.selected == id { store.open(id) }
        }
        .onChange(of: store.displaySnapshot, initial: true) { _, snapshot in
            presentation.update(snapshot)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let failure = current.snapshot["operation"]["error"].string ?? current.snapshot["storageError"].string {
                    Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .padding(10)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                if current.snapshot["approval"] != .null {
                    let target = RemoteStore.ApprovalTarget(snapshot: current.snapshot)
                    VStack(spacing: 10) {
                        Text(current.snapshot["approval"]["description"].string ?? "Approve tool execution?").font(.callout).textSelection(.enabled)
                        DisclosureGroup {
                            Text(String(decoding: (try? JSONEncoder().encode(current.snapshot["approval"]["call"])) ?? Data(), as: UTF8.self))
                                .font(.caption.monospaced()).textSelection(.enabled).frame(maxHeight: 140)
                        } label: {
                            let tool = ToolDisplayMetadata(name: current.snapshot["approval"]["call"]["name"].string ?? "Tool")
                            Label(tool.label, systemImage: tool.icon)
                        }
                        .accessibilityIdentifier("approval-tool-details")
                        HStack {
                            Button("Deny", role: .destructive) {
                                if let target { Task { await store.approve(target, approved: false) } }
                            }
                            Spacer()
                            Button("Approve") {
                                if let target { Task { await store.approve(target, approved: true) } }
                            }.buttonStyle(.borderedProminent).tint(AppColors.blue)
                        }
                    }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .disabled(target.map { store.canApprove($0) } != true)
                }
                RemoteChatComposer(store: store)
            }
            .disabled(store.selected != conversationID)
            .padding(.horizontal, 12).padding(.vertical, 8)
            // Restored multiline drafts must update the transcript's scroll clearance.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .overlay(alignment: .bottom) {
            SessionNotice(message: Binding(get: { store.visibleError }, set: { store.error = $0 })).padding(.bottom, 72)
        }
    }
}

private struct RemoteChatComposer: View {
    let store: RemoteStore
    @FocusState private var focused: Bool
    @State private var fieldHeight: CGFloat = 48
    private var draft: Binding<String> {
        Binding(get: { store.selected.flatMap { store.drafts[$0] } ?? "" },
                set: { if let id = store.selected { store.drafts[id] = $0 } })
    }
    private var stopping: Bool { RemoteMessageSubmission.showsStop(snapshot: store.displaySnapshot, draft: draft.wrappedValue) }
    private var field: some View {
        TextField("Message", text: draft, axis: .vertical)
            .focused($focused)
            .tint(AppColors.blue)
            .accessibilityIdentifier("message-composer")
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(minHeight: 48)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ComposerFieldHeightKey.self, value: geometry.size.height)
                }
            }
    }
    private var outline: some View {
        RoundedRectangle(cornerRadius: 26)
            .strokeBorder(focused ? AppColors.blue : .clear, lineWidth: 1)
            .allowsHitTesting(false)
    }
    private var action: some View {
        Button {
            let stopping = stopping
            if stopping { Task { await store.stop() } }
            else { store.beginSend() }
        } label: {
            Image(systemName: stopping ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .accessibilityLabel(stopping ? "Stop" : (store.active ? "Queue Message" : "Send"))
        .buttonBorderShape(.capsule)
        .disabled(stopping ? !store.canStop : !store.canSend)
    }
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) {
                        field.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26)).overlay { outline }
                        action.buttonStyle(.glassProminent).tint(AppColors.blue).frame(width: 48, height: fieldHeight)
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    field.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26)).overlay { outline }
                    action.buttonStyle(.plain).foregroundStyle(.white)
                        .frame(width: 48, height: fieldHeight)
                        .background(AppColors.blue, in: Capsule())
                }
            }
        }
        .onPreferenceChange(ComposerFieldHeightKey.self) { fieldHeight = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer-controls")
    }
}

private struct ComposerFieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 48
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct NewChatScreen: View {
    let store: RemoteStore
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var tools = RemoteSessionCreation.ToolSelection(library: .null)
    @State private var initialized = false
    @State private var choosingFolder = false
    private var selectedModel: RemoteJSON { store.models.first { $0.id == model } ?? .null }
    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    Button {
                        guard store.connected else { return }
                        choosingFolder = true
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(workspace.isEmpty ? "Choose Folder" : workspace)
                                .foregroundStyle(workspace.isEmpty ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(!store.connected)
                    .accessibilityIdentifier("new-session-workspace")
                }
                Section("Model selection") {
                    Picker("Model", selection: $model) {
                        ForEach(store.models, id: \.id) { model in Text(model["name"].string ?? model.id).tag(model.id) }
                    }
                    Picker("Reasoning", selection: $effort) {
                        Text("Default").tag("")
                        ForEach(selectedModel["efforts"].array, id: \.id) { option in
                            Text(option["name"].string ?? option.id).tag(option.id)
                        }
                    }
                    .disabled(selectedModel["efforts"].array.isEmpty)
                }
                .disabled(!initialized)
                Section("Tools") {
                    ForEach(RemoteSessionCreation.tools) { tool in
                        Toggle(isOn: Binding(get: { tools.isEnabled(tool.id) },
                                             set: { tools.setEnabled(tool.id, $0) })) {
                            Label(tool.label, systemImage: tool.icon)
                        }
                        .accessibilityIdentifier("new-session-tool-\(tool.id)")
                    }
                }
                .disabled(!initialized)
            }
            .accessibilityIdentifier("new-session-form")
            .sheet(isPresented: $choosingFolder) {
                HostFolderPicker(store: store, initialPath: workspace) { workspace = $0 }
            }
            .navigationTitle("New Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).foregroundStyle(.secondary)
                        .disabled(store.isCreatingSession)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task {
                        let body = RemoteSessionCreation.body(workspace: workspace, model: selectedModel,
                                                              effort: effort, settings: store.library["settings"], tools: tools)
                        await store.mutate("POST", "/v1/conversations", body) { value in
                            created(value.id); dismiss()
                        }
                    } }.disabled(!workspace.hasPrefix("/") || !initialized || selectedModel.id.isEmpty || store.isCreatingSession || !store.connected)
                        .modifier(PrimaryActionButtonStyle())
                }
            }
            .onAppear(perform: initializeDefaults)
            .onChange(of: store.hasLoadedLibrary) { _, _ in initializeDefaults() }
            .onChange(of: model) { _, _ in resetEffort() }
            .overlay(alignment: .bottom) {
                if !choosingFolder {
                    SessionNotice(message: Binding(get: { store.visibleError }, set: { store.error = $0 }))
                }
            }
        }
        .interactiveDismissDisabled(store.isCreatingSession)
    }
    private func initializeDefaults() {
        guard !initialized, store.hasLoadedLibrary || store.library != .null else { return }
        initialized = true
        if workspace.isEmpty { workspace = store.conversations.first?["workspace"].string ?? "" }
        if model.isEmpty { model = store.library["defaultModel"].string ?? store.models.first?.id ?? "" }
        tools = RemoteSessionCreation.ToolSelection(library: store.library)
        resetEffort()
    }
    private func resetEffort() {
        effort = RemoteSessionCreation.initialEffort(model: selectedModel, settings: store.library["settings"])
    }
}

struct SharedSettingsScreen: View {
    @Bindable var store: RemoteStore
    @AppStorage(ToolDisplayPreferences.descriptiveShellTitlesKey) private var descriptiveShellTitles = false
    @FocusState private var editingPrompt: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle("Descriptive shell titles", isOn: $descriptiveShellTitles)
                        .accessibilityIdentifier("descriptive-shell-titles")
                    Group {
                        Toggle("Automatic session titles", isOn: Binding(get: { store.library["automaticTitles"].bool }, set: { value in patch(["automaticTitles":.bool(value)]) }))
                        Toggle("Auto mode for new chats", isOn: Binding(get: { store.library["settings"]["autoApprove"].bool }, set: { value in patch(["settings":.object(["autoApprove":.bool(value)])]) }))
                        Picker("Default model", selection: Binding(get: { store.library["defaultModel"].string ?? "" }, set: { value in patch(["defaultModel": value.isEmpty ? .null : .string(value)]) })) {
                            Text("Automatic").tag("")
                            ForEach(store.models, id: \.id) { model in Text(model["name"].string ?? model.id).tag(model.id) }
                        }
                    }
                    .disabled(!store.canEditSharedSettings)
                }
                Section("System Prompt") {
                    TextEditor(text: $store.settings.prompt).frame(minHeight: 120).focused($editingPrompt)
                        .accessibilityIdentifier("settings-system-prompt")
                }
                .disabled(!store.canEditSharedSettings)
            }
            .accessibilityIdentifier("settings-form")
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.settings.actionTitle) {
                        editingPrompt = false
                        store.finishSettings()
                    }
                    .accessibilityIdentifier("settings-done")
                    .modifier(PrimaryActionButtonStyle())
                    .disabled(store.settings.hasUnsavedChanges && store.hasLoadedLibrary && !store.canEditSharedSettings)
                }
            }
            .onAppear { store.refreshSettings() }
            .onChange(of: store.hasLoadedLibrary) { _, _ in store.refreshSettings(editing: editingPrompt) }
            .onChange(of: store.library["settings"]["systemPrompt"]) { _, _ in
                store.refreshSettings(editing: editingPrompt)
            }
            .overlay(alignment: .bottom) {
                SessionNotice(message: Binding(get: { store.settings.error ?? store.visibleError }, set: {
                    if store.settings.error != nil { store.settings.error = $0 }
                    else { store.error = $0 }
                }))
            }
        }
        .interactiveDismissDisabled(store.settings.hasUnsavedChanges)
    }
    private func patch(_ value: [String:RemoteJSON]) { Task { await store.mutate("PATCH", "/v1/library", .object(value)) } }
}

/// Native navigation/list controls over the agent's read-only directory endpoint.
/// UIDocumentPicker would select an iPhone folder, not a workspace on the host.
private struct HostFolderPicker: View {
    private struct LoadRequest: Hashable {
        let path: String?
        let connected: Bool
    }

    let store: RemoteStore
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var listing: RemoteJSON = .null
    @State private var requestedPath: String?
    @State private var readGeneration = 0
    @State private var failure: String?
    init(store: RemoteStore, initialPath: String, choose: @escaping (String) -> Void) {
        self.store = store; self.choose = choose
        _requestedPath = State(initialValue: initialPath.isEmpty ? nil : initialPath)
    }
    private var currentPath: String? {
        guard let path = listing["path"].string, path.hasPrefix("/") else { return nil }
        return path
    }
    var body: some View {
        NavigationStack {
            Group {
                if !store.connected {
                    Text(RemoteStore.hostConnectionRequiredMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("host-folder-offline")
                } else {
                    List {
                        Section {
                            if let parent = listing["parent"].string {
                                Button("back up", systemImage: "arrow.turn.left.up") { requestedPath = parent }
                            }
                            ForEach(listing["directories"].array, id: \.folderPath) { directory in
                                Button { requestedPath = directory["path"].string } label: {
                                    Label(directory["name"].string ?? "Folder", systemImage: "folder")
                                        .foregroundStyle(AppColors.blue)
                                }
                                .accessibilityIdentifier("host-folder-\(directory.folderPath)")
                            }
                        } header: {
                            if let currentPath {
                                Text(currentPath).font(.callout).textCase(nil).textSelection(.enabled)
                                    .padding(.bottom, 8)
                            }
                        }
                        if listing["truncated"].bool {
                            Text("This folder is too large to list completely. Some folders are not shown.").font(.caption)
                        }
                        if let failure { Text(failure).foregroundStyle(.red) }
                    }
                    .accessibilityIdentifier("host-folder-list")
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // A pending or failed read does not invalidate the displayed folder.
                    Button("Choose") { if let currentPath { choose(currentPath); dismiss() } }
                        .disabled(currentPath == nil)
                        .modifier(PrimaryActionButtonStyle())
                }
            }
            .task(id: LoadRequest(path: requestedPath, connected: store.connected)) {
                readGeneration += 1
                let generation = readGeneration
                failure = nil
                guard store.connected else { return }
                do {
                    // Drain already-issued reads even after navigation or dismissal;
                    // cancelling a secure-channel receive would close the shared socket.
                    let path = requestedPath
                    let request = Task { try await store.browseFolders(path, showHidden: false) }
                    let value = try await request.value
                    guard generation == readGeneration, !Task.isCancelled else { return }
                    listing = value
                } catch {
                    guard generation == readGeneration, !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
        }
    }
}
private extension RemoteJSON { var folderPath: String { self["path"].string ?? "" } }
