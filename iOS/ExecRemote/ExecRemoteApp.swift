import SwiftUI
import ExecRemote

@main struct ExecRemoteApp: App {
    @State private var store = RemoteStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .task(id: phase) {
                    if phase == .active { await store.observe() }
                    else { await store.suspend() }
                }
        }
    }
}

struct RootView: View {
    @Bindable var store: RemoteStore
    @State private var invitation = ""
    @State private var scanning = false
    @State private var settings = false
    @State private var creating = false
    @State private var forgetting = false
    var body: some View {
        NavigationStack {
            Group {
                if store.host == nil { pairing }
                else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        List {
                            ForEach(RemoteSessionDay.group(store.conversations)) { day in
                                Section {
                                    ForEach(day.conversations, id: \.id) { conversation in
                                        sessionRow(conversation)
                                    }
                                } header: {
                                    Text(day.title(now: context.date))
                                        .font(.title3.bold())
                                        .foregroundStyle(Color(uiColor: .label))
                                        .textCase(nil)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .refreshable { do { try await store.refresh() } catch { store.error = error.localizedDescription } }
                        .overlay { if store.conversations.isEmpty { ContentUnavailableView("No Sessions", systemImage: "bubble.left.and.bubble.right") } }
                    }
                }
            }
            .navigationTitle(store.host == nil ? "Exec" : "All Sessions")
            .navigationBarTitleDisplayMode(store.host == nil ? .large : .inline)
            .toolbar {
                if store.host != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Menu {
                            Button("Settings", systemImage: "gearshape") { settings = true }
                            Button("Reconnect", systemImage: "arrow.clockwise") { Task { await store.connect() } }
                            Button("Forget Host", systemImage: "trash", role: .destructive) { forgetting = true }
                        } label: { Label("Session Options", systemImage: "ellipsis") }.disabled(store.busy)
                    }
                    ToolbarItem(placement: .bottomBar) { Spacer() }
                    ToolbarItem(placement: .bottomBar) {
                        Button("New Chat", systemImage: "square.and.pencil") { creating = true }.disabled(!store.connected || store.busy)
                    }
                }
            }
            .navigationDestination(isPresented: Binding(get: { store.selected != nil }, set: { if !$0 { store.selected = nil } })) {
                ConversationScreen(store: store)
            }
            .safeAreaInset(edge: .bottom) {
                if let error = store.error {
                    HStack(alignment: .top) {
                        Text(error).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") { store.error = nil }.labelStyle(.iconOnly)
                    }.padding().background(.regularMaterial)
                }
            }
            .sheet(isPresented: $scanning) {
                ScannerView { text in
                    scanning = false
                    Task { await store.pair(text) }
                }
            }
            .sheet(isPresented: $settings) { SharedSettingsScreen(store: store) }
            .sheet(isPresented: $creating) { NewChatScreen(store: store) }
            .confirmationDialog("Forget this host? Revoke this device on the Mac to remove its authorization.", isPresented: $forgetting) {
                Button("Forget Host", role: .destructive) { Task { await store.forget() } }
            }
        }
    }
    private func sessionRow(_ conversation: RemoteJSON) -> some View {
        Button { store.selected = conversation.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(conversation["metadata"]["title"].string ?? conversation["title"].string ?? "New Chat")
                    .font(.headline).foregroundStyle(Color(uiColor: .label)).lineLimit(1)
                HStack {
                    Text(RemoteSessionDay.activityDate(conversation), format: .dateTime.hour().minute())
                        .fixedSize()
                    Spacer(minLength: 16)
                    if let workspace = conversation["workspace"].string, !workspace.isEmpty {
                        Text(URL(fileURLWithPath: workspace).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .disabled(conversation["unreadable"].bool)
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await store.deleteConversation(conversation.id) }
            }
            .disabled(store.busy || !store.connected || RemoteMessageSubmission.isActive(conversation))
        }
    }

    private var pairing: some View {
        Form {
            Section {
                Button("Scan Pairing QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
            }
            Section {
                TextEditor(text: $invitation).frame(minHeight: 120).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Pairing invitation")
                Button("Pair") {
                    let text = invitation; invitation = ""
                    Task { await store.pair(text) }
                }.disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
            } header: { Text("Pairing Invitation") } footer: {
                Text("On your Mac, open Exec → Settings → Remote Access. You can paste an invitation when a camera is unavailable.")
            }
        }
    }
}

struct ConversationScreen: View {
    @Bindable var store: RemoteStore
    @State private var composerHeight: CGFloat = 68
    var body: some View {
        NativeTranscript(conversationID: store.selected, snapshot: store.displaySnapshot, bottomPadding: composerHeight)
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(store.snapshot["metadata"]["title"].string ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .bottomBar)
        .onChange(of: store.selected, initial: true) { _, id in
            if let id { store.open(id) }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let failure = store.snapshot["operation"]["error"].string ?? store.snapshot["storageError"].string {
                    Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if store.snapshot["approval"] != .null {
                    VStack(spacing: 10) {
                        Text(store.snapshot["approval"]["description"].string ?? "Approve tool execution?").font(.callout).textSelection(.enabled)
                        DisclosureGroup("Tool Details") {
                            Text(String(decoding: (try? JSONEncoder().encode(store.snapshot["approval"]["call"])) ?? Data(), as: UTF8.self))
                                .font(.caption.monospaced()).textSelection(.enabled).frame(maxHeight: 140)
                        }
                        HStack {
                            Button("Deny", role: .destructive) { Task { await store.approve(false) } }
                            Spacer()
                            Button("Approve") { Task { await store.approve(true) } }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .disabled(store.busy || !store.connected)
                }
                RemoteChatComposer(store: store)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ComposerHeightKey.self, value: geometry.size.height)
                }
            }
        }
        .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 68
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct RemoteChatComposer: View {
    let store: RemoteStore
    @State private var fieldHeight: CGFloat = 48
    private var draft: Binding<String> {
        Binding(get: { store.selected.flatMap { store.drafts[$0] } ?? "" },
                set: { if let id = store.selected { store.drafts[id] = $0 } })
    }
    private var stopping: Bool { RemoteMessageSubmission.showsStop(snapshot: store.displaySnapshot, draft: draft.wrappedValue) }
    private var field: some View {
        TextField("Message", text: draft, axis: .vertical)
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
    private var action: some View {
        Button {
            let stopping = stopping
            Task { if stopping { await store.stop() } else { await store.send() } }
        } label: {
            Image(systemName: stopping ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .accessibilityLabel(stopping ? "Stop" : (store.active ? "Queue Message" : "Send"))
        .buttonBorderShape(.capsule)
        .disabled(store.busy || store.awaitingSendSnapshot || !store.connected || (!stopping && draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) {
                        field.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                        action.buttonStyle(.glassProminent).frame(width: 48, height: fieldHeight)
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    field.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
                    action.buttonStyle(.plain).foregroundStyle(.white)
                        .frame(width: 48, height: fieldHeight)
                        .background(.blue, in: Capsule())
                }
            }
        }
        .onPreferenceChange(ComposerFieldHeightKey.self) { fieldHeight = $0 }
    }
}

private struct ComposerFieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 48
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct NewChatScreen: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var choosingFolder = false
    private var selectedModel: RemoteJSON { store.models.first { $0.id == model } ?? .null }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { choosingFolder = true } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(workspace.isEmpty ? "Choose Folder" : workspace)
                                .foregroundStyle(workspace.isEmpty ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                Section {
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
            }
            .sheet(isPresented: $choosingFolder) {
                HostFolderPicker(store: store, initialPath: workspace) { workspace = $0 }
            }
            .navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task {
                        let body = RemoteSessionCreation.body(workspace: workspace, model: selectedModel,
                                                              effort: effort, settings: store.library["settings"])
                        await store.mutate("POST", "/v1/conversations", body) { value in
                            store.selected = value.id; dismiss()
                        }
                    } }.disabled(!workspace.hasPrefix("/") || model.isEmpty || store.busy)
                }
            }
            .onAppear {
                workspace = store.conversations.first?["workspace"].string ?? ""
                model = store.library["defaultModel"].string ?? store.models.first?.id ?? ""
                resetEffort()
            }
            .onChange(of: model) { _, _ in resetEffort() }
        }
    }
    private func resetEffort() {
        effort = RemoteSessionCreation.initialEffort(model: selectedModel, settings: store.library["settings"])
    }
}

