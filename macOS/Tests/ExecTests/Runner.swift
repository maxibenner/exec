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
            ("Account usage fits settings widths", { try AccountUsageLabelTests().fitsAvailableWidths() }),
            ("Composer command and path isolation", { try ComposerCommandTests().recognizesOnlyLeadingCommands() }),
            ("Composer cursor excludes controls", { try ComposerCursorTests().excludesControlsWithoutLeavingGaps() }),
            ("Header underlap preserves transcript geometry and anchors", { try TranscriptScrollTests().headerUnderlapPreservesGeometryAndAnchors() }),
            ("Transcript scroll routing and gesture isolation", { try TranscriptScrollTests().routesVerticalGesturesWithoutStealingOtherScrolling() }),
            ("Empty tool steps do not move the transcript", { try TranscriptTests().emptyToolStepsDoNotMoveTranscript() }),
            ("Expanded tool content stays within native row bounds", { try TranscriptTests().expandedToolContentStaysInsideCommittedRowBounds() }),
            ("Linked text wrapping, resizing and updates", { try LinkedTextTests().measuresWrappingAcrossWidthsAndUpdates() }),
            ("Markdown selection across blocks and streaming updates", { try MarkdownSelectionTests().selectsAndCopiesAcrossBlocksWithoutLosingFormatting() }),
            ("Markdown blocks and streaming code", { try MarkdownTests().preservesBlocksAndStreamingCode() }),
            ("Markdown link and image safety", { try MarkdownTests().stripsActiveContentAndUnsafeLinks() }),
            ("Diff column alignment and literal content", { try DiffTests().pairsReplacementsWithoutLosingMarkersOrPlusSigns() }),
            ("New session rows start at the top before catalog persistence", { try SessionPresentationTests().newSessionStartsAtTop() }),
            ("Deletion suppresses expected stream closure and preserves real failures", { try await SessionPresentationTests().deletionIgnoresStreamClosureAndResumesOnFailure() }),
            ("Unsubmitted drafts survive navigation and uncertain creation", { try await BackendFollowupTests().localDraftSurvivesNavigationAndUncertainCreate() }),
            ("Inherited workspaces permit one explicit choice before starting", { try await BackendFollowupTests().inheritedWorkspaceCanBeChosenExactlyOnce() }),
            ("Account usage refreshes only on opening settings", { try await BackendFollowupTests().usageRefreshesOnlyOnSettingsRequest() }),
            ("Mid-turn commands apply once after idle", { try await BackendFollowupTests().commandsWaitForIdleAndPreserveApprovals() }),
            ("Compaction queues and uncertain settings stop queued effects", { try await BackendFollowupTests().compactQueuesOnceAndConfigurationFailureStopsActions() }),
            ("Desktop grants and cancellation never share late captures", { try await BackendFollowupTests().desktopRequiresExplicitGrantAndDiscardsCancelledCapture() }),
            ("Desktop replies preserve correlation without retry", { try await BackendFollowupTests().desktopRepliesExactlyOnceWithoutRetry() }),
            ("Agent streamed Unicode reconciles by stable identity", { try await AgentEventTests().streamsAndReconcilesWithoutReplacingRenderer() }),
            ("Cancellation keeps ownership through cleanup", { try await AgentEventTests().cancellationOwnsCleanupAndUsesExactID() }),
            ("Uncertain configuration never retries", { try await AgentEventTests().configurationFailureDoesNotRetry() }),
            ("Agent snapshot reconciliation and approvals", { try await AgentIntegrationTests().snapshotAndApproval() }),
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
