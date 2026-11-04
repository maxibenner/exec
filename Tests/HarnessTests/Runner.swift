import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) throws {
    guard try condition() else { throw CheckFailure(description: "\(file):\(line): expectation failed") }
}

func expectFailure(_ operation: () throws -> Void) throws {
    do { try operation() }
    catch is HarnessError { return }
    throw CheckFailure(description: "Expected HarnessError")
}

// Runs with Apple's Command Line Tools alone; no Xcode or test dependencies.
@main struct TestRunner {
    @MainActor static func main() async throws {
        let streaming = StreamingTests()
        let chat = ChatStoreTests()
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Codex OAuth fields", { try CodexConnectionTests().authorizationUsesCodexFlow() }),
            ("OAuth callback validation", { try CodexConnectionTests().callbackRequiresExactStateAndPath() }),
            ("Codex catalog compatibility version", { try CodexConnectionTests().catalogUsesCompatibilityVersionNotAppVersion() }),
            ("Codex request routing", { try CodexConnectionTests().requestsUseCodexEndpointAndAccountRouting() }),
            ("Codex account metadata", { try CodexConnectionTests().readsAccountRoutingMetadata() }),
            ("Codex terminal events", { try CodexConnectionTests().handlesDoneWithoutAcceptingFailure() }),
            ("SSE framing and Unicode", { try streaming.framesCommentsMultilineAndUnicode() }),
            ("Partial SSE frame", { try streaming.partialFrameDoesNotEmit() }),
            ("SSE size limit", { try streaming.oversizedEventIsRejected() }),
            ("Semantic events and opaque output", { try streaming.semanticEvents() }),
            ("Failure events", { try streaming.errorsAndIncompleteAreNotSuccess() }),
            ("OAuth form encoding", { try streaming.formEncodingEscapesReservedCharacters() }),
            ("OIDC signature and claims", { try IdentityTests().verifiesSignatureAndRejectsInvalidClaims() }),
            ("Follow-up and new conversation", { try await chat.successfulFollowupIncludesHistoryAndNewClearsIt() }),
            ("Failed turn isolation", { try await chat.failedTurnsStayVisibleButAreExcludedFromContext() }),
            ("Cancellation", { try await chat.stopCancelsAndDoesNotCommitPartialTurn() })
        ]
        for (name, check) in checks {
            try await check()
            print("PASS \(name)")
        }
        print("\(checks.count) checks passed.")
    }
}
