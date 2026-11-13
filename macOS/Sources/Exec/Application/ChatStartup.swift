import Foundation
import Observation

@MainActor @Observable final class ChatStartup {
    private(set) var store: ChatLibrary?
    private(set) var windows: SessionWindows?
    private(set) var error: String?
    private(set) var starting = false
    private(set) var isReadyForPresentation = false
    let service = AgentService()
    private var task: Task<Void, Never>?
    func start() {
        guard !starting, store == nil else { return }
        starting = true
        error = nil
        task = Task {
            defer { starting = false; task = nil }
            do {
                let api = try await service.start()
                let library = ChatLibrary(provider: AgentAccounts(api: api))
                try await library.restore()
                try Task.checkCancellation()
                store = library
                library.startSynchronization()
                windows = SessionWindows(library: library)
                isReadyForPresentation = true
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isReadyForPresentation = true
            }
        }
    }
    func shutdown() async {
        task?.cancel()
        await task?.value
        store?.closePresentations()
        await service.shutdown()
    }
}