struct SharedSettingsScreen: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @FocusState private var editingPrompt: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section("Shared Agent Settings") {
                    Toggle("Automatic session titles", isOn: Binding(get: { store.library["automaticTitles"].bool }, set: { value in patch(["automaticTitles":.bool(value)]) }))
                    Toggle("Auto mode for new chats", isOn: Binding(get: { store.library["settings"]["autoApprove"].bool }, set: { value in patch(["settings":.object(["autoApprove":.bool(value)])]) }))
                    Picker("Default model", selection: Binding(get: { store.library["defaultModel"].string ?? "" }, set: { value in patch(["defaultModel": value.isEmpty ? .null : .string(value)]) })) {
                        Text("Automatic").tag("")
                        ForEach(store.models, id: \.id) { model in Text(model["name"].string ?? model.id).tag(model.id) }
                    }
                }
                Section("System Prompt") {
                    TextEditor(text: $prompt).frame(minHeight: 120).focused($editingPrompt)
                    Button("Save System Prompt") { editingPrompt = false; patch(["settings":.object(["systemPrompt":.string(prompt)])]) }
                }
            }
            .disabled(store.busy || !store.connected)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { prompt = store.library["settings"]["systemPrompt"].string ?? "" }
            .onChange(of: store.library["settings"]["systemPrompt"]) { _, value in if !editingPrompt { prompt = value.string ?? "" } }
        }
    }
    private func patch(_ value: [String:RemoteJSON]) { Task { await store.mutate("PATCH", "/v1/library", .object(value)) } }
}

