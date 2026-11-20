import AppKit
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
    // Keep run() in a synchronous entry point: AppKit marks it noasync. The
    // default suite is unchanged; only this isolated process owns an app loop.
    @MainActor private static func runComposerEvents() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        // A missing mouse-up could otherwise strand AppKit's tracking loop.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            FileHandle.standardError.write(Data("FAIL composer events: 60-second timeout\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            let checks: [(String, @MainActor () async throws -> Void)] = [
                ("Forked composers show a caret and accept real keyboard input", {
                    try await SidebarCreationTests().forkFocusesMountedComposerAfterNavigation()
                }),
                ("Composer survives a dismantled temporary replacement", {
                    try await ComposerEventTests().survivingEditorResumesAfterTemporaryReplacement()
                }),
                ("Composer real-event blur/refocus, subsequent clicks and explicit focus", {
                    try await ComposerEventTests().realBlurAndRefocusPreserveSelectionAndViewport()
                }),
                ("Composer remount restores selection and text-anchored viewport", {
                    try await ComposerEventTests().remountRestoresSelectionAndViewportAfterLayout()
                }),
                ("Composer stale snapshots cannot cross drafts or sessions", {
                    try await ComposerEventTests().changedDraftAndSessionDoNotReuseSnapshot()
                })
            ]
            var failures = 0
            for (name, check) in checks {
                do { try await check(); print("PASS \(name)") }
                catch {
                    failures += 1
                    FileHandle.standardError.write(Data("FAIL \(name): \(error)\n".utf8))
                }
            }
            print("\(checks.count - failures)/\(checks.count) composer event checks passed.")
            exit(failures == 0 ? 0 : 1)
        }
        NSApp.run()
    }

    @MainActor static func main() async {
        if CommandLine.arguments.contains("--composer-events") {
            runComposerEvents()
            return
        }
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Thinking footer follows response gaps and terminal states", { try ThinkingIndicatorTests().responseActivity() }),
            ("Thinking footer belongs to transcript geometry", { try await ThinkingIndicatorTests().documentFooter() }),
            ("Thinking footer delay cancels, restarts and ends on detach", { try await ThinkingIndicatorTests().delayLifecycle() }),
            ("Single-line and wrapped sidebar titles use consistent padding", { try SidebarTitleLayoutTests().singleAndWrappedTitlesUseTheSamePadding() }),
            ("Startup counts zero, one and multiple sessions", { try StartupSessionCountTests().countsZeroOneAndMultipleSessions() }),
            ("Startup ignores children and invalid files", { try StartupSessionCountTests().ignoresChildrenAndInvalidFiles() }),
            ("Sidebar visibility is set before ordering the window front", { try await SidebarVisibilityTests().appliesInitialVisibilityBeforeOrderingWindowFront() }),
            ("Sidebar toggles survive content, count and focus changes", { try await SidebarVisibilityTests().nativeToggleSurvivesContentCountAndFocusChanges() }),
            ("Sidebar reveal requests respect subsequent manual close", { try await SidebarVisibilityTests().revealRequestsOpenOnceAndRespectSubsequentManualClose() }),
            ("Only successful second top-level creation reveals the sidebar", { try await SidebarCreationTests().onlySecondTopLevelCreationRevealsAfterSuccess() }),
            ("Blank creation waits for workspace selection before revealing", { try await SidebarCreationTests().blankWorkspaceCreationRevealsOnlyAfterSelectionAndSave() }),
            ("Failed creation and fork never reveal the sidebar", { try await SidebarCreationTests().failedCreationAndForkNeverReveal() }),
            ("Fork reveals only for the second top-level session", { try await SidebarCreationTests().forkRevealsOnlyForSecondTopLevelSession() }),
            ("Navigation, deletion and catalogs never reveal the sidebar", { try await SidebarCreationTests().navigationDeletionAndCatalogChangesNeverReveal() }),
            ("Intervening catalog changes cannot trigger a second-session reveal", { try await SidebarCreationTests().interveningCatalogChangesDoNotMasqueradeAsSecondCreation() }),
            ("Settings use an aligned native header and permanent sidebar", { try await SettingsWindowLayoutTests().nativeHeaderKeepsSidebarVisibleAcrossSections() }),
            ("Library initial and legacy tool defaults disable shell", { try await DefaultToolSettingsTests().initialAndLegacyDefaultsDisableShell() }),
            ("Rejected catalog writes allow corrected explicit changes", { try await SessionCatalogRecoveryTests().rejectedWritesDoNotPoisonQueuedOrFutureExplicitChanges() }),
            ("Ambiguous catalog writes recover by reading without replay", { try await SessionCatalogRecoveryTests().ambiguousWritesRequireAuthoritativeReadWithoutReplayingChanges() }),
            ("Library rejections save only newer explicit corrections", { try await ChatLibraryCatalogRecoveryTests().rejectionSavesOnlyNewerExplicitCorrection() }),
            ("Skipped library restores retain their pending catchup", { try await ChatLibraryCatalogRecoveryTests().skippedRestoreKeepsCatchupPending() }),
            ("Unsettled library writes require settled reads without replay", { try await ChatLibraryCatalogRecoveryTests().unsettledWriteRequiresSettledReadWithoutReplay() }),
            ("Explicit all-enabled defaults persist and restore", { try await DefaultToolSettingsTests().explicitAllEnabledPersistsAndRestores() }),
            ("Shared tool defaults only affect future conversations", { try await DefaultToolSettingsTests().sharedDefaultsOnlyAffectFutureConversations() }),
            ("Session tools default enabled and accept all selections", { try await SessionToolSelectionTests().defaultsAndAllToolNames() }),
            ("Session tool snapshots replace selection and support legacy metadata", { try SessionToolSelectionTests().snapshotsReplaceSelectionAndSupportLegacyMetadata() }),
            ("Session tool creation and re-enabling persist through normal saves", { try await SessionToolSelectionTests().creationAndReenablePersistThroughNormalSave() }),
            ("Active tool selections reconcile once at idle", { try await SessionToolSelectionTests().activeSelectionsReconcileAtIdle() }),
            ("Net unchanged tool selections do not write", { try await SessionToolSelectionTests().netUnchangedSelectionDoesNotWrite() }),
            ("Tool selections stay editable and retain changes during saves", { try await SessionToolSelectionTests().selectionsDuringSaveKeepLatestChoice() }),
            ("Failed tool selection saves are not retried", { try await SessionToolSelectionTests().failedSelectionSaveIsNotRetried() }),
            ("Sub-agents cannot change tool selection", { try await SessionToolSelectionTests().childrenCannotToggle() }),
            ("New conversations reset tool selection without changing the source", { try await SessionToolSelectionTests().newConversationsResetSelectionWithoutChangingSource() }),
            ("Session tool catalog preserves names, groups and icons", { try SessionToolCatalogTests().preservesNamesGroupsAndTranscriptIcons() }),
            ("Fork preserves the saved snapshot instead of defaults", { try await SessionForkTests().forkPreservesReturnedSnapshotInsteadOfDefaults() }),
            ("Fork saves pending source configuration before copying", { try await SessionForkTests().forkSavesPendingSourceConfigurationBeforeCopying() }),
            ("Failed source saves prevent forks without retry", { try await SessionForkTests().failedSourceSavePreventsForkWithoutRetrying() }),
            ("Clear preserves configuration and drafts across observers", { try await SessionClearTests().clearPreservesConfigurationAndLocalDraftAcrossObservers() }),
            ("Clear saves pending configuration before resetting", { try await SessionClearTests().clearPersistsPendingConfigurationBeforeReset() }),
            ("Clear consumes only its unchanged confirmed command draft", { try await SessionClearTests().clearConsumesOnlyUnchangedCommandDraftAfterConfirmation() }),
            ("Failed clear requires read-only recovery without retry", { try await SessionClearTests().failedClearRequiresReadonlyRecoveryWithoutRetry() }),
            ("Failed configuration saves prevent clear without retry", { try await SessionClearTests().failedConfigurationSavePreventsClearWithoutRetry() }),
            ("Clear settles a single pending submission without replay", { try await SessionClearTests().clearWaitsForSingleSubmissionThenResetsWithoutReplay() }),
            ("Active clear cancels before saving pending settings", { try await SessionClearTests().activeClearSavesPendingSettingsOnlyAfterCancellation() }),
            ("Unsaved sessions cannot clear", { try await SessionClearTests().unsavedSessionsCannotClear() }),
            ("Active sessions clear without waiting for idle", { try await SessionClearTests().activeSessionsClearImmediatelyWithoutWaitingForIdle() }),
            ("Incremental delegation keeps one active result card", { try DelegationProgressTests().projectsIncrementalResultsInOneActiveCard() }),
            ("Delegation preserves results through cleanup and disclosure changes", { try DelegationProgressTests().preservesResultsThroughCleanupFailureAndDisclosureChanges() }),
            ("Delegation sync replaces results without replaying work", { try await DelegationProgressTests().syncReplacesPartialAndFinalResultsWithoutReplayingWork() }),
            ("Wait cards preserve inputs and outcomes", { try WaitTests().presentationPreservesInputsAndOutcomes() }),
            ("Wait activity sync preserves pending rows and clears waiting", { try await WaitTests().activityOnlySyncPreservesPendingRowAndClearsWaiting() }),
            ("Resident and catalog waits use existing active-session confirmation", { try await WaitTests().residentAndCatalogWaitsRequireExistingConfirmation() }),
            ("Deletion cancellation preserves running work", { try await SessionDeletionTests().cancellationLeavesRunningWorkUntouched() }),
            ("Deletion retains its target and ignores duplicates", { try await SessionDeletionTests().confirmationKeepsOriginalIDAndIgnoresDuplicateRequests() }),
            ("Deletion detects running descendants", { try await SessionDeletionTests().runningFamilyIncludesNestedAndNonresidentWork() }),
            ("Idle deletion is immediate and single-shot", { try await SessionDeletionTests().idleDeletionIsImmediateAndSingleShot() }),
            ("Cleanup during confirmation cannot redirect deletion", { try await SessionDeletionTests().automaticCleanupWhileConfirmingDoesNotDeleteAnotherSession() }),
            ("Detached deletion uses the same confirmation", { try await SessionDeletionTests().detachedWindowCommandUsesTheSameConfirmation() }),
            ("Automatic cleanup reconciles both catalog/poll orders without warnings", { try await SessionLifecycleTests().cleanupOrdersNeverPublishConnectionWarnings() }),
            ("Cleanup preserves unsent drafts and genuine observation failures", { try await SessionLifecycleTests().cleanupPreservesDraftsAndRealFailures() }),
            ("Intentional child stops never flash attention during automatic cleanup", { try await ChildStopAttentionTests().intentionalStopNeverFlashesAttentionDuringChildCleanup() }),
            ("Child stops preserve genuine failures, storage warnings and approval", { try await ChildStopAttentionTests().childStopKeepsRealFailuresStorageAndApprovalActionable() }),
            ("Cleanup settles remote cancellation without hiding real errors", { try await SessionLifecycleTests().cleanupSettlesRemoteCancellationWithoutHidingRealErrors() }),
            ("Stale catalogs and observer generations cannot remove new residents", { try await SessionLifecycleTests().staleCatalogsAndObserverGenerationsCannotRemoveNewResidents() }),
            ("Creation and registration survive older catalog absence", { try await SessionLifecycleTests().creationAndRegistrationSurviveOlderAbsence() }),
            ("Automatic cleanup loads an evicted parent with a safe failure fallback", { try await SessionLifecycleTests().cleanupLoadsEvictedParentAndKeepsSafeFallback() }),
            ("Cleanup during navigation respects parent window ownership", { try await SessionLifecycleTests().cleanupDuringNavigationRespectsParentWindowOwnership() }),
            ("Native composer focus follows repeated requests, rapid navigation and cleanup", { try await SessionLifecycleTests().nativeComposerFocusFollowsRequestsAndCleanup() }),
            ("Attachment remove marks stay centered at 1× and 2×", { try AttachmentRemoveButtonTests().marksStayCentered() }),
            ("Child-session navigation preserves approvals without replaying work", { try await DelegationTests().childNavigationPreservesApprovalAndDoesNotReplayWork() }),
            ("Child steering targets the owned operation, including initial snapshot races", { try await DelegationTests().childSteeringUsesExistingOperation() }),
            ("Deletion reconciles child sessions and returns focus to retained parents", { try await DelegationTests().parentDeletionRemovesResidentChildrenWithoutWaitingForSync() }),
            ("Child content keeps its inset and full width in light and dark sidebars", { try SidebarRowAnimationTests().childContentInsetsStayInsideItsFullWidth() }),
            ("Sidebar height interpolation moves neighbors without compressing natural content", { try SidebarRowAnimationTests().interpolatedHeightAllocatesLayoutWithoutCompressingContent() }),
            ("Sub-agent changes preserve native row identity, child insets and parent alignment", { try await SessionPresentationTests().subagentsResizeTheirNativeParentRowWithoutReplacingIt() }),
            ("Delegation cards preserve tasks and failures", { try DelegationTests().delegationPresentationPreservesTaskAndFailure() }),
            ("File drops copy bytes and preserve atomic mixed imports", { try await FileAttachmentTests().copiesFilesAndKeepsMixedImportsAtomic() }),
            ("Queued files retain their operation, restore cards and never replay", { try await FileAttachmentTests().queuesFilesWithoutReplayingOrChangingOperation() }),
            ("Indicator gray bases stay visible under zero, partial and full accent pulses", { try WorkingIndicatorTests().grayBasesRemainVisibleUnderAccentPulses() }),
            ("Indicator layers animate, freeze and stop when hidden or detached", { try WorkingIndicatorTests().layerAnimationLifecycle() }),
            ("System-accent user bubbles support text and images in light and dark mode", { try await TranscriptTests().userBubblesSupportTextAndImagesInBothAppearances() }),
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
            ("Transcript keeps the full native scrollbar knob and hit geometry", { try TranscriptScrollerTests().keepsTheFullNativeKnobAndHitGeometryAcrossStylesAndResizes() }),
            ("Composer aligns with overlay and legacy transcript scrollbars", { try await TranscriptTests().composerInsetMatchesTranscriptViewport() }),
            ("Transcript live resize commits widths before display", { try TranscriptTests().resizingCommitsRowsBeforeDisplay() }),
            ("Batched transcript measurements preserve geometry across resize and edits", { try TranscriptTests().batchedMeasurementsPreserveGeometryAcrossResizeAndEdits() }),
            ("Transcript reuses measurements without losing streaming or selection", { try await TranscriptTests().reusesMeasurementsWithoutLosingStreamingOrSelection() }),
            ("Formatted transcript resize retains hosts and measures each row once", { try await TranscriptTests().resizingFormattedRowsKeepsHostsAndMeasuresOnce() }),
            ("Local tool disclosures invalidate measured transcript heights", { try await TranscriptTests().localDisclosureChangesInvalidateMeasuredHeight() }),
            ("Near-bottom scrolling does not snap to the edge", { try TranscriptTests().preservesNearBottomScrolling() }),
            ("Virtual transcript geometry and scroll anchors", { try TranscriptTests().geometryPreservesAnchors() }),
            ("Tool clusters preserve gap-free geometry and scroll anchors", { try TranscriptTests().toolClustersPreserveGeometryAndAnchors() }),
            ("Virtual transcript mounts only viewport rows", { try await TranscriptTests().mountsBoundedRowsAndRestoresPosition() }),
            ("Backend compaction snapshots preserve activity and status", { try AgentIntegrationTests().compactionSnapshotsPreserveActivity() }),
            ("Compaction rows remain visible without assistant text", { try TranscriptTests().compactionRowsRemainVisibleWithoutAssistantText() }),
            ("Read file headers show actual line ranges", { try ReadFileSummaryTests().showsActualReturnedLines() }),
            ("Account usage remaining allowance and expiry", { try AccountUsageLabelTests().remainingAllowanceAndExpiry() }),
            ("Remote settings cache survives reentry and stays backend-scoped", { try await RemoteAccessSettingsCacheTests().stateSurvivesReentryAndStaysBackendScoped() }),
            ("Remote refresh publishes only changes and preserves relay drafts", { try await RemoteAccessSettingsCacheTests().refreshPublishesOnlyChangesAndPreservesRelayDraft() }),
            ("Remote read failures preserve cache and allow recovery", { try await RemoteAccessSettingsCacheTests().readFailuresPreserveCacheAndAllowRecovery() }),
            ("Older and cancelled remote reads cannot replace fresh state", { try await RemoteAccessSettingsCacheTests().olderAndCancelledReadsDoNotReplaceFreshState() }),
            ("Stale remote polls cannot replace toggle acknowledgements", { try await RemoteAccessSettingsCacheTests().stalePollDoesNotReplaceToggleAcknowledgement() }),
            ("Remote toggles use acknowledgements and reconcile without replay", { try await RemoteAccessSettingsCacheTests().toggleUsesAcknowledgementAndReconcilesWithoutRetry() }),
            ("Pairing QR prepares stable scan and copy content", { try RemoteAccessSettingsTests().pairingQRCodePreparesStableScanAndCopyContent() }),
            ("Pairing popup keeps a white QR container and stable clipboard content in both appearances", { try PairingQRCodePopupTests().readableCodeAndStableCopyInBothAppearances() }),
            ("Remote settings commit once and disable with an invalid draft", { try await RemoteAccessSettingsTests().savesOnCommitAndDisablesWithInvalidDraft() }),
            ("Remote toggle failures revert without replay", { try await RemoteAccessSettingsTests().failedToggleRevertsWithoutRetry() }),
            ("Account usage fits settings widths", { try AccountUsageLabelTests().fitsAvailableWidths() }),
            ("Composer command and path isolation", { try ComposerCommandTests().recognizesOnlyLeadingCommands() }),
            ("Composer cursor excludes controls", { try ComposerCursorTests().excludesControlsWithoutLeavingGaps() }),
            ("Composer bridges focus state and preserves marked text through updates", { try await ComposerTextInputTests().bridgesFocusAndPreservesComposition() }),
            ("Retired composers cannot apply queued focus or binding updates", { try await ComposerTextInputTests().retiredEditorsCannotApplyQueuedFocus() }),
            ("Composer preserves its viewport and selection across focus changes", { try await ComposerTextInputTests().preservesViewportAcrossFocusChanges() }),
            ("Composer renders a consistent caret at line starts and ends", { try ComposerTextInputTests().drawsConsistentCaret() }),
            ("Submitted attachments forward vertical scrolling to the transcript", { try AttachmentScrollTests().submittedAttachmentsForwardVerticalScrolling() }),
            ("Composer sizes wrapped drafts and routes editing commands", { try ComposerTextInputTests().sizesAndRoutesEditingCommands() }),
            ("New sends reserve response space without following streaming content", { try TranscriptTurnScrollTests().anchorsNewSendsWhileResponsesFillSpace() }),
            ("Sent-turn scrolling survives resize, remount and manual reading", { try TranscriptTurnScrollTests().preservesReadingAndSupportsExplicitFollowing() }),
            ("Downward scrolling to the bottom resumes transcript tracking, not streaming growth", { try TranscriptTurnScrollTests().resumesFollowingOnlyAfterScrollingDownToBottom() }),
            ("First sends anchor before the viewport is laid out", { try TranscriptTurnScrollTests().anchorsBeforeInitialLayout() }),
            ("Streaming visual growth coalesces and stays bounded", { try TranscriptScrollTests().growthCoalescesWithoutMovingLogicalGeometry() }),
            ("Completion preserves only identical rendering and passive hit tests are inert", { try TranscriptScrollTests().completionPreservesOnlyIdenticalRendering() }),
            ("Streaming pins every measured pass and respects manual opt-out", { try TranscriptScrollTests().pinsEveryMeasuredPassAndRespectsManualOptOut() }),
            ("Bottom following survives native geometry and rubber-band rebound", { try TranscriptScrollTests().bottomFollowSurvivesNativeGeometryAndBounce() }),
            ("A downward boundary wheel resumes a short reserved turn", { try TranscriptScrollTests().boundaryWheelResumesShortReservedTurn() }),
            ("Header underlap preserves transcript geometry and anchors", { try TranscriptScrollTests().headerUnderlapPreservesGeometryAndAnchors() }),
            ("Transcript scroll routing and gesture isolation", { try TranscriptScrollTests().routesVerticalGesturesWithoutStealingOtherScrolling() }),
            ("Empty tool steps do not move the transcript", { try TranscriptTests().emptyToolStepsDoNotMoveTranscript() }),
            ("Expanded tool content stays within native row bounds", { try TranscriptTests().expandedToolContentStaysInsideCommittedRowBounds() }),
            ("Rendered edits preserve selection and code append positions", { try LinkedTextTests().renderedEditsPreserveSelectionAndCodeAppendPositions() }),
            ("Linked text wrapping, resizing and updates", { try LinkedTextTests().measuresWrappingAcrossWidthsAndUpdates() }),
            ("Streaming Markdown stabilizes unfinished tails and finishes canonically", { try StreamingMarkdownTests().projectsOnlyUnfinishedTails() }),
            ("Markdown native code and table surfaces have whole-block rounded corners", { try MarkdownBlockBackgroundTests().roundsNativeCodeAndTableSurfaces() }),
            ("Markdown selection across blocks and streaming updates", { try MarkdownSelectionTests().selectsAndCopiesAcrossBlocksWithoutLosingFormatting() }),
            ("Markdown blocks and streaming code", { try MarkdownTests().preservesBlocksAndStreamingCode() }),
            ("Markdown link and image safety", { try MarkdownTests().stripsActiveContentAndUnsafeLinks() }),
            ("Diff column alignment and literal content", { try DiffTests().pairsReplacementsWithoutLosingMarkersOrPlusSigns() }),
            ("Sidebar drops publish immediately and reconcile persistence without retry", { try await SessionPresentationTests().reorderPublishesBeforePersistenceAndReconciles() }),
            ("Workspace picker and creation preserve the current conversation until success", { try await SidebarCreationTests().pickerKeepsCurrentUntilCreationCompletes() }),
            ("New session rows and selection arrive together at the top", { try await SessionPresentationTests().newSessionStartsAtTop() }),
            ("Session creation failures preserve selection and navigation wins", { try await SessionPresentationTests().creationKeepsCurrentOnFailureAndDoesNotStealNavigation() }),
            ("Deletion cancels sync reads and resumes after failure", { try await SessionPresentationTests().deletionIgnoresStreamClosureAndResumesOnFailure() }),
            ("Unsubmitted drafts survive navigation and uncertain creation", { try await BackendFollowupTests().localDraftSurvivesNavigationAndUncertainCreate() }),
            ("Remote deletion reconciles without losing local drafts", { try await BackendFollowupTests().remoteDeletionReconcilesAndPreservesLocalDraft() }),
            ("New sessions use Settings defaults and request a workspace", { try await BackendFollowupTests().freshSessionsUseSettingsDefaultsAndRequestWorkspace() }),
            ("Model catalogs survive launch and reconcile successful refreshes", { try await BackendFollowupTests().modelCatalogSurvivesLaunchAndRefreshes() }),
            ("Account usage refreshes only on opening settings", { try await BackendFollowupTests().usageRefreshesOnlyOnSettingsRequest() }),
            ("Mid-turn commands apply once after idle", { try await BackendFollowupTests().commandsWaitForIdleAndPreserveApprovals() }),
            ("Compaction queues and uncertain settings stop queued effects", { try await BackendFollowupTests().compactQueuesOnceAndConfigurationFailureStopsActions() }),
            ("Pending and running compaction queue sends once without consuming new drafts", { try await CompactionQueueTests().pendingAndRunningCompactionQueueOnceWithoutConsumingNewDrafts() }),
            ("Uncertain compaction and queue requests never start a fallback turn", { try await CompactionQueueTests().uncertainCompactionOrQueueNeverFallsBackToANewTurn() }),
            ("Stop before compaction acceptance retains drafts and operation ownership", { try await CompactionQueueTests().stopBeforeCompactionReceiptRetainsDraftAndTargetsAcceptedOperation() }),
            ("Compaction sends preserve configuration ordering and uncertain-write safety", { try await CompactionQueueTests().compactionDoesNotBypassConfigurationSavesOrUncertainWrites() }),
            ("Desktop requests OS access on use and never shares late captures", { try await BackendFollowupTests().desktopRequestsOSPermissionOnUseAndDiscardsCancelledCapture() }),
            ("Desktop replies preserve correlation without retry", { try await BackendFollowupTests().desktopRepliesExactlyOnceWithoutRetry() }),
            ("Notifications share one idle stream and filter revisions", { try await ChangeNotificationTests().sharedIdleAndRevisionSpecificCatchup() }),
            ("Notifications subscribe before reads and retain concurrent invalidations", { try await ChangeNotificationTests().subscribeBeforeReadAndChangesDuringRead() }),
            ("Notifications reconnect with catchup and bounded backoff", { try await ChangeNotificationTests().reconnectCatchupAndBoundedBackoff() }),
            ("Only explicit unsupported notifications enable legacy polling", { try await ChangeNotificationTests().explicitUnsupportedOnlyAndLegacyCadence() }),
            ("Catalog notifications preserve read races and legacy fallback", { try await ChangeNotificationTests().catalogFallbackAndReadRace() }),
            ("Superseded catalog reads retain their invalidation", { try await ChangeNotificationTests().supersededCatalogReadRetainsInvalidation() }),
            ("Transcript read failures recover without catalog changes", { try await ChangeNotificationTests().transientReadFailuresRecoverWithoutCatalogChanges() }),
            ("Notifications coalesce, handle epoch/removal and close independently", { try await ChangeNotificationTests().coalescesEpochRemovalAndShutdown() }),
            ("Warm switching keeps hidden notification readers current", { try await ChangeNotificationTests().warmSwitchingKeepsHiddenResidentsCurrent() }),
            ("Typed sync preserves cursor proof without history encoding", { try AgentTranscriptSyncTests().typedStatePreservesProofAndRejectsInvalidPages() }),
            ("Mac transcript sync pages large history and merges only its suffix", { try await AgentTranscriptSyncTests().pagesHistoryAndMergesOnlyTheChangedSuffix() }),
            ("Mac transcript sync backfills tool calls before publishing results", { try await AgentTranscriptSyncTests().backfillsToolCallsBeforePublishingResults() }),
            ("Mac transcript sync resets changed history and rejects wrong sessions", { try await AgentTranscriptSyncTests().resetsChangedHistoryAndRejectsWrongConversations() }),
            ("Agent incremental Unicode updates reconcile by stable identity", { try await AgentEventTests().streamsAndReconcilesWithoutReplacingRenderer() }),
            ("Agent sync recovers one failed read without replaying work", { try await AgentEventTests().reconnectsObserverOnceWithoutReplayingWork() }),
            ("Cancellation keeps ownership through cleanup", { try await AgentEventTests().cancellationOwnsCleanupAndUsesExactID() }),
            ("Stop and close during image/file uploads retain drafts without dispatch", { try await SubmissionSafetyTests().stopAndCloseDuringUploadsNeverDispatchAndPreserveDrafts() }),
            ("Stop after dispatch reconciles once and cancels only the confirmed operation", { try await SubmissionSafetyTests().stopAfterDispatchReconcilesOnceAndCancelsOnlyConfirmedOperation() }),
            ("Uncertain configuration never retries", { try await AgentEventTests().configurationFailureDoesNotRetry() }),
            ("Agent snapshot reconciliation and approvals", { try await AgentIntegrationTests().snapshotAndApproval() }),
            ("Failed approval decisions reconcile pending state without replay", { try await ToolApprovalRecoveryTests().failedDecisionsReconcileAuthoritativelyWithoutResending() }),
            ("Queued images retain their operation and never replay", { try await ImageQueueTests().queuesImagesWithoutReplayingOrChangingOperation() }),
            ("Uncertain submissions never retry", { try await AgentIntegrationTests().uncertainSendIsNotRetried() }),
            ("Quit retains copy and awaits backend shutdown", { try await AgentIntegrationTests().quitWaitsForBackendAndPreservesCopy() }),
            ("Idle and detached drafts require explicit Quit loss confirmation", { try await QuitDraftTests().idleAndDetachedDraftsRequireExplicitLossConfirmation() }),
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
