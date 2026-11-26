import SwiftUI

private struct SidebarSessionGroup: Identifiable {
    let session: SessionSummary
    let children: [SessionSummary]
    var id: UUID { session.id }

    @MainActor static func snapshot(_ store: ChatLibrary) -> [Self] {
        // Build the ordered catalog once, not once again for every parent.
        let sessions = store.sessionList
        var children: [UUID: [SessionSummary]] = [:]
        for session in sessions {
            if let parent = session.parent?.sessionId { children[parent, default: []].append(session) }
        }
        return sessions.filter { $0.parent == nil && !store.detachedSessionIDs.contains($0.id) }
            .map { Self(session: $0, children: children[$0.id] ?? []) }
    }
}

struct SessionSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: ChatLibrary
    let open: (UUID) -> Void
    let delete: (SessionSummary) -> Void
    @State private var renamePrompt = SessionRenamePrompt()
    private var rowAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.25) }
    private var groups: [SidebarSessionGroup] { SidebarSessionGroup.snapshot(store) }

    // Native drags already animate their drop. Suppress a second animation for that order.
    @State private var nativeDropOrder: [UUID]? = nil

    private func activate(_ id: UUID) {
        guard store.canNavigate else { return }
        open(id)
    }

    private func beginRenaming(_ session: SessionSummary) {
        guard store.canRenameSession(session.id),
              let current = store.sessionList.first(where: { $0.id == session.id }) else { return }
        renamePrompt.present(title: current.title) { title in
            store.renameSession(session.id, title: title)
        }
    }

    var body: some View {
        let sessions = groups
        let rootIDs = sessions.map(\.id)
        let shortcutIDs = rootIDs.prefix(9)
        // The library paints grey selection; native table selection stays empty.
        List {
            ForEach(sessions) { group in
                let session = group.session
                VStack(alignment: .leading, spacing: 0) {
                    SessionRow(session: session, store: store,
                               rename: { beginRenaming(session) }, delete: { delete(session) })
                        .onTapGesture { activate(session.id) }
                        .accessibilityAction { activate(session.id) }
                        .accessibilityAddTraits(store.sidebarSelectionID == session.id ? [.isSelected] : [])
                    SidebarChildRows(children: group.children, animation: rowAnimation) { child in
                        SessionChildRowContent(child: child, store: store)
                            // Include the native row gutters in the background, then
                            // cancel that padding so the connector/text do not move.
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                            .background {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(store.sidebarSelectionID == child.id ? Color.primary.opacity(0.08) : Color.clear)
                            }
                            .padding(.horizontal, -16)
                            .onTapGesture { activate(child.id) }
                            .accessibilityAction { activate(child.id) }
                            .accessibilityAction(named: "Delete Sub-agent") {
                                if store.canDeleteSession(child.id) { delete(child) }
                            }
                            .accessibilityAddTraits(store.sidebarSelectionID == child.id ? [.isSelected] : [])
                            .overlay {
                                SessionContextMenu(items: [
                                    .action("Delete Sub-agent", enabled: store.canDeleteSession(child.id)) { delete(child) }
                                ])
                            }
                    }
                    SessionRowMetadata(session: session, shortcut: shortcutIDs.firstIndex(of: session.id).map { $0 + 1 })
                        .padding(.top, 3).padding(.bottom, 5)
                        .contentShape(Rectangle())
                        .onTapGesture { activate(session.id) }
                        .accessibilityAction { activate(session.id) }
                        .overlay {
                            ParentSessionContextMenu(session: session, store: store,
                                rename: { beginRenaming(session) }, delete: { delete(session) })
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(SidebarAnimatedHeight(animation: rowAnimation))
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(store.sidebarSelectionID == session.id
                              ? Color.primary.opacity(0.08) : Color.clear)
                )
                .moveDisabled(!store.canReorderSessions)
            }
            .onMove { offsets, destination in
                guard rootIDs == store.sidebarSessions.map(\.id) else { return }
                store.moveSidebarSessions(from: offsets, to: destination)
                let dropped = store.sidebarSessions.map(\.id)
                if dropped != rootIDs { nativeDropOrder = dropped }
            }
        }
        .listStyle(.sidebar)
        // Animate the catalog change where List consumes it. Republishing an
        // onChange mirror can leave native rows snapping in a real window scene.
        .animation(rootIDs == nativeDropOrder ? nil : rowAnimation, value: rootIDs)
        .padding(.horizontal, 10)
        .focusable(false)
        .onChange(of: rootIDs) { _, current in
            if let nativeDropOrder, nativeDropOrder != current { self.nativeDropOrder = nil }
        }
        .background(WindowReference { renamePrompt.window = $0 })
    }
}

/// Inside a retained native row, child transitions still need their own update.
private struct SidebarChildRows<Row: View>: View {
    let children: [SessionSummary]
    let animation: Animation?
    private let row: (SessionSummary) -> Row
    @State private var displayed: [SessionSummary]
    @State private var revealed: Set<UUID>