/// Native navigation/list controls over the agent's read-only directory endpoint.
/// UIDocumentPicker would select an iPhone folder, not a workspace on the host.
private struct HostFolderPicker: View {
    let store: RemoteStore
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var listing: RemoteJSON = .null
    @State private var requestedPath: String?
    @State private var loading = false
    @State private var failure: String?
    init(store: RemoteStore, initialPath: String, choose: @escaping (String) -> Void) {
        self.store = store; self.choose = choose
        _requestedPath = State(initialValue: initialPath.isEmpty ? nil : initialPath)
    }
    private var currentPath: String? { listing["path"].string }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let parent = listing["parent"].string {
                        Button("back up", systemImage: "arrow.turn.left.up") { requestedPath = parent }
                    }
                    ForEach(listing["directories"].array, id: \.folderPath) { directory in
                        Button { requestedPath = directory["path"].string } label: {
                            HStack {
                                Label(directory["name"].string ?? "Folder", systemImage: "folder")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
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
            .disabled(loading)
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") { if let currentPath { choose(currentPath); dismiss() } }
                        .disabled(currentPath == nil || loading || failure != nil)
                }
            }
            .task(id: requestedPath) {
                loading = true; failure = nil
                defer { loading = false }
                do {
                    // Let an already-issued read finish when dismissing the sheet;
                    // cancelling a secure-channel receive would close the shared socket.
                    let path = requestedPath
                    let request = Task { try await store.browseFolders(path, showHidden: false) }
                    let value = try await request.value
                    try Task.checkCancellation()
                    listing = value
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
        }
    }
}
private extension RemoteJSON { var folderPath: String { self["path"].string ?? "" } }
