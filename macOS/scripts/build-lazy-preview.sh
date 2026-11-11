#!/bin/bash
# Build an isolated, synthetic-data preview without changing production sources.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
preview="$(mktemp -d "$PWD/.build/lazy-preview.XXXXXX")"
trap 'rm -rf "$preview"' EXIT
for item in Sources Resources Design scripts Package.swift Package.resolved; do
    ditto "$item" "$preview/$item"
done
python3 - "$preview" <<'PY'
from pathlib import Path
import json, plistlib, sys, uuid
root = Path(sys.argv[1])
def replace(path, old, new):
    file = root / path
    text = file.read_text()
    assert text.count(old) == 1, (path, old)
    file.write_text(text.replace(old, new))

path = 'Sources/Exec/App/TranscriptView.swift'
replace(path, '''        VirtualTranscript(messages: messages, state: state, jumpRequest: state.jumpRequest, bottomInset: bottomInset)
            .ignoresSafeArea(.container, edges: .top)
            .focusedSceneValue(\\.transcriptNavigation, messages.contains { $0.role == .user } ? state : nil)''', '''        if #available(macOS 15.0, *) {
            PreviewLazyTranscript(messages: messages, state: state, bottomInset: bottomInset)
        } else {
            VirtualTranscript(messages: messages, state: state, jumpRequest: state.jumpRequest, bottomInset: bottomInset)
        }''')
with (root / path).open('a') as file:
    file.write(r'''
// Experimental container only. The standard app sources are not changed.
@available(macOS 15.0, *)
private struct PreviewLazyTranscript: View {
    let messages: [Message]
    let state: TranscriptState
    let bottomInset: CGFloat
    private var visibleMessages: [Message] {
        messages.filter {
            $0.compaction != nil || $0.role != .assistant || !$0.text.isEmpty || $0.status == .failed
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(visibleMessages) { message in
                            MessageView(message: message, state: state).equatable()
                                .frame(width: max(1, min(820, geometry.size.width - 40)), alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, message.id == visibleMessages.last?.id ? bottomInset + 32 : 0)
                                .id(message.id)
                        }
                    }
                    .padding(.top, 20).frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                } action: { _, nearBottom in
                    state.followsLatest = nearBottom
                }
                .onAppear {
                    if let last = visibleMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: messages) { old, new in
                    let sent = new.last?.id != old.last?.id && new.last?.role == .user
                    if state.followsLatest || sent, let last = visibleMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: geometry.size.width) { _, _ in
                    if state.followsLatest, let last = visibleMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: bottomInset) { _, _ in
                    if state.followsLatest, let last = visibleMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: state.jumpRequest) { _, _ in
                    if let last = visibleMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}
''')

# Isolate sessions (including legacy migration), account cache, preferences and
# credentials. Never import the user's production accounts or conversation files.
file = root / 'Sources/Exec/Storage/SessionStore.swift'
text = file.read_text()
old = 'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first'
assert text.count(old) == 2
text = text.replace(old, old + '?.appendingPathComponent("Exec Lazy Preview", isDirectory: true)')
old = '        return try applicationStore(in: base)'
assert text.count(old) == 1
text = text.replace(old, '''        let destination = base.appendingPathComponent("Exec", isDirectory: true)
        if !FileManager.default.fileExists(atPath: destination.path),
           let fixtures = Bundle.main.resourceURL?.appendingPathComponent("PreviewSessions") {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures, to: destination)
        }
        return try applicationStore(in: base)''')
# Fixtures are installed during startup, after initial sidebar visibility is chosen.
text = text.replace('return ["Exec", "Harness"].contains { hasSavedSessions(in: base.appendingPathComponent($0)) }',
                    'return Bundle.main.resourceURL?.appendingPathComponent("PreviewSessions") != nil || ["Exec", "Harness"].contains { hasSavedSessions(in: base.appendingPathComponent($0)) }')
file.write_text(text)
replace('Sources/Exec/Storage/KeychainStore.swift', 'private let service = "local.swift-harness"',
        'private let service = "local.swift-harness.lazy-preview"')
replace('Sources/Exec/Storage/AccountMetadataCache.swift', '"Exec/AccountMetadata"', '"Exec Lazy Preview/AccountMetadata"')
replace('Sources/Exec/App/SparkleUpdater.swift', '        controller.startUpdater()', '        // Updates are disabled in the isolated preview.')
replace('Sources/Exec/App/SparkleUpdater.swift',
        '        guard notice.beginSilentCheck(canCheck: canCheckForUpdates && !controller.updater.sessionInProgress) else { return }\n        controller.updater.checkForUpdateInformation()',
        '        // Never query the production update feed from this preview.')

replace('Sources/Exec/App/ExecApp.swift', '@main struct ExecApp: App {', '''@main struct ExecApp: App {
    init() {
        UserDefaults.standard.set("exec.local:lazy-preview", forKey: "providerLibraryIdentity")
    }
''')
info = root / 'Resources/Info.plist'
plist = plistlib.loads(info.read_bytes())
plist['CFBundleIdentifier'] = 'local.swift-harness.lazy-preview'
plist['CFBundleName'] = 'Exec Lazy Preview'
plist['CFBundleDisplayName'] = 'Exec Lazy Preview'
info.write_bytes(plistlib.dumps(plist))

fixtures = root / 'Resources/PreviewSessions'
fixtures.mkdir()
for count in (400, 2000):
    messages = []
    for index in range(count):
        user = index % 2 == 0
        paragraph = 'A native transcript should preserve **conversation integrity** while content changes. Keep cancellation explicit, maintain a stable reading position, and avoid unnecessary layout work.'
        text = f'Question {index}: Explain the layout and cancellation behavior for this example.' if user else (
            f'## Response {index}\n\n' + '\n\n'.join([paragraph] * (2 + index % 5))
            + '\n\n```swift\nfunc example() async throws {\n    try Task.checkCancellation()\n    let values = (0..<20).map { $0 * 2 }\n    print(values)\n}\n```\n\n- Preserve the current anchor\n- Reuse existing content\n- Measure before optimizing')
        messages.append(dict(id=str(uuid.uuid4()), role='user' if user else 'assistant', text=text,
                             status='complete', toolCalls=[], images=[]))
    snapshot = dict(version=1, identity='exec.local:lazy-preview', selectedModel='', messages=messages, history=[], activeTurn=False,
                    title=f'Lazy preview — {count:,} synthetic messages', isTitleManuallySet=True)
    (fixtures / (str(uuid.uuid4()) + '.json')).write_text(json.dumps(snapshot))
replace('scripts/build-app.sh',
        'cp Resources/Info.plist "$built/Contents/Info.plist"',
        'cp Resources/Info.plist "$built/Contents/Info.plist"\nditto Resources/PreviewSessions "$built/Contents/Resources/PreviewSessions"')
PY
(cd "$preview" && ./scripts/build-app.sh)
destination="${1:-$HOME/Desktop/Exec Lazy Preview.app}"
if [[ -e "$destination" ]]; then
    printf 'Refusing to overwrite existing destination: %s\n' "$destination" >&2
    exit 1
fi
ditto "$preview/dist/Exec.app" "$destination"
codesign --verify --deep --strict "$destination"
printf '\nPreview copied to: %s\n' "$destination"
