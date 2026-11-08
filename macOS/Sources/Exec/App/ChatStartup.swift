import Foundation
import Observation

/// Publish a local presentation before starting credential restoration. Tests can
/// hold the credential loader without touching Keychain or a live provider.
@MainActor @Observable final class ChatStartup {
    private(set) var store: ChatLibrary?
    private(set) var windows: SessionWindows?
    private(set) var error: String?
    private(set) var starting = false
    private(set) var isReadyForPresentation = false
    private var task: Task<Void, Never>?
    private var preparingLibrary: ChatLibrary?

    func start(makeSessions: () throws -> SessionStore, cache: AccountMetadataCache?,
               preferences: UserDefaults = .standard, localPresentation: AccountPresentation? = nil,
               restoreProvider: @escaping @MainActor () async throws -> any ChatProvider) {
        guard !starting, store == nil || store?.isPresentingStartup == true else { return }
        starting = true
        error = nil
        let sessions: SessionStore
        do { sessions = try makeSessions() }
        catch { self.error = error.localizedDescription; starting = false; isReadyForPresentation = true; return }
        task = Task {
            defer { starting = false; task = nil }
            do {
                if store == nil,
                   let preview = try await ChatLibrary.startupPresentation(sessions: sessions, cache: cache,
                        preferences: preferences, fallback: localPresentation) {
                    try Task.checkCancellation()
                    publish(preview)
                }
                // Let the cached presentation mount before Keychain can prompt.
                await Task.yield()
                try Task.checkCancellation()
                let provider = try await restoreProvider()
                try Task.checkCancellation()
                if let store, store.isPresentingStartup {
                    try await store.reconcileStartup(with: provider)
                } else {
                    let library = try ChatLibrary(provider: provider, sessions: sessions,
                                                  preferences: preferences, metadataCache: cache)
                    preparingLibrary = library
                    defer { preparingLibrary = nil }
                    library.restore()
                    // Without a local presentation, finish disk restoration before
                    // showing the window. Remote model discovery stays separate.
                    await library.current.waitUntilIdle()
                    try Task.checkCancellation()
                    publish(library)
                }
            } catch is CancellationError {
                // No automatic retries, and late credential results never enable work.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isReadyForPresentation = true
            }
        }
    }

    func cancel() {
        task?.cancel()
        preparingLibrary?.stopAll()
        store?.stopAll()
    }

    private func publish(_ library: ChatLibrary) {
        windows = SessionWindows(library: library)
        store = library
        isReadyForPresentation = true
    }
}
