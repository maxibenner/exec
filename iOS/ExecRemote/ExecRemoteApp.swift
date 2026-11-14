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
                    List(store.conversations, id: \.id) { conversation in
                        Button { store.selected = conversation.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation["metadata"]["title"].string ?? conversation["title"].string ?? "New Chat")
                                    .foregroundStyle(.primary).lineLimit(2)
                                Text(conversation["workspace"].string ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.disabled(conversation["unreadable"].bool)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.deleteConversation(conversation.id) } }
                                .disabled(store.busy || !store.connected || ["running", "awaiting_approval", "cancelling"].contains(conversation["operation"]["state"].string ?? ""))
                        }
                    }
                    .refreshable { do { try await store.refresh() } catch { store.error = error.localizedDescription } }
                    .overlay { if store.conversations.isEmpty { ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right") } }
                }
            }
            .navigationTitle(store.host == nil ? "Exec" : "")
            .navigationBarTitleDisplayMode(store.host == nil ? .large : .inline)
            .toolbar {
                if store.host != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Settings", systemImage: "gearshape") { settings = true }
                            Button("Reconnect", systemImage: "arrow.clockwise") { Task { await store.connect() } }
                            Button("Forget Host", systemImage: "trash", role: .destructive) { forgetting = true }
                        } label: { Image(systemName: "ellipsis.circle") }.disabled(store.busy)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
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
    var body: some View {
        NativeTranscript(conversationID: store.selected, messages: store.snapshot["messages"].array)
        .navigationTitle(store.snapshot["metadata"]["title"].string ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.selected) { if let id = store.selected { await store.open(id) } }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let failure = store.snapshot["operation"]["error"].string ?? store.snapshot["storageError"].string {
                    Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if store.snapshot["approval"] != .null {
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
                RemoteChatComposer(store: store)
            }.padding(.horizontal, 12).padding(.vertical, 8).disabled(store.busy || !store.connected)
        }
    }
}

private struct RemoteChatComposer: View {
    let store: RemoteStore
    private var draft: Binding<String> {
        Binding(get: { store.selected.flatMap { store.drafts[$0] } ?? "" },
                set: { if let id = store.selected { store.drafts[id] = $0 } })
    }
    private var field: some View {
        TextField("Message", text: draft, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
    }
    private var action: some View {
        Button {
            let stopping = store.active
            Task { if stopping { await store.stop() } else { await store.send() } }
        } label: {
            Image(systemName: store.active ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .accessibilityLabel(store.active ? "Stop" : "Send")
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(!store.active && draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    field.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                    action.buttonStyle(.glassProminent)
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                field.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
                action.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct NewChatScreen: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var model = ""
    @State private var choosingFolder = false
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
                } header: { Text("Workspace on Host") }
                Picker("Model", selection: $model) {
                    ForEach(store.models, id: \.id) { model in Text(model["name"].string ?? model.id).tag(model.id) }
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
                        await store.mutate("POST", "/v1/conversations", .object(["workspace":.string(workspace), "model":.string(model)])) { value in
                            store.selected = value.id; dismiss()
                        }
                    } }.disabled(!workspace.hasPrefix("/") || model.isEmpty || store.busy)
                }
            }
            .onAppear {
                workspace = store.conversations.first?["workspace"].string ?? ""
                model = store.library["defaultModel"].string ?? store.models.first?.id ?? ""
            }
        }
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
    let initialPath: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var listing: RemoteJSON = .null
    @State private var requestedPath: String?
    @State private var showHidden = false
    @State private var loading = false
    @State private var failure: String?
    @State private var enteringPath = false
    @State private var enteredPath = ""
    init(store: RemoteStore, initialPath: String, choose: @escaping (String) -> Void) {
        self.store = store; self.initialPath = initialPath; self.choose = choose
        _requestedPath = State(initialValue: initialPath.isEmpty ? nil : initialPath)
    }
    private var currentPath: String? { listing["path"].string }
    var body: some View {
        NavigationStack {
            List {
                if let currentPath {
                    Section {
                        Text(currentPath).font(.callout).textSelection(.enabled)
                        if let parent = listing["parent"].string {
                            Button("Parent Folder", systemImage: "arrow.up") { requestedPath = parent }
                        }
                    } header: { Text("On the Agent Host") }
                }
                Section {
                    ForEach(listing["directories"].array, id: \.folderPath) { directory in
                        Button { requestedPath = directory["path"].string } label: {
                            HStack {
                                Label(directory["name"].string ?? "Folder", systemImage: "folder")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if listing["truncated"].bool {
                    Text("This folder is too large to list completely. Use Open Path to choose a missing folder.").font(.caption)
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
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Toggle("Show Hidden Folders", isOn: $showHidden)
                        Button("Open Path…", systemImage: "folder.badge.questionmark") {
                            enteredPath = currentPath ?? ""; enteringPath = true
                        }
                        Button("Home Folder", systemImage: "house") { requestedPath = nil }
                    } label: { Label("Folder Options", systemImage: "ellipsis.circle") }
                    .disabled(loading)
                }
            }
            .alert("Open Host Folder", isPresented: $enteringPath) {
                TextField("Absolute path", text: $enteredPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open") { requestedPath = enteredPath }
                Button("Cancel", role: .cancel) {}
            }
            .task(id: BrowseLocation(path: requestedPath, hidden: showHidden)) {
                loading = true; failure = nil
                defer { loading = false }
                do {
                    // Let an already-issued read finish when dismissing the sheet;
                    // cancelling a secure-channel receive would close the shared socket.
                    let path = requestedPath, hidden = showHidden
                    let request = Task { try await store.browseFolders(path, showHidden: hidden) }
                    let value = try await request.value
                    try Task.checkCancellation()
                    listing = value
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
        }
    }
    private struct BrowseLocation: Hashable { let path: String?; let hidden: Bool }
}
private extension RemoteJSON { var folderPath: String { self["path"].string ?? "" } }
