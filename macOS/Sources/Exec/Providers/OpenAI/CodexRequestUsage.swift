import Foundation
import CoreFoundation

/// Diagnostic metadata only: never prompts, credentials, or account identifiers.
struct CodexResponseUsage: Codable, Sendable, Equatable {
    var model: String?
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?

    var contextTokens: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + outputTokens
    }

    init(response: [String: Any]) {
        model = (response["model"] as? String).map { String($0.prefix(128)) }
        let usage = response["usage"] as? [String: Any] ?? [:]
        func count(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue,
                  (0...500_000_000).contains(number.doubleValue) else { return nil }
            return number.intValue
        }
        inputTokens = count(usage["input_tokens"])
        outputTokens = count(usage["output_tokens"])
        cachedInputTokens = count((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"])
        reasoningTokens = count((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"])
        if let cachedInputTokens, let inputTokens, cachedInputTokens > inputTokens { self.cachedInputTokens = nil }
        if let reasoningTokens, let outputTokens, reasoningTokens > outputTokens { self.reasoningTokens = nil }
    }
}

struct CodexRequestUsage: Codable, Sendable {
    enum Kind: String, Codable { case main, search, compaction }
    enum Outcome: String, Codable { case unconfirmed, completed, failed, interrupted }
    let id: UUID
    let kind: Kind
    let requestedModel: String
    let requestedEffort: String?
    let inputID: UUID?
    let startedAt: Date
    let finishedAt: Date?
    let outcome: Outcome
    // Missing counts mean unavailable, never zero. Reasoning is part of output;
    // cached input is part of input, not an additional token charge.
    let usage: CodexResponseUsage?
}
