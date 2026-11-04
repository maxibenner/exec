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
    @MainActor static func main() async {
        let streaming = StreamingTests()
        let chat = ChatStoreTests()
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Read-only tool boundaries", { try ToolTests().readToolsStayWithinWorkspace() }),
            ("Shell output, timeout and cancellation", { try await ToolTests().shellOutputTimeoutAndCancellation() }),
            ("Shell approval", { try await ToolTests().everyShellCommandRequiresApproval() }),
            ("Tool interruption and recovery", { try await chat.interruptedToolTurnRetainsResultsWithoutReexecution() }),
            ("Workspace instruction loading", { try WorkspaceTests().loadsOnlyRootInstructionsAndRejectsUnsafeFiles() }),
            ("Workspace context isolation", { try await chat.workspaceChangesKeepInstructionsAndHistoryIsolated() }),
            ("Refresh and restart", { try await LifecycleTests().refreshIsSharedAndSurvivesRestart() }),
            ("Interrupted refresh recovery", { try await LifecycleTests().interruptedRefreshIsNotReplayedAfterRestart() }),
            ("Rotated token persistence", { try await LifecycleTests().rotatedTokensSurviveTemporaryKeychainFailure() }),
            ("Offline sign-out", { try await LifecycleTests().signOutClearsLocalSessionWhenOffline() }),
            ("Provider tool round trip", { try await LifecycleTests().providerEncodesToolsAndPreservesToolRoundTrips() }),
            ("Provider follow-up context", { try await LifecycleTests().providerPreservesOpaqueFollowupContext() }),
            ("Network stream cancellation and EOF", { try await LifecycleTests().streamCancellationClosesRequestAndPrematureEOFIsFailure() }),
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
            do { try await check() }
            catch {
                FileHandle.standardError.write(Data("FAIL \(name): \(error)\n".utf8))
                exit(1)
            }
            FileHandle.standardOutput.write(Data("PASS \(name)\n".utf8))
        }
        print("\(checks.count) checks passed.")
    }
}
