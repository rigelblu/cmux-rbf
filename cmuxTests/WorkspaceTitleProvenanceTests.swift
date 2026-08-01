import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for custom-title provenance: auto-naming writes must never
/// overwrite user-set titles, clearing must reset provenance, and provenance
/// must round-trip through session snapshots (with legacy snapshots that
/// predate provenance decoding as user-owned).
@MainActor
@Suite struct WorkspaceTitleProvenanceTests {

    // MARK: - Workspace titles

    @Test func autoWriteOnUntitledWorkspaceLands() {
        let workspace = Workspace(title: "Terminal")
        let applied = workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(applied)
        #expect(workspace.title == "Fix auth bug")
        #expect(workspace.customTitle == "Fix auth bug")
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func autoWriteOverUserTitleIsRejected() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("My Project")
        let applied = workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(!applied)
        #expect(workspace.title == "My Project")
        #expect(workspace.effectiveCustomTitleSource == .user)
    }

    @Test func userWriteOverAutoTitleLandsAndClaimsOwnership() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        let applied = workspace.setCustomTitle("Release prep")
        #expect(applied)
        #expect(workspace.title == "Release prep")
        #expect(workspace.effectiveCustomTitleSource == .user)
        // The workspace is now user-owned: further auto writes must be rejected.
        #expect(!workspace.setCustomTitle("Something else", source: .auto))
    }

    @Test func autoWriteCanRefreshAutoTitle() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        let applied = workspace.setCustomTitle("Debug login flow", source: .auto)
        #expect(applied)
        #expect(workspace.title == "Debug login flow")
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func autoWriteNeverClears() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(!workspace.setCustomTitle(nil, source: .auto))
        #expect(!workspace.setCustomTitle("   ", source: .auto))
        #expect(workspace.title == "Fix auth bug")
    }

    @Test func codexRenameReplacesAutomaticNameButNotDirectCmuxName() {
        let workspace = Workspace(title: "Terminal")
        #expect(workspace.setCustomTitle("Automatic summary", source: .auto))
        #expect(workspace.setCustomTitle("Explicit Codex name", source: .agentSession))
        #expect(workspace.title == "Explicit Codex name")
        #expect(workspace.effectiveCustomTitleSource == .agentSession)

        #expect(workspace.setCustomTitle("Direct cmux name"))
        #expect(!workspace.setCustomTitle("Later Codex name", source: .agentSession))
        #expect(workspace.title == "Direct cmux name")
        #expect(workspace.effectiveCustomTitleSource == .user)
    }

    @Test func clearingDirectCmuxNameLetsNextCodexRenameLand() {
        let workspace = Workspace(title: "Terminal")
        #expect(workspace.setCustomTitle("Direct cmux name"))
        #expect(workspace.setCustomTitle(nil))
        #expect(workspace.setCustomTitle("Explicit Codex name", source: .agentSession))
        #expect(workspace.title == "Explicit Codex name")
        #expect(workspace.effectiveCustomTitleSource == .agentSession)
    }

    @Test func codexRenameConfirmationRequiresResumeThreadIdentity() {
        var detector = CodexRenameConfirmationDetector()
        let automaticText = Array("Session renamed to Automatic summary.".utf8)
        let automaticMatches = automaticText.withUnsafeBufferPointer {
            detector.consume($0)
        }
        #expect(automaticMatches.isEmpty)

        let explicitText = Array(
            ("\u{001B}[2mSession renamed to \u{001B}[0mFix auth bug" +
                ". To resume this session run \u{001B}[1mcodex resume, then select " +
                "Fix auth bug (123E4567-E89B-12D3-A456-426614174000)\u{001B}[0m.").utf8
        )
        let explicitMatches = explicitText.withUnsafeBufferPointer {
            detector.consume($0)
        }
        #expect(explicitMatches == [
            CodexRenameConfirmation(
                name: "Fix auth bug",
                threadID: "123E4567-E89B-12D3-A456-426614174000"
            )
        ])
    }

    /// An automatic name update renders the same cell and carries no resume
    /// hint, so it sits in the buffer ahead of the next real confirmation.
    /// Scanning forward from the first name prefix splices the two together
    /// and yields a name the user never typed.
    @Test func automaticNameAheadOfConfirmationDoesNotSpliceIntoTheName() {
        var detector = CodexRenameConfirmationDetector()
        let automaticThenExplicit = Array(
            ("Session renamed to Automatic summary." +
                "Session renamed to Fix auth bug. To resume this session run " +
                "codex resume, then select Fix auth bug " +
                "(123E4567-E89B-12D3-A456-426614174000)").utf8
        )
        let matches = automaticThenExplicit.withUnsafeBufferPointer {
            detector.consume($0)
        }
        #expect(matches == [
            CodexRenameConfirmation(
                name: "Fix auth bug",
                threadID: "123E4567-E89B-12D3-A456-426614174000"
            )
        ])
    }

    /// A redraw of the same confirmation is dropped because its submission was
    /// already consumed, not because the detector remembers what it last saw.
    /// Suppressing at the detector would also swallow a genuine second
    /// `/rename` to the same name, which is indistinguishable byte-for-byte.
    @Test func codexRenameRedrawIsDroppedByTheSubmissionStoreNotTheDetector() {
        var detector = CodexRenameConfirmationDetector()
        let surfaceID = UUID()
        let store = CodexExplicitRenameSubmissionStore()
        let firstChunk = Array("Session renamed to Streaming name. To resume ".utf8)
        let secondChunk = Array(
            ("this session run codex resume, then select Streaming name " +
                "(123E4567-E89B-12D3-A456-426614174000)").utf8
        )
        #expect(firstChunk.withUnsafeBufferPointer { detector.consume($0) }.isEmpty)
        #expect(secondChunk.withUnsafeBufferPointer { detector.consume($0) }.count == 1)

        store.record(surfaceID: surfaceID, name: "Streaming name", now: 100)
        #expect(store.consumeMatching(surfaceID: surfaceID, name: "Streaming name", now: 101))

        let redraw = Array(
            ("Session renamed to Streaming name. To resume this session run " +
                "codex resume, then select Streaming name " +
                "(123E4567-E89B-12D3-A456-426614174000)").utf8
        )
        #expect(redraw.withUnsafeBufferPointer { detector.consume($0) }.count == 1)
        #expect(!store.consumeMatching(surfaceID: surfaceID, name: "Streaming name", now: 102))
    }

    /// The resume marker and the thread ID it anchors can arrive in different
    /// PTY chunks — the tee sees whatever write sizes the kernel hands it.
    /// Marker detection is incremental but extraction also needs the trailing
    /// thread ID, so the marker must stay armed until extraction actually
    /// consumes it. A one-shot flag cleared on the first attempt loses the
    /// confirmation permanently, and every later chunk returns nothing.
    @Test func markerChunkWithoutThreadIdStillConfirmsWhenTheIdArrives() {
        var detector = CodexRenameConfirmationDetector()
        let markerChunk = Array(
            "Session renamed to Split name. To resume this session run ".utf8
        )
        let threadChunk = Array(
            ("codex resume, then select Split name " +
                "(123E4567-E89B-12D3-A456-426614174000)").utf8
        )
        #expect(markerChunk.withUnsafeBufferPointer { detector.consume($0) }.isEmpty)
        #expect(threadChunk.withUnsafeBufferPointer { detector.consume($0) } == [
            CodexRenameConfirmation(
                name: "Split name",
                threadID: "123E4567-E89B-12D3-A456-426614174000"
            )
        ])
    }

    /// After a direct cmux name is cleared, renaming to the name Codex already
    /// carries must still reach cmux. The confirmation bytes are identical to
    /// the earlier one, so only the fresh submission distinguishes them.
    @Test func repeatedSameNameRenameLandsAfterDirectCmuxNameIsCleared() {
        var detector = CodexRenameConfirmationDetector()
        let surfaceID = UUID()
        let store = CodexExplicitRenameSubmissionStore()
        let confirmation = Array(
            ("Session renamed to Same name. To resume this session run " +
                "codex resume, then select Same name " +
                "(123E4567-E89B-12D3-A456-426614174000)").utf8
        )

        store.record(surfaceID: surfaceID, name: "Same name", now: 100)
        #expect(confirmation.withUnsafeBufferPointer { detector.consume($0) }.count == 1)
        #expect(store.consumeMatching(surfaceID: surfaceID, name: "Same name", now: 101))

        store.record(surfaceID: surfaceID, name: "Same name", now: 200)
        #expect(confirmation.withUnsafeBufferPointer { detector.consume($0) }.count == 1)
        #expect(store.consumeMatching(surfaceID: surfaceID, name: "Same name", now: 201))
    }

    @Test func codexRenameSubmissionRequiresExactCommandAndMatchingConfirmation() {
        let surfaceID = UUID()
        let store = CodexExplicitRenameSubmissionStore()

        #expect(CodexExplicitRenameSubmissionStore.explicitRenameName(
            in: "› /rename   Fix auth bug  "
        ) == "Fix auth bug")
        #expect(CodexExplicitRenameSubmissionStore.explicitRenameName(
            in: "› explain /rename behavior"
        ) == nil)
        #expect(CodexExplicitRenameSubmissionStore.explicitRenameName(
            in: "› /rename"
        ) == nil)

        store.record(surfaceID: surfaceID, name: "Fix   auth bug", now: 100)
        #expect(!store.consumeMatching(surfaceID: surfaceID, name: "Automatic", now: 101))
        #expect(store.consumeMatching(surfaceID: surfaceID, name: "Fix auth bug", now: 101))
        #expect(!store.consumeMatching(surfaceID: surfaceID, name: "Fix auth bug", now: 101))
    }

    @Test func codexRenameSubmissionExpiresBeforeLateConfirmation() {
        let surfaceID = UUID()
        let store = CodexExplicitRenameSubmissionStore()
        store.record(surfaceID: surfaceID, name: "Fix auth bug", now: 100)
        #expect(!store.consumeMatching(surfaceID: surfaceID, name: "Fix auth bug", now: 131))
    }

    @Test func clearingUserTitleRevertsToProcessTitleAndAllowsAutoWrite() {
        let workspace = Workspace(title: "Terminal")
        workspace.applyProcessTitle("zsh")
        workspace.setCustomTitle("My Project")
        workspace.setCustomTitle(nil)
        #expect(workspace.title == "zsh")
        #expect(workspace.customTitle == nil)
        #expect(workspace.effectiveCustomTitleSource == nil)
        #expect(workspace.setCustomTitle("Fix auth bug", source: .auto))
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func carriedTitleWithoutProvenanceIsTreatedAsUserOwned() {
        let workspace = Workspace(title: "Terminal")
        // Simulate a custom title that arrived without provenance (legacy
        // restore, carried panel move): direct assignment bypasses the setter.
        workspace.customTitle = "Carried Title"
        #expect(workspace.effectiveCustomTitleSource == .user)
        #expect(!workspace.setCustomTitle("Fix auth bug", source: .auto))
        #expect(workspace.customTitle == "Carried Title")
    }

    // MARK: - Panel titles

    @Test func panelProvenanceMirrorsWorkspaceRules() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Fix auth bug", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Fix auth bug")
        #expect(workspace.panelCustomTitleSources[panelId] == .auto)

        // User rename wins and claims ownership.
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Build Pane"))
        #expect(workspace.panelCustomTitleSources[panelId] == .user)
        #expect(!workspace.setPanelCustomTitle(panelId: panelId, title: "Other", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Build Pane")

        // Clearing resets provenance and re-opens the panel to auto naming.
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: nil))
        #expect(workspace.panelCustomTitles[panelId] == nil)
        #expect(workspace.panelCustomTitleSources[panelId] == nil)
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Refreshed", source: .auto))
        #expect(workspace.panelCustomTitleSources[panelId] == .auto)
    }

    /// The PTY tee hands the Codex rename handler a *terminal surface* UUID,
    /// and the handler resolves the hosting panel from it. `TerminalPanel`
    /// adopts its surface's id at init, so the resolution is identity for a
    /// live panel — and it must not route through the bonsplit tab-id map,
    /// which keys a different id space and answers `nil` for every terminal
    /// surface UUID. That wrong-space lookup rejected a fully proven rename
    /// with `no_panel_for_surface` live on 2026-08-01.
    /// Asserted from `surface.id` rather than `panel.id` deliberately: the id
    /// the tee actually passes is the surface's, and the two being equal is the
    /// invariant under test, not a premise. Asserting a `panel.id` round trip
    /// would stay green if `TerminalPanel.init` ever stopped adopting
    /// `surface.id` — the exact way this resolution breaks.
    @Test func terminalSurfaceUUIDResolvesItsHostingPanel() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newTerminalSurface(inPane: pane, focus: true))

        #expect(workspace.panelIdHostingTerminalSurface(panel.surface.id) == panel.id)
        #expect(workspace.panelIdHostingTerminalSurface(UUID()) == nil)

        // A registered non-terminal panel must not resolve, or the terminal
        // guard is decoration: without this the guard can be weakened to a
        // bare presence check and every assertion above still passes.
        let browser = try #require(workspace.newBrowserSurface(
            inPane: pane,
            url: URL(string: "https://example.com"),
            focus: false
        ))
        #expect(workspace.panels[browser.id] != nil)
        #expect(workspace.panelIdHostingTerminalSurface(browser.id) == nil)
    }

    @Test func panelCodexRenameHasIndependentDirectCmuxOwnership() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        #expect(workspace.setPanelCustomTitle(
            panelId: panelId,
            title: "Explicit Codex name",
            source: .agentSession
        ))
        #expect(workspace.panelCustomTitleSources[panelId] == .agentSession)

        #expect(workspace.setPanelCustomTitle(
            panelId: panelId,
            title: "Explicit Codex name",
            source: .auto
        ) == false)

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Direct cmux tab"))
        #expect(!workspace.setPanelCustomTitle(
            panelId: panelId,
            title: "Later Codex name",
            source: .agentSession
        ))
        #expect(workspace.panelCustomTitles[panelId] == "Direct cmux tab")

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: nil))
        #expect(workspace.setPanelCustomTitle(
            panelId: panelId,
            title: "Codex after clear",
            source: .agentSession
        ))
        #expect(workspace.panelCustomTitles[panelId] == "Codex after clear")
    }

    /// A rename proven by a session that does not own the workspace updates its
    /// own tab and leaves the workspace name alone, so a sibling Codex session
    /// or a Teams subagent cannot relabel work it does not represent.
    @Test func surfaceScopedCodexRenameLeavesWorkspaceTitleUnchanged() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.applyProcessTitle("zsh")

        let result = workspace.applyCodexSessionName(
            "Sibling Codex name",
            panelId: panelId,
            workspaceEligible: false
        )

        #expect(!result.workspaceApplied)
        #expect(result.panelApplied == true)
        #expect(workspace.customTitle == nil)
        #expect(workspace.title == "zsh")
        #expect(workspace.panelCustomTitles[panelId] == "Sibling Codex name")
    }

    /// A rename changes names and nothing else.
    ///
    /// The riskiest routing case is renaming a panel that is *not* focused: a
    /// title write that reaches for the panel through selection rather than by
    /// id would silently move focus to the renamed tab, and the user's cursor
    /// would jump mid-typing. Codex renames are also the one title path that
    /// fires while the user is actively working in another pane.
    ///
    /// Unread and notification state live on `AppDelegate.shared.notificationStore`,
    /// which no unit test has, so asserting them here would compare nil to nil.
    /// That half of the scenario stays a dogfood check.
    @Test func codexRenameLeavesSelectionAndFocusUnchanged() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let renamedPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        let focusedPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        let selectedTabIdBefore = manager.selectedTabId
        let focusedPanelIdBefore = workspace.focusedPanelId
        let focusedPaneIdBefore = workspace.bonsplitController.focusedPaneId
        let orderedPanelIdsBefore = workspace.orderedPanelIds
        #expect(focusedPanelIdBefore == focusedPanelId)
        #expect(focusedPanelIdBefore != renamedPanelId)

        let result = workspace.applyCodexSessionName(
            "Renamed while elsewhere",
            panelId: renamedPanelId,
            workspaceEligible: true
        )

        #expect(result.workspaceApplied)
        #expect(result.panelApplied == true)
        #expect(workspace.panelCustomTitles[renamedPanelId] == "Renamed while elsewhere")
        #expect(manager.selectedTabId == selectedTabIdBefore)
        #expect(workspace.focusedPanelId == focusedPanelIdBefore)
        #expect(workspace.bonsplitController.focusedPaneId == focusedPaneIdBefore)
        #expect(workspace.orderedPanelIds == orderedPanelIdsBefore)
    }

    /// The sole live agent session in a workspace still names both targets.
    @Test func workspaceEligibleCodexRenameNamesBothTargets() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        let result = workspace.applyCodexSessionName(
            "Only Codex name",
            panelId: panelId,
            workspaceEligible: true
        )

        #expect(result.workspaceApplied)
        #expect(result.panelApplied == true)
        #expect(workspace.customTitle == "Only Codex name")
        #expect(workspace.effectiveCustomTitleSource == .agentSession)
        #expect(workspace.panelCustomTitles[panelId] == "Only Codex name")
    }

    /// An empty agent write leaves the agent's own name standing.
    ///
    /// Codex offers no way to clear a thread name — a bare `/rename` opens a
    /// prompt pre-filled with the current name (Codex 0.146.0, verified
    /// 2026-07-31) — so nothing legitimate produces an agent clear. An empty
    /// name reaching here is a malformed or truncated update, and wiping the
    /// title the user is reading is the worse answer.
    @Test func codexEmptyNameLeavesAgentSessionTitleStanding() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.applyProcessTitle("zsh")
        workspace.applyCodexSessionName("Codex name", panelId: panelId, workspaceEligible: true)

        let result = workspace.applyCodexSessionName(
            nil,
            panelId: panelId,
            workspaceEligible: true
        )

        #expect(!result.workspaceApplied)
        #expect(result.panelApplied == false)
        #expect(workspace.customTitle == "Codex name")
        #expect(workspace.effectiveCustomTitleSource == .agentSession)
        #expect(workspace.panelCustomTitles[panelId] == "Codex name")
    }

    /// An empty agent write never reaches a name the user set directly in cmux.
    @Test func codexEmptyNameLeavesDirectCmuxNamesIntact() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.setCustomTitle("Keep workspace name")
        workspace.setPanelCustomTitle(panelId: panelId, title: "Keep tab name")

        let result = workspace.applyCodexSessionName(
            nil,
            panelId: panelId,
            workspaceEligible: true
        )

        #expect(!result.workspaceApplied)
        #expect(result.panelApplied == false)
        #expect(workspace.customTitle == "Keep workspace name")
        #expect(workspace.panelCustomTitles[panelId] == "Keep tab name")
    }

    /// An automatic name cannot clear a title an explicit rename owns.
    @Test func autoSourceCannotClearAgentSessionTitle() {
        let workspace = Workspace(title: "Terminal")
        workspace.applyProcessTitle("zsh")
        #expect(workspace.setCustomTitle("Codex name", source: .agentSession))
        #expect(!workspace.setCustomTitle(nil, source: .auto))
        #expect(workspace.customTitle == "Codex name")
    }

    @Test func panelCodexRenameClaimsMatchingAutomaticText() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        #expect(workspace.setPanelCustomTitle(
            panelId: panelId,
            title: "Same name",
            source: .auto
        ))
        #expect(workspace.setPanelCustomTitle(
            panelId: panelId,
            title: "Same name",
            source: .agentSession
        ))
        #expect(workspace.panelCustomTitleSources[panelId] == .agentSession)
    }

    @Test func panelAutoWriteRejectedForCarriedTitleWithoutProvenance() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        // Simulate a carried title (move/respawn flows write the dictionary
        // directly when no provenance traveled with the title).
        workspace.panelCustomTitles[panelId] = "Carried Tab"
        #expect(!workspace.setPanelCustomTitle(panelId: panelId, title: "Other", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Carried Tab")
    }

    // MARK: - Snapshot round-trip

    @Test func workspaceSnapshotPersistsAgentAuthorityWithLegacySource() {
        let workspace = Workspace(title: "Terminal")
        #expect(workspace.setCustomTitle("Explicit Codex name", source: .agentSession))
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.customTitleSource == .auto)
        #expect(snapshot.customTitleAuthority == .agentSession)
    }

    @Test func workspaceSnapshotRoundTripPreservesProvenance() throws {
        var snapshot = SessionWorkspaceSnapshot(
            processTitle: "zsh",
            customTitle: "Fix auth bug",
            customTitleSource: .auto,
            customTitleAuthority: .agentSession,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let encodedObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(encodedObject["customTitleSource"] as? String == "auto")
        #expect(encodedObject["customTitleAuthority"] as? String == "agentSession")

        let decoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: encoded
        )
        #expect(decoded.customTitleSource == .auto)
        #expect(decoded.customTitleAuthority == .agentSession)
        let currentWorkspace = Workspace(title: "Terminal")
        currentWorkspace.setCustomTitle(
            decoded.customTitle,
            source: decoded.customTitleAuthority ?? decoded.customTitleSource ?? .user
        )
        #expect(currentWorkspace.effectiveCustomTitleSource == .agentSession)

        // Legacy shape: encoding a nil source omits the key, which is exactly
        // what snapshots persisted before provenance look like on disk.
        snapshot.customTitleSource = nil
        snapshot.customTitleAuthority = nil
        let legacyDecoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(legacyDecoded.customTitleSource == nil)

        // Restore semantics: absent provenance restores as user-owned.
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle(legacyDecoded.customTitle, source: legacyDecoded.customTitleSource ?? .user)
        #expect(workspace.effectiveCustomTitleSource == .user)
    }
}
