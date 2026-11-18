import SwiftUI
import UIKit
import ExecRemote

@main struct ExecRemoteApp: App {
    @State private var store: RemoteStore = {
        #if DEBUG && targetEnvironment(simulator)
        if RemoteUIFixture.enabled { return RemoteUIFixture.makeStore() }
        #endif
        return RemoteStore()
    }()
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
    @State private var scanning = false
    @State private var settings = false
    @State private var creating = false
    var body: some View {
        NavigationStack {
            Group {
                if store.host == nil { pairing }
                else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        List {
                            ForEach(RemoteSessionListDay.group(store.conversations)) { group in
                                Section {
                                    ForEach(group.rows) { row in
                                        sessionRow(row)
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
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .refreshable { do { try await store.refresh() } catch { store.error = error.localizedDescription } }
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
                    SessionControls(busy: store.busy, connected: store.connected,
                                    settings: { settings = true },
                                    reconnect: { Task { await store.connect() } },
                                    forget: { Task { await store.forget() } },
                                    create: { creating = true })
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
            .background(Color(uiColor: store.host == nil ? .systemBackground : .systemGroupedBackground))
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
        }
    }
    private func sessionRow(_ row: RemoteSessionListDay.Row) -> some View {
        let conversation = row.conversation
        return Button { store.selected = conversation.id } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(conversation["metadata"]["title"].string ?? conversation["title"].string ?? "New Chat")
                        .font(row.isSubagent ? .subheadline : .headline)
                        .foregroundStyle(Color(uiColor: row.isSubagent ? .secondaryLabel : .label))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !row.isSubagent {
                        HStack(spacing: 8) {
                            Text(RemoteSessionDay.activityDate(conversation), format: .dateTime.hour().minute())
                                .fixedSize()
                            if let workspace = conversation["workspace"].string, !workspace.isEmpty {
                                Text(URL(fileURLWithPath: workspace).lastPathComponent)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !row.isSubagent {
                    // Always reserve the status slot, including for idle sessions.
                    Group {
                        if RemoteMessageSubmission.isActive(conversation) {
                            ProgressView().controlSize(.regular).accessibilityLabel("Active")
                                .accessibilityIdentifier("session-active-\(conversation.id)")
                        } else {
                            Color.clear.accessibilityHidden(true)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, row.isSubagent ? 2 : 6)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("session-\(conversation.id)")
        .disabled(conversation["unreadable"].bool)
        // Keep native grouped resting corners and native swipe actions; a custom
        // background or clip would replace the system's swipe-corner animation.
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await store.deleteConversation(conversation.id) }
            }
            .disabled(store.busy || !store.connected || RemoteMessageSubmission.isActive(conversation))
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.busy)
            .padding()
        }
    }
}

private struct SessionControls: View {
    let busy: Bool
    let connected: Bool
    let settings: () -> Void
    let reconnect: () -> Void
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
        .font(.body.weight(.semibold))
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    @ViewBuilder private var controls: some View {
        Menu {
            Button("Settings", systemImage: "gearshape", action: settings)
            Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
            Button("Forget Host", systemImage: "trash", role: .destructive, action: forget)
        } label: {
            Label("Session Options", systemImage: "ellipsis")
                .frame(width: 24, height: 24)
        }
        .disabled(busy)
        Spacer()
        Button(action: create) {
            Label("New Session", systemImage: "plus")
                .frame(width: 24, height: 24)
        }
        .disabled(busy || !connected)
    }
}

struct ConversationScreen: View {
    @Bindable var store: RemoteStore
    @State private var composerHeight: CGFloat = 68
    var body: some View {
        NativeTranscript(conversationID: store.selected, snapshot: store.displaySnapshot,
                         bottomPadding: composerHeight, hasEarlier: store.hasEarlierMessages,
                         loadEarlier: { Task { await store.loadEarlier() } })
        .ignoresSafeArea(.container, edges: [.top, .bottom])
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
    @State private var tools = RemoteSessionCreation.ToolSelection(library: .null)
    @State private var initialized = false
    @State private var choosingFolder = false
    private var selectedModel: RemoteJSON { store.models.first { $0.id == model } ?? .null }
    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
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
                    .accessibilityIdentifier("new-session-workspace")
                }
                Section("Tools") {
                    ForEach(RemoteSessionCreation.tools) { tool in
                        Toggle(isOn: Binding(get: { tools.isEnabled(tool.id) },
                                             set: { tools.setEnabled(tool.id, $0) })) {
                            Label(tool.label, systemImage: tool.icon)
                        }
                        .accessibilityIdentifier("new-session-tool-\(tool.id)")
                    }
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
            }
            .sheet(isPresented: $choosingFolder) {
                HostFolderPicker(store: store, initialPath: workspace) { workspace = $0 }
            }
            .navigationTitle("New Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task {
                        let body = RemoteSessionCreation.body(workspace: workspace, model: selectedModel,
                                                              effort: effort, settings: store.library["settings"], tools: tools)
                        await store.mutate("POST", "/v1/conversations", body) { value in
                            store.selected = value.id; dismiss()
                        }
                    } }.disabled(!workspace.hasPrefix("/") || model.isEmpty || store.busy || !store.connected)
                }
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                workspace = store.conversations.first?["workspace"].string ?? ""
                model = store.library["defaultModel"].string ?? store.models.first?.id ?? ""
                tools = RemoteSessionCreation.ToolSelection(library: store.library)
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
            List {
                Section {
                    if let parent = listing["parent"].string {
                        Button("back up", systemImage: "arrow.turn.left.up") { requestedPath = parent }
                    }
                    ForEach(listing["directories"].array, id: \.folderPath) { directory in
                        Button { requestedPath = directory["path"].string } label: {
                            Label(directory["name"].string ?? "Folder", systemImage: "folder")
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
            .tint(.blue)
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // A pending or failed read does not invalidate the displayed folder.
                    Button("Choose") { if let currentPath { choose(currentPath); dismiss() } }
                        .disabled(currentPath == nil)
                }
            }
            .task(id: requestedPath) {
                readGeneration += 1
                let generation = readGeneration
                failure = nil
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
