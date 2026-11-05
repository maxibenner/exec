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
            ("Web search request, context isolation and persistence", { try await WebSearchTests().roundTripKeepsSearchSeparateAndSavesSources() }),
            ("Web search failure and no-retry behavior", { try await WebSearchTests().failuresStopWithoutRetriesOrFalseSuccess() }),
            ("Web search cancellation and restart safety", { try await WebSearchTests().cancellationAndRestartDoNotResumeSearch() }),
            ("Web search bounds and source safety", { try WebSearchTests().parsingBoundsAndSourceSafety() }),
            ("Web search validation and checkpoint safety", { try await WebSearchTests().invalidInputAndCheckpointFailureMakeNoRequests() }),
            ("Effort catalog and request encoding", { try await EffortTests().catalogAndRequestEncoding() }),
            ("Effort persistence and conversation isolation", { try await EffortTests().selectionPersistenceAndIsolation() }),
            ("Image drop normalization and validation", { try await ImageAttachmentTests().normalizesAndRejectsInvalidDrops() }),
            ("Image wire format and legacy sessions", { try ImageAttachmentTests().wireFormatAndLegacyDecoding() }),
            ("Image persistence and failed-turn isolation", { try await ImageAttachmentTests().sendsPersistsAndExcludesFailedImages() }),
            ("Pending image drop conversation isolation", { try await ImageAttachmentTests().pendingDropsStayWithOriginalConversation() }),
            ("Read file headers show actual line ranges", { try ReadFileSummaryTests().showsActualReturnedLines() }),
            ("Composer cursor excludes controls", { try ComposerCursorTests().excludesControlsWithoutLeavingGaps() }),
            ("Batched snapshots flush on failure and cancellation", { try await chat.batchedSnapshotsFlushOnFailureAndCancellation() }),
            ("Linked text wrapping, resizing and updates", { try LinkedTextTests().measuresWrappingAcrossWidthsAndUpdates() }),
            ("Markdown blocks and streaming code", { try MarkdownTests().preservesBlocksAndStreamingCode() }),
            ("Markdown link and image safety", { try MarkdownTests().stripsActiveContentAndUnsafeLinks() }),
            ("Approved edits and stale-file protection", { try await FileEditTests().approvedEditsRejectStaleFilesAndPreserveMode() }),
            ("Edit creation and diff boundaries", { try FileEditTests().creationAndDiffBoundaries() }),
            ("Concurrent edit protection", { try await FileEditTests().concurrentPreparedEditsCannotOverwriteEachOther() }),
            ("Diff column alignment and literal content", { try DiffTests().pairsReplacementsWithoutLosingMarkersOrPlusSigns() }),
            ("Session restore and follow-up", { try await SessionTests().conversationAndWorkspaceSurviveRestart() }),
            ("Interrupted session recovery", { try await SessionTests().interruptedActionsAreRecordedNotReplayed() }),
            ("Session corruption and account isolation", { try await SessionTests().incompatibleOrCorruptSessionsAreNotOverwritten() }),
            ("Session switching, deletion and migration", { try await SessionTests().sessionsSwitchDeleteAndMigrateWithoutLosingHistory() }),
            ("Session index recovery", { try await SessionTests().indexRecoveryDoesNotReplayOrResurrectDeletedSessions() }),
            ("Checkpoint failure safety", { try await SessionTests().failedCheckpointPreventsModelAndToolExecution() }),
            ("Concurrent conversations and foreground selection", { try await ChatLibraryTests().concurrentTurnsKeepContextDraftsAndSelectionIsolated() }),
            ("Workspace selection during active conversations", { try await ChatLibraryTests().workspaceSelectionDoesNotInterruptRunningConversations() }),
            ("Background approval isolation", { try await ChatLibraryTests().backgroundApprovalsStayWithTheirConversation() }),
            ("Read-only tool boundaries", { try ToolTests().readToolsStayWithinWorkspace() }),
            ("Shell output, timeout and cancellation", { try await ToolTests().shellOutputTimeoutAndCancellation() }),
            ("Shell approval", { try await ToolTests().everyShellCommandRequiresApproval() }),
            ("Scoped and revocable auto-approval", { try await ToolTests().autoApprovalIsScopedAndRevocable() }),
            ("Long tool turns and duplicate protection", { try await chat.longToolTurnsFinishWithoutArtificialCaps() }),
            ("Tool interruption and recovery", { try await chat.interruptedToolTurnRetainsResultsWithoutReexecution() }),
            ("Workspace instruction loading", { try WorkspaceTests().loadsOnlyRootInstructionsAndRejectsUnsafeFiles() }),
            ("Workspace context isolation", { try await chat.workspaceChangesKeepInstructionsAndHistoryIsolated() }),
            ("Context usage reports and estimates", { try CompactionTests().contextUsageReportsRestoredMeasurementsAndEstimates() }),
            ("Compaction threshold and durable continuation", { try await CompactionTests().thresholdAndDurableOpaqueContinuation() }),
            ("Compaction failure and cancellation safety", { try await CompactionTests().failedAndCancelledCompactionKeepsOriginalContext() }),
            ("Compaction estimates and tool boundaries", { try await CompactionTests().estimatesLegacyStateAndClosedToolBoundaries() }),
            ("Compaction checkpoint safety", { try await CompactionTests().checkpointFailurePreventsInferenceAfterCompaction() }),
            ("Refresh and restart", { try await LifecycleTests().refreshIsSharedAndSurvivesRestart() }),
            ("Shared refresh cancellation isolation", { try await LifecycleTests().cancellingOneCallerDoesNotCancelSharedRefresh() }),
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
            ("Completed output item reconciliation", { try streaming.completedItemsMergeWithoutDuplicatingOrLosingContext() }),
            ("Final text and empty response handling", { try await chat.finalTextReplacesDeltasAndEmptyResponsesFail() }),
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
