import Foundation
import Observation
import ExecRemote

/// Store-owned, not view-owned: resident hidden sessions observe every response
/// gap too. Reopening a transcript must not restart an already elapsed delay.
@MainActor @Observable final class ThinkingIndicatorLifecycle {
    private(set) var visible: Set<String> = []
    @ObservationIgnored private var gaps: [String: Gap] = [:]
    private struct Gap {
        let operationID: String
        let token: UUID
        let task: Task<Void, Never>
    }
    private let sleep: @Sendable (Double) async throws -> Void

    init(sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    static func operation(in snapshot: RemoteJSON) -> String? {
        guard snapshot["operation"]["state"].string == "running",
              snapshot["approval"] == .null, snapshot["activeToolCallID"] == .null,
              snapshot["activeToolName"] == .null,
              !snapshot["messages"].array.contains(where: {
                  ($0["role"].string == "assistant" && $0["status"].string == "streaming" && !($0["text"].string ?? "").isEmpty)
                  || ($0["role"].string == "tool" && $0["outcome"].string == "running")
              }) else { return nil }
        return snapshot["operation"]["id"].string
    }

    func update(_ snapshot: RemoteJSON, suppressed: Bool = false) {
        guard let id = snapshot["id"].string else { return }
        let operation = suppressed ? nil : Self.operation(in: snapshot)
        guard gaps[id]?.operationID != operation else { return }
        remove(id)
        guard let operation else { return }
        let token = UUID()
        let task = Task { @MainActor [weak self, sleep] in
            do { try await sleep(0.5) } catch { return }
            guard !Task.isCancelled, let self, self.gaps[id]?.token == token else { return }
            self.visible.insert(id)
        }
        gaps[id] = Gap(operationID: operation, token: token, task: task)
    }

    func remove(_ id: String) {
        gaps.removeValue(forKey: id)?.task.cancel()
        visible.remove(id)
    }

    func retain(_ isResident: (String) -> Bool) {
        for id in Array(gaps.keys) where !isResident(id) { remove(id) }
    }

    func reset() { retain { _ in false } }
    deinit { for gap in gaps.values { gap.task.cancel() } }
}