    init(children: [SessionSummary], animation: Animation?, @ViewBuilder row: @escaping (SessionSummary) -> Row) {
        self.children = children
        self.animation = animation
        self.row = row
        // Remounting a recycled family must not replay existing child fades.
        _displayed = State(initialValue: children)
        _revealed = State(initialValue: Set(children.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(displayed) { child in
                row(child)
                    .modifier(SidebarChildAppearance(visible: revealed.contains(child.id), animation: animation) {
                        revealed.insert(child.id)
                    })
                    .transition(.opacity)
            }
        }
        .onChange(of: children) { _, updated in
            guard displayed != updated else { return }
            let updatedIDs = updated.map(\.id)
            withAnimation(displayed.map(\.id) == updatedIDs ? nil : animation) {
                revealed.formIntersection(updatedIDs)
                displayed = updated
            }
        }
    }
}

/// Content padding stays inside the selection background and native menu overlay.
struct SessionChildRowContent: View {
    let child: SessionSummary
    let store: ChatLibrary

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SessionChildConnector()
                Text(verbatim: child.title).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Group {
                if store.needsApproval(child.id) {
                    SessionStatusIndicator(symbol: "hand.raised").foregroundStyle(.orange)
                        .accessibilityLabel("Approval required")
                } else if store.needsAttention(child.id) {
                    SessionStatusIndicator(symbol: "exclamationmark.circle").foregroundStyle(.orange)
                } else if store.isSessionWaiting(child.id) {
                    SessionStatusIndicator(symbol: "stopwatch").foregroundStyle(.green)
                        .accessibilityLabel("Waiting")
                } else if store.showsUnreadCompletion(child.id) {
                    UnreadCompletionIndicator()
                }
            }
            // Match the parent's trailing status slot without insetting the row.
            .frame(width: 16)
        }
        .font(.caption2).foregroundStyle(.secondary)
        // Status symbols must not change the child's layout height.
        .frame(height: 22, alignment: .center)
    }
}

private struct SessionChildConnector: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let capHeight = NSFont.preferredFont(forTextStyle: .caption2).capHeight
        let width = capHeight * 0.85
        Path { path in
            path.move(to: CGPoint(x: 0.5, y: 0.5))
            path.addLine(to: CGPoint(x: 0.5, y: capHeight / 2))
            path.addLine(to: CGPoint(x: width - 0.5, y: capHeight / 2))
        }
        .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        .frame(width: width, height: capHeight)
        .alignmentGuide(.firstTextBaseline) { _ in capHeight }
        // Adjust only the drawing by screen pixels, preserving the row's layout.
        .offset(x: 2 / displayScale, y: 1 / displayScale)
        .accessibilityHidden(true)
    }
}

private struct SessionRowMetadata: View {
    let session: SessionSummary
    let shortcut: Int?

    var body: some View {
        HStack {
            if let shortcut {
                Text("⌘\(shortcut)").monospacedDigit().fixedSize()
                    .help("Switch to session (⌘\(shortcut))")
                    .accessibilityLabel("Keyboard shortcut: Command \(shortcut)")
            }
            if let workspace = session.workspace {
                Text(URL(fileURLWithPath: workspace).lastPathComponent).lineLimit(1).help(workspace)
            }
            Spacer(minLength: 4)
            if !session.unreadable {
                Text(session.updatedAt, format: .dateTime.month(.abbreviated).day()).fixedSize()
                    .help(session.updatedAt.formatted(date: .long, time: .shortened))
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct SessionStatusIndicator: View {
    var symbol: String? = nil
    private let size: CGFloat = 14

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).resizable().scaledToFit()
            } else {
                // The native small spinner is 16 pt; a frame alone does not resize it.
                SidebarProgressSpinner().frame(width: 16, height: 16).scaleEffect(size / 16)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct UnreadCompletionIndicator: View {
    var body: some View {
        SessionStatusIndicator(symbol: "exclamationmark.circle")
            .foregroundStyle(AppColors.blue)
            .help("Unread completion")
            .accessibilityLabel("Unread completion")
    }
}

/// Give AppKit the resolved appearance explicitly: SwiftUI's sidebar spinner
/// otherwise retains its light-appearance gray when the surrounding row is dark.
private struct SidebarProgressSpinner: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ indicator: NSProgressIndicator, context: Context) {
        indicator.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    static func dismantleNSView(_ indicator: NSProgressIndicator, coordinator: ()) {
        indicator.stopAnimation(nil)
    }
}

/// Reuse parent actions on disjoint title/footer surfaces, never over child rows.
private struct ParentSessionContextMenu: View {
    let session: SessionSummary
    let store: ChatLibrary
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        SessionContextMenu(items: [
            .action("Rename…", enabled: store.canRenameSession(session.id), perform: rename),
            .separator,
            .action("Delete Session", enabled: store.canDeleteSession(session.id), perform: delete)
        ])
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let store: ChatLibrary
    private var needsApproval: Bool { store.needsApproval(session.id) }
    private var needsAttention: Bool { store.needsAttention(session.id) }
    let rename: () -> Void
    let delete: () -> Void

    @ViewBuilder private var status: some View {
        if needsApproval {
            SessionStatusIndicator(symbol: "hand.raised").foregroundStyle(.orange)
                .help("Approval required").accessibilityLabel("Approval required")
        } else if needsAttention {
            SessionStatusIndicator(symbol: "exclamationmark.circle").foregroundStyle(.orange)
                .help("Conversation needs attention").accessibilityLabel("Conversation needs attention")
        } else if store.isSessionWaiting(session.id) {
            SessionStatusIndicator(symbol: "stopwatch").foregroundStyle(.green)
                .accessibilityLabel("Waiting")
        } else if store.isSessionResponding(session.id) {
            SessionStatusIndicator().accessibilityLabel("Running")
        } else if !session.unreadable && store.showsUnreadCompletion(session.id) {
            UnreadCompletionIndicator()
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: session.title).font(.body.weight(.regular)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Reserve horizontal space only. Indicators may overflow vertically,
            // but must never increase a single-line title's layout height.
            Color.clear.frame(width: 16, height: 0)
                .overlay { status }
        }
        .padding(.top, 5)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .overlay {
            ParentSessionContextMenu(session: session, store: store, rename: rename, delete: delete)
        }
        .accessibilityAction(named: "Rename Conversation") { if store.canRenameSession(session.id) { rename() } }
        .accessibilityAction(named: "Delete Session") { if store.canDeleteSession(session.id) { delete() } }
    }
}
