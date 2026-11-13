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
                    }
                    .refreshable { do { try await store.refresh() } catch { store.error = error.localizedDescription } }
                    .overlay { if store.conversations.isEmpty { ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right") } }
                }
            }
            .navigationTitle("Exec")
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
                HStack(alignment: .bottom) {
                    TextField("Message", text: Binding(get: { store.selected.flatMap { store.drafts[$0] } ?? "" }, set: { if let id = store.selected { store.drafts[id] = $0 } }), axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder)
                    if store.active {
                        Button("Stop", systemImage: "stop.fill") { Task { await store.stop() } }.labelStyle(.iconOnly)
                    } else {
                        Button("Send", systemImage: "arrow.up.circle.fill") { Task { await store.send() } }.labelStyle(.iconOnly).font(.title2)
                            .disabled((store.selected.flatMap { store.drafts[$0] } ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.padding().background(.regularMaterial).disabled(store.busy || !store.connected)
        }
    }
}

struct NewChatScreen: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var model = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Workspace on host", text: $workspace).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Model", selection: $model) {
                    ForEach(store.models, id: \.id) { model in Text(model["name"].string ?? model.id).tag(model.id) }
                }
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
