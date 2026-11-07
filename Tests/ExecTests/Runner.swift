import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) throws {
    guard try condition() else { throw CheckFailure(description: "\(file):\(line): expectation failed") }
}

func expectFailure(_ operation: () throws -> Void) throws {
    do { try operation() }
    catch is ExecError { return }
    throw CheckFailure(description: "Expected ExecError")
}

// Runs with Apple's Command Line Tools alone; no Xcode or test dependencies.
@main struct TestRunner {
    @MainActor static func main() async {
        let streaming = StreamingTests()
        let chat = ChatStoreTests()
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Workspace picker waits for the owning conversation window", { try await WorkspacePickerTests().presentsPickerInOwningWindow() }),
            ("First send requires a workspace and preserves cancelled drafts", { try await WorkspacePickerTests().sendRequiresWorkspaceAndPreservesDraft() }),
            ("System prompts autosave and remain isolated per conversation", { try await SystemPromptTests().persistsAndSnapshots() }),
            ("Generated titles persist with isolated context and preferences", { try await SessionTitleTests().updatesPersistWithoutChangingChatContext() }),
            ("Title generation rejects incomplete and cancelled responses", { try await SessionTitleTests().rejectsFailedAndCancelledGeneration() }),
            ("Image file migration, deduplication and integrity", { try await ImageStorageTests().migrationAndIntegrity() }),
            ("Image generation subscription request, persistence and presentation", { try await ImageGenerationTests().roundTrip() }),
            ("Image generation validation, bounds and no retries", { try await ImageGenerationTests().failuresAndValidation() }),
            ("Image generation cancellation and recovery", { try await ImageGenerationTests().cancellationAndRecovery() }),
            ("Screenshot sizing and minimal presentation", { try ScreenshotTests().fitsCaptureAndKeepsPresentationMinimal() }),
            ("Screenshot auto mode, one-time and session permission", { try await ScreenshotTests().permissions() }),
            ("Screenshot persistence, model input and tool presentation", { try await ScreenshotTests().capturesPersistAndEncode() }),
            ("Screenshot validation, denial, failure and cancellation", { try await ScreenshotTests().failuresAndCancellationStop() }),
            ("Detached sessions preserve running context and window-local controls", { try await DetachedSessionTests().movingRunningConversationsPreservesOwnershipAndControls() }),
            ("Detaching all workspace sessions shows the empty placeholder", { try await DetachedSessionTests().detachingAllWorkspaceSessionsShowsPlaceholder() }),
            ("Cold detach and native window close preserve drafts and presentation", { try await DetachedSessionTests().coldDetachAndNativeClosePreserveState() }),
            ("Sidebar reordering preserves detached conversations and saved order", { try await DetachedSessionTests().sidebarReorderingPreservesDetachedConversations() }),
            ("Pending approvals survive detach and reattach without execution", { try await DetachedSessionTests().pendingApprovalsMoveWithoutExecutionOrReplay() }),
            ("Session deletion selects adjacent rows and preserves drafts", { try await SessionDeletionTests().selectsAdjacentRowsInSidebarOrder() }),
            ("Session deletion and neighbor-load failures remain recoverable", { try await SessionDeletionTests().deletionAndNeighborLoadFailuresStayRecoverable() }),
            ("Detached deletion preserves the main conversation and recovers from failure", { try await SessionDeletionTests().detachedDeletionPreservesMainConversationAndRecoversFromFailure() }),
            ("Persistent session ordering, migration and write failures", { try await SessionOrderingTests().migratesAndPersistsOrderWithoutChangingSelectionOrOtherAccounts() }),
            ("Session moves preserve running work, drafts and shortcuts", { try await SessionOrderingTests().movesStayStableDuringActivityAndKeepDraftsAndShortcuts() }),
            ("Tool summaries describe inputs and preserve results", { try ToolPresentationTests().describesInputsAndPreservesResults() }),
            ("Tool presentation preserves failures and unknown arguments", { try ToolPresentationTests().handlesFailuresAndUnknownArgumentsHonestly() }),
            ("Single-line tool headers and selectable expanded inputs", { try ToolPresentationTests().keepsHeadersOnOneLineAndBodiesSelectable() }),
            ("Transcript click-away selection clearing", { try TranscriptSelectionTests().clearsOtherSelectionsWithoutStealingClicks() }),
            ("Bounded HTTP diagnostics and credential redaction", { try await streaming.httpErrorDiagnostics() }),
            ("Resident eviction protects work and drafts", { try await ChatLibraryTests().residentLimitProtectsRunningWorkAndDrafts() }),
            ("Composer aligns with overlay and legacy transcript scrollbars", { try await TranscriptTests().composerInsetMatchesTranscriptViewport() }),
            ("Near-bottom scrolling does not snap to the edge", { try TranscriptTests().preservesNearBottomScrolling() }),
            ("Virtual transcript geometry and scroll anchors", { try TranscriptTests().geometryPreservesAnchors() }),
            ("Virtual transcript mounts only viewport rows", { try await TranscriptTests().mountsBoundedRowsAndRestoresPosition() }),
            ("Manual compaction and cancellation", { try await CompactionTests().manualCompactionBypassesThresholdAndPreservesTranscript() }),
            ("Fetch URL and public-address validation", { try FetchContentTests().validatesURLsAndPublicAddresses() }),
            ("Fetch page text and redirect checks", { try await FetchContentTests().fetchesTextAndRechecksRedirects() }),
            ("Fetch HTTPS redirect upgrades without HTTP fallback", { try await FetchContentTests().upgradesHTTPRedirectsWithoutDowngrading() }),
            ("Fetch unsafe redirects and response bounds", { try await FetchContentTests().rejectsUnsafeRedirectsAndBoundsResponses() }),
            ("Fetch context and persistence without a workspace", { try await FetchContentTests().persistsResultsWithoutWorkspaceOrSearchProvider() }),
            ("Fetch failure, cancellation and recovery", { try await FetchContentTests().failuresAndCancellationNeverReplay() }),
            ("Web search request, context isolation and persistence", { try await WebSearchTests().roundTripKeepsSearchSeparateAndSavesSources() }),
            ("Custom search model stays independent of chat reasoning", { try await WebSearchTests().roundTripKeepsSearchSeparateAndSavesSources(searchModel: "custom-search") }),
            ("Search model preference applies across conversations and restarts", { try await WebSearchTests().searchModelPreferencePersistsAcrossConversations() }),
            ("Web search failure and no-retry behavior", { try await WebSearchTests().failuresStopWithoutRetriesOrFalseSuccess() }),
            ("Web search cancellation and restart safety", { try await WebSearchTests().cancellationAndRestartDoNotResumeSearch() }),
            ("Web search bounds and source safety", { try WebSearchTests().parsingBoundsAndSourceSafety() }),
            ("Web search validation and checkpoint safety", { try await WebSearchTests().invalidInputAndCheckpointFailureMakeNoRequests() }),
            ("Effort catalog and request encoding", { try await EffortTests().catalogAndRequestEncoding() }),
            ("Effort persistence and conversation isolation", { try await EffortTests().selectionPersistenceAndIsolation() }),
            ("Image drop normalization and validation", { try await ImageAttachmentTests().normalizesAndRejectsInvalidDrops() }),
            ("Image wire format and legacy sessions", { try ImageAttachmentTests().wireFormatAndLegacyDecoding() }),
            ("Image persistence and preservation after failure", { try await ImageAttachmentTests().sendsPersistsAndPreservesImagesAfterFailure() }),
            ("Pending image drop conversation isolation", { try await ImageAttachmentTests().pendingDropsStayWithOriginalConversation() }),
            ("Read file headers show actual line ranges", { try ReadFileSummaryTests().showsActualReturnedLines() }),
            ("Steering accepts input immediately and batches at model boundaries", { try await SteeringTests().acceptsImmediatelyAndBatchesAtModelBoundary() }),
            ("Steering finishes current tool and skips remaining calls", { try await SteeringTests().finishesCurrentToolAndSkipsRest() }),
            ("Steering withdraws approval without execution", { try await SteeringTests().withdrawsApprovalWithoutExecuting() }),
            ("Steering interruption and restoration preserve input without restart", { try await SteeringTests().interruptionPreservesInputAcrossRestore() }),
            ("Steering compaction and save failure safety", { try await SteeringTests().compactionAndSaveFailureDoNotRestartWork() }),
            ("Steering tool failure, cancellation and checkpoint safety", { try await SteeringTests().toolFailureAndCheckpointFailurePreserveInput() }),
            ("Steering stays with background conversation", { try await SteeringTests().backgroundInputStaysWithConversation() }),
            ("Session switches preserve native focus", { try await ComposerFocusTests().switchingSessionsDoesNotStealFocus() }),
            ("Pi progress animation frames", { try SteeringTests().progressFramesMatchPi() }),
            ("Run allowance observations persist with unknown values and legacy compatibility", { try await AccountUsageTests().runObservationsPersist() }),
            ("Response token details reject malformed counts", { try AccountUsageTests().responseUsageValidation() }),
            ("Account usage request, parsing and no retry", { try await AccountUsageTests().requestParsingAndFailure() }),
            ("Account usage sign-out isolation", { try await AccountUsageTests().accountIsolation() }),
            ("Provider footer remaining allowance and expiry", { try ProviderUsageFooterTests().remainingAllowanceAndExpiry() }),
            ("Provider footer fits narrow and wide sidebars", { try ProviderUsageFooterTests().fitsSidebarWidths() }),
            ("Composer command and path isolation", { try ComposerCommandTests().recognizesOnlyLeadingCommands() }),
            ("Composer cursor excludes controls", { try ComposerCursorTests().excludesControlsWithoutLeavingGaps() }),
            ("Batched snapshots flush on failure and cancellation", { try await chat.batchedSnapshotsFlushOnFailureAndCancellation() }),
            ("Transcript scroll routing and gesture isolation", { try TranscriptScrollTests().routesVerticalGesturesWithoutStealingOtherScrolling() }),
            ("Empty tool steps do not move the transcript", { try TranscriptTests().emptyToolStepsDoNotMoveTranscript() }),
            ("Expanded tool content stays within native row bounds", { try TranscriptTests().expandedToolContentStaysInsideCommittedRowBounds() }),
            ("Linked text wrapping, resizing and updates", { try LinkedTextTests().measuresWrappingAcrossWidthsAndUpdates() }),
            ("Markdown selection across blocks and streaming updates", { try MarkdownSelectionTests().selectsAndCopiesAcrossBlocksWithoutLosingFormatting() }),
            ("Markdown blocks and streaming code", { try MarkdownTests().preservesBlocksAndStreamingCode() }),
            ("Markdown link and image safety", { try MarkdownTests().stripsActiveContentAndUnsafeLinks() }),
            ("Approved edits and stale-file protection", { try await FileEditTests().approvedEditsRejectStaleFilesAndPreserveMode() }),
            ("Edit creation and diff boundaries", { try FileEditTests().creationAndDiffBoundaries() }),
            ("Concurrent edit protection", { try await FileEditTests().concurrentPreparedEditsCannotOverwriteEachOther() }),
            ("Diff column alignment and literal content", { try DiffTests().pairsReplacementsWithoutLosingMarkersOrPlusSigns() }),
            ("Session shortcut ordering and navigation", { try await SessionShortcutTests().shortcutsFollowSidebarOrderAndPreserveNavigation() }),
            ("Session restore and follow-up", { try await SessionTests().conversationAndWorkspaceSurviveRestart() }),
            ("Interrupted session recovery", { try await SessionTests().interruptedActionsAreRecordedNotReplayed() }),
            ("Session corruption and account isolation", { try await SessionTests().incompatibleOrCorruptSessionsAreNotOverwritten() }),
            ("Session switching, deletion and migration", { try await SessionTests().sessionsSwitchDeleteAndMigrateWithoutLosingHistory() }),
            ("Session index recovery", { try await SessionTests().indexRecoveryDoesNotReplayOrResurrectDeletedSessions() }),
            ("Checkpoint failure safety", { try await SessionTests().failedCheckpointPreventsModelAndToolExecution() }),
            ("Streaming leaves sidebar summaries unchanged", { try await ChatLibraryTests().streamingDoesNotInvalidateSidebarSummaries() }),
            ("Seven resident sessions switch without snapshot I/O", { try await ChatLibraryTests().sevenOpenSessionsSwitchSynchronouslyWithoutRewritingSnapshots() }),
            ("Superseded cold opens and durable recovery", { try await ChatLibraryTests().coldSelectionsAreSupersededAndRecoveryRemainsDurable() }),
            ("Concurrent conversations and foreground selection", { try await ChatLibraryTests().concurrentTurnsKeepContextDraftsAndSelectionIsolated() }),
            ("Workspace selection during active conversations", { try await ChatLibraryTests().workspaceSelectionDoesNotInterruptRunningConversations() }),
            ("Background approval isolation", { try await ChatLibraryTests().backgroundApprovalsStayWithTheirConversation() }),
            ("Read-only tool boundaries", { try ToolTests().readToolsStayWithinWorkspace() }),
            ("Shell output, timeout and cancellation", { try await ToolTests().shellOutputTimeoutAndCancellation() }),
            ("Shell approval", { try await ToolTests().everyShellCommandRequiresApproval() }),
            ("Scoped and revocable auto-approval", { try await ToolTests().autoApprovalIsScopedAndRevocable() }),
            ("Long tool turns and duplicate protection", { try await chat.longToolTurnsFinishWithoutArtificialCaps() }),
            ("Tool interruption and recovery", { try await chat.interruptedToolTurnRetainsResultsWithoutReexecution() }),
            ("Workspace instructions refresh on first send", { try await WorkspaceTests().refreshesInstructionsOnFirstSend() }),
            ("Workspace instruction loading", { try WorkspaceTests().loadsOnlyRootInstructionsAndRejectsUnsafeFiles() }),
            ("Workspace context isolation", { try await chat.workspaceChangesKeepInstructionsAndHistoryIsolated() }),
            ("Context usage reports and estimates", { try CompactionTests().contextUsageReportsOnlyMatchingMeasurements() }),
            ("Compaction threshold and durable continuation", { try await CompactionTests().thresholdAndDurableOpaqueContinuation() }),
            ("Compaction failure and cancellation safety", { try await CompactionTests().failedAndCancelledCompactionKeepsOriginalContext() }),
            ("Compaction estimates and tool boundaries", { try await CompactionTests().reportedCountsLegacyStateAndClosedToolBoundaries() }),
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
            ("Stable request encoding preserves tool schemas across rounds", { try CodexConnectionTests().preservesRequestEncodingAcrossToolRounds() }),
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
            ("Failed responses preserve prompts and exclude assistant output", { try await chat.failedResponsesPreservePromptsButExcludeAssistantOutput() }),
            ("Cancellation preserves partial context and restart history", { try await chat.stopPreservesPartialContext() })
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
