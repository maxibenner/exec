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

@main struct TestRunner {
    @MainActor static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Child-session navigation preserves approvals without replaying work", { try await DelegationTests().childNavigationPreservesApprovalAndDoesNotReplayWork() }),
            ("Child steering targets the owned operation, including initial snapshot races", { try await DelegationTests().childSteeringUsesExistingOperation() }),
            ("Deletion reconciles child sessions and returns focus to retained parents", { try await DelegationTests().parentDeletionRemovesResidentChildrenWithoutWaitingForSync() }),
            ("Sub-agent changes resize native sidebar rows without replacing their parent", { try await SessionPresentationTests().subagentsResizeTheirNativeParentRowWithoutReplacingIt() }),
            ("Delegation cards preserve tasks and failures", { try DelegationTests().delegationPresentationPreservesTaskAndFailure() }),
            ("File drops copy bytes and preserve atomic mixed imports", { try await FileAttachmentTests().copiesFilesAndKeepsMixedImportsAtomic() }),
            ("Queued files retain their operation, restore cards and never replay", { try await FileAttachmentTests().queuesFilesWithoutReplayingOrChangingOperation() }),
            ("Indicator gray bases stay visible under zero, partial and full blue pulses", { try WorkingIndicatorTests().grayBasesRemainVisibleUnderBluePulses() }),
            ("Indicator layers animate, freeze and stop when hidden or detached", { try WorkingIndicatorTests().layerAnimationLifecycle() }),
            ("Blue user bubbles support text and images in light and dark mode", { try await TranscriptTests().userBubblesSupportTextAndImagesInBothAppearances() }),
            ("Compaction and all tool headers keep stable activity geometry", { try TranscriptTests().activityIndicatorsKeepRowGeometry() }),
            ("Update availability restores before checks and clears when obsolete", { try UpdateNoticeTests().availabilityRestoresBeforeCheckingAndClearsWhenObsolete() }),
            ("Update badge dismissal persists per build", { try UpdateNoticeTests().dismissalSurvivesRelaunchAndOnlyHidesThatBuild() }),
            ("Silent update checks throttle failures and respect busy sessions", { try UpdateNoticeTests().silentChecksAreThrottledAndDoNotConsumeBusyAttempts() }),
            ("Update badge fits sidebar widths in light and dark appearances", { try UpdateNoticeTests().badgeFitsSidebarWidths() }),
            ("Window placement round-trips without toolbar height drift", { try MainWindowGeometryTests().roundTripsWithoutChromeDrift() }),
            ("Window placement adapts to changed and missing displays", { try MainWindowGeometryTests().adaptsToDisplayChanges() }),
            ("Window placement ignores invalid preferences", { try MainWindowGeometryTests().rejectsInvalidPreferences() }),
            ("Window geometry observes only the visible normal main window", { try await MainWindowGeometryTests().observesOnlyVisibleNormalMainWindow() }),
            ("Descriptive shell titles preserve commands and persisted preferences", { try ToolPresentationTests().descriptiveShellTitlesPreserveCommandAndResults() }),
            ("Tool summaries describe inputs and preserve results", { try ToolPresentationTests().describesInputsAndPreservesResults() }),
            ("Tool presentation preserves failures and unknown arguments", { try ToolPresentationTests().handlesFailuresAndUnknownArgumentsHonestly() }),
            ("Single-line tool headers and selectable expanded inputs", { try ToolPresentationTests().keepsHeadersOnOneLineAndBodiesSelectable() }),
            ("Sent-message navigation traverses user rows and returns to the bottom", { try MessageNavigationTests().traversesSentMessagesAndReturnsToBottom() }),
            ("Sent-message navigation preserves targets and resumes from manual scrolling", { try MessageNavigationTests().preservesTargetDuringUpdatesAndResumesFromManualScroll() }),
            ("Sent-message navigation handles empty and independent transcripts", { try MessageNavigationTests().emptySingleAndIndependentTranscripts() }),
            ("Transcript click-away selection clearing", { try TranscriptSelectionTests().clearsOtherSelectionsWithoutStealingClicks() }),
            ("Composer keeps its height while working and stopping", { try TranscriptTests().composerKeepsItsHeightWhileWorking() }),
            ("Composer aligns with overlay and legacy transcript scrollbars", { try await TranscriptTests().composerInsetMatchesTranscriptViewport() }),
            ("Transcript live resize commits widths before display", { try TranscriptTests().resizingCommitsRowsBeforeDisplay() }),
            ("Batched transcript measurements preserve geometry across resize and edits", { try TranscriptTests().batchedMeasurementsPreserveGeometryAcrossResizeAndEdits() }),
            ("Transcript reuses measurements without losing streaming or selection", { try await TranscriptTests().reusesMeasurementsWithoutLosingStreamingOrSelection() }),
            ("Formatted transcript resize retains hosts and measures each row once", { try await TranscriptTests().resizingFormattedRowsKeepsHostsAndMeasuresOnce() }),
            ("Local tool disclosures invalidate measured transcript heights", { try await TranscriptTests().localDisclosureChangesInvalidateMeasuredHeight() }),
            ("Near-bottom scrolling does not snap to the edge", { try TranscriptTests().preservesNearBottomScrolling() }),
            ("Virtual transcript geometry and scroll anchors", { try TranscriptTests().geometryPreservesAnchors() }),
            ("Virtual transcript mounts only viewport rows", { try await TranscriptTests().mountsBoundedRowsAndRestoresPosition() }),
            ("Compaction rows remain visible without assistant text", { try TranscriptTests().compactionRowsRemainVisibleWithoutAssistantText() }),
            ("Read file headers show actual line ranges", { try ReadFileSummaryTests().showsActualReturnedLines() }),
            ("Account usage remaining allowance and expiry", { try AccountUsageLabelTests().remainingAllowanceAndExpiry() }),
            ("Remote settings commit once and disable with an invalid draft", { try await RemoteAccessSettingsTests().savesOnCommitAndDisablesWithInvalidDraft() }),
            ("Remote toggle failures revert without replay", { try await RemoteAccessSettingsTests().failedToggleRevertsWithoutRetry() }),
            ("Account usage fits settings widths", { try AccountUsageLabelTests().fitsAvailableWidths() }),
            ("Composer command and path isolation", { try ComposerCommandTests().recognizesOnlyLeadingCommands() }),
            ("Composer cursor excludes controls", { try ComposerCursorTests().excludesControlsWithoutLeavingGaps() }),
            ("New sends reserve response space without following streaming content", { try TranscriptTurnScrollTests().anchorsNewSendsWhileResponsesFillSpace() }),
            ("Sent-turn scrolling survives resize, remount and manual reading", { try TranscriptTurnScrollTests().preservesReadingAndSupportsExplicitFollowing() }),
            ("Downward scrolling to the bottom resumes transcript tracking, not streaming growth", { try TranscriptTurnScrollTests().resumesFollowingOnlyAfterScrollingDownToBottom() }),
            ("First sends anchor before the viewport is laid out", { try TranscriptTurnScrollTests().anchorsBeforeInitialLayout() }),
            ("Header underlap preserves transcript geometry and anchors", { try TranscriptScrollTests().headerUnderlapPreservesGeometryAndAnchors() }),
            ("Transcript scroll routing and gesture isolation", { try TranscriptScrollTests().routesVerticalGesturesWithoutStealingOtherScrolling() }),
            ("Empty tool steps do not move the transcript", { try TranscriptTests().emptyToolStepsDoNotMoveTranscript() }),
            ("Expanded tool content stays within native row bounds", { try TranscriptTests().expandedToolContentStaysInsideCommittedRowBounds() }),
            ("Linked text wrapping, resizing and updates", { try LinkedTextTests().measuresWrappingAcrossWidthsAndUpdates() }),
            ("Markdown selection across blocks and streaming updates", { try MarkdownSelectionTests().selectsAndCopiesAcrossBlocksWithoutLosingFormatting() }),
            ("Markdown blocks and streaming code", { try MarkdownTests().preservesBlocksAndStreamingCode() }),
            ("Markdown link and image safety", { try MarkdownTests().stripsActiveContentAndUnsafeLinks() }),
            ("Diff column alignment and literal content", { try DiffTests().pairsReplacementsWithoutLosingMarkersOrPlusSigns() }),
            ("Sidebar drops publish immediately and reconcile persistence without retry", { try await SessionPresentationTests().reorderPublishesBeforePersistenceAndReconciles() }),
            ("New session rows and selection arrive together at the top", { try await SessionPresentationTests().newSessionStartsAtTop() }),
            ("Session creation failures and navigation clear temporary selection", { try await SessionPresentationTests().creationSelectionClearsOnFailureAndDoesNotStealNavigation() }),
            ("Deletion cancels sync reads and resumes after failure", { try await SessionPresentationTests().deletionIgnoresStreamClosureAndResumesOnFailure() }),
            ("Unsubmitted drafts survive navigation and uncertain creation", { try await BackendFollowupTests().localDraftSurvivesNavigationAndUncertainCreate() }),
            ("Remote deletion reconciles without losing local drafts", { try await BackendFollowupTests().remoteDeletionReconcilesAndPreservesLocalDraft() }),
            ("Inherited workspaces permit one explicit choice before starting", { try await BackendFollowupTests().inheritedWorkspaceCanBeChosenExactlyOnce() }),
            ("Model catalogs survive launch and reconcile successful refreshes", { try await BackendFollowupTests().modelCatalogSurvivesLaunchAndRefreshes() }),
            ("Account usage refreshes only on opening settings", { try await BackendFollowupTests().usageRefreshesOnlyOnSettingsRequest() }),
            ("Mid-turn commands apply once after idle", { try await BackendFollowupTests().commandsWaitForIdleAndPreserveApprovals() }),
            ("Compaction queues and uncertain settings stop queued effects", { try await BackendFollowupTests().compactQueuesOnceAndConfigurationFailureStopsActions() }),
            ("Desktop requests OS access on use and never shares late captures", { try await BackendFollowupTests().desktopRequestsOSPermissionOnUseAndDiscardsCancelledCapture() }),
            ("Desktop replies preserve correlation without retry", { try await BackendFollowupTests().desktopRepliesExactlyOnceWithoutRetry() }),
            ("Mac transcript sync pages large history and merges only its suffix", { try await AgentTranscriptSyncTests().pagesHistoryAndMergesOnlyTheChangedSuffix() }),
            ("Mac transcript sync backfills tool calls before publishing results", { try await AgentTranscriptSyncTests().backfillsToolCallsBeforePublishingResults() }),
            ("Mac transcript sync resets changed history and rejects wrong sessions", { try await AgentTranscriptSyncTests().resetsChangedHistoryAndRejectsWrongConversations() }),
            ("Agent incremental Unicode updates reconcile by stable identity", { try await AgentEventTests().streamsAndReconcilesWithoutReplacingRenderer() }),
            ("Agent sync recovers one failed read without replaying work", { try await AgentEventTests().reconnectsObserverOnceWithoutReplayingWork() }),
            ("Cancellation keeps ownership through cleanup", { try await AgentEventTests().cancellationOwnsCleanupAndUsesExactID() }),
            ("Uncertain configuration never retries", { try await AgentEventTests().configurationFailureDoesNotRetry() }),
            ("Agent snapshot reconciliation and approvals", { try await AgentIntegrationTests().snapshotAndApproval() }),
            ("Queued images retain their operation and never replay", { try await ImageQueueTests().queuesImagesWithoutReplayingOrChangingOperation() }),
            ("Uncertain submissions never retry", { try await AgentIntegrationTests().uncertainSendIsNotRetried() }),
            ("Quit retains copy and awaits backend shutdown", { try await AgentIntegrationTests().quitWaitsForBackendAndPreservesCopy() }),
            ("HTTP redirects and interrupted mutations never replay", { try await HTTPConsumerTests().redirectsAndInterruptedMutationsAreNotReplayed() }),
            ("HTTPS rejects an untrusted certificate without fallback", { try await HTTPConsumerTests().tlsRejectsUntrustedCertificate() }),
            ("Bundled backend ignores external settings and provisions private credentials", { try AgentIntegrationTests().httpConfiguration() }),
            ("Agent transport connects to isolated Rust service", { try await AgentIntegrationTests().realService() })
        ]
        for (name, check) in checks {
            do { try await check() }
            catch {
                FileHandle.standardError.write(Data("FAIL \(name): \(error)\n".utf8))
                exit(1)
            }
            print("PASS \(name)")
        }
        print("\(checks.count) checks passed.")
    }
}
