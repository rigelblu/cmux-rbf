import AppKit
import CmuxNotifications
import CmuxSidebar
import CmuxWorkspaces
@_spi(CmuxHostTransport) import CmuxExtensionKit
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarWorkspaceSnapshotRefreshPolicyTests {
    @Test @MainActor
    func extensionSnapshotCacheDoesNotInflateSequenceForIdenticalProviderContent() throws {
        let workspaceID = UUID()
        let initial = CmuxSidebarSnapshot(
            sequence: 10,
            selectedWorkspaceID: workspaceID,
            workspaces: [CmuxSidebarWorkspace(id: workspaceID, title: "Pi")]
        )
        let cache = CMUXSidebarSnapshotCache()
        _ = cache.replace(with: initial)
        let unread = SidebarUnreadSnapshot(
            totalUnreadCount: 1,
            summaryByWorkspaceId: [
                workspaceID: SidebarWorkspaceUnreadSummary(
                    unreadCount: 1,
                    latestNotificationText: "Done"
                ),
            ]
        )
        let patched = try #require(cache.applyUnread(unread))
        let matchingProvider = CmuxSidebarSnapshot(
            sequence: 10,
            selectedWorkspaceID: workspaceID,
            workspaces: [
                CmuxSidebarWorkspace(
                    id: workspaceID,
                    title: "Pi",
                    unreadCount: 1,
                    latestNotification: "Done"
                ),
            ]
        )

        let firstPoll = cache.replace(with: matchingProvider)
        let secondPoll = cache.replace(with: matchingProvider)

        #expect(firstPoll.sequence == patched.sequence)
        #expect(secondPoll.sequence == patched.sequence)

        let changedProvider = CmuxSidebarSnapshot(
            sequence: 10,
            selectedWorkspaceID: workspaceID,
            workspaces: [
                CmuxSidebarWorkspace(
                    id: workspaceID,
                    title: "Pi renamed",
                    unreadCount: 1,
                    latestNotification: "Done"
                ),
            ]
        )
        let changedPoll = cache.replace(with: changedProvider)
        #expect(changedPoll.sequence == patched.sequence + 1)
        #expect(changedPoll.workspaces.first?.title == "Pi renamed")
    }

    @Test func contextMenuPinChangeUpdatesDisplayedFieldsAndDefersNoisyFields() {
        let current = Self.snapshot(
            title: "lmao",
            isPinned: false,
            customColorHex: nil,
            remoteConnectionStatusText: "Connected",
            latestConversationMessage: "old message",
            listeningPorts: [3000],
            finderDirectoryPath: "/old"
        )
        let next = Self.snapshot(
            title: "lmao",
            isPinned: true,
            customColorHex: nil,
            remoteConnectionStatusText: "Disconnected",
            latestConversationMessage: "new message",
            listeningPorts: [3000, 4000],
            finderDirectoryPath: nil
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        var expectedDisplayed = current
        expectedDisplayed = expectedDisplayed.applyingContextMenuImmediateFields(from: next)
        #expect(decision.workspaceSnapshotStorage == expectedDisplayed)
        #expect(decision.workspaceSnapshotStorage?.isPinned == true)
        #expect(decision.workspaceSnapshotStorage?.remoteConnectionStatusText == "Connected")
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.workspaceSnapshotStorage?.listeningPorts == [3000])
        #expect(decision.workspaceSnapshotStorage?.finderDirectoryPath == nil)
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }
    @Test func contextMenuImmediateOnlyChangeDoesNotCreateDeferredFlush() {
        let current = Self.snapshot(
            title: "old",
            customDescription: nil,
            isPinned: false,
            customColorHex: nil,
            finderDirectoryPath: nil
        )
        let next = Self.snapshot(
            title: "new",
            customDescription: "description",
            isPinned: true,
            customColorHex: "#C0392B",
            finderDirectoryPath: "/tmp/workspace"
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage == next)
        #expect(decision.pendingWorkspaceSnapshot == nil)
        #expect(!decision.hasDeferredWorkspaceObservationInvalidation)
    }
    @Test func contextMenuMediaActivityChangeUpdatesDisplayedGlyphImmediately() {
        let current = Self.snapshot(
            remoteConnectionStatusText: "Connected",
            latestConversationMessage: "old message",
            listeningPorts: [3000],
            mediaActivity: BrowserMediaActivity(isPlayingAudio: true)
        )
        let next = Self.snapshot(
            remoteConnectionStatusText: "Disconnected",
            latestConversationMessage: "new message",
            listeningPorts: [3000, 4000],
            mediaActivity: BrowserMediaActivity(isPlayingAudio: false)
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.mediaActivity.isPlayingAudio == false)
        #expect(decision.workspaceSnapshotStorage?.remoteConnectionStatusText == "Connected")
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.workspaceSnapshotStorage?.listeningPorts == [3000])
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }
    @Test func contextMenuAttentionLaneChangeUpdatesStripSuppressionImmediately() {
        // Parking a workspace happens THROUGH the context menu (Status submenu),
        // so the strip suppression lane must update while the menu is still
        // open; if it fell out of ContextMenuImmediateFields the strip would
        // silently linger until menu dismiss.
        let current = Self.snapshot(
            remoteConnectionStatusText: "Connected",
            latestConversationMessage: "old message",
            listeningPorts: [3000],
            attentionTaskStatus: .working
        )
        let next = Self.snapshot(
            remoteConnectionStatusText: "Disconnected",
            latestConversationMessage: "new message",
            listeningPorts: [3000, 4000],
            attentionTaskStatus: .todo
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.attentionTaskStatus == .todo)
        #expect(decision.workspaceSnapshotStorage?.remoteConnectionStatusText == "Connected")
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.workspaceSnapshotStorage?.listeningPorts == [3000])
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }
    @Test func agentWaitingChangeAppliesImmediatelyWhileContextMenuIsOpen() {
        let current = Self.snapshot(
            remoteConnectionStatusText: "Connected",
            latestConversationMessage: "old message",
            listeningPorts: [3000],
            showsRaisedHand: false
        )
        let next = Self.snapshot(
            remoteConnectionStatusText: "Disconnected",
            latestConversationMessage: "new message",
            listeningPorts: [3000, 4000],
            showsRaisedHand: true
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.showsRaisedHand == true)
        #expect(decision.workspaceSnapshotStorage?.remoteConnectionStatusText == "Connected")
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.workspaceSnapshotStorage?.listeningPorts == [3000])
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    /// cm-128.5: the triangle is a leading row glyph like the hand, so an error appearing applies at once with the menu open.
    @Test func agentErrorChangeAppliesImmediatelyWhileContextMenuIsOpen() {
        let current = Self.snapshot(listeningPorts: [3000])
        let next = Self.snapshot(
            listeningPorts: [3000, 4000],
            errors: [SidebarAgentStateEntry(statusKey: "claude_code", displayName: "Claude Code", paneCount: 1, usageLimit: true)] // cmux-rbf: changed on purpose (#cm-128.6)
        )
        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current, next: next, force: false, contextMenuVisible: true)
        #expect(decision.workspaceSnapshotStorage?.agentLists.error == next.agentLists.error, // cmux-rbf: changed on purpose (#cm-128.6)
                "stored \(String(describing: decision.workspaceSnapshotStorage?.agentLists.error))")
        #expect(decision.workspaceSnapshotStorage?.listeningPorts == [3000], "control: telemetry stays frozen")
    }

    @Test func closedContextMenuStoresNextAndClearsPending() {
        let current = Self.snapshot(title: "old", isPinned: false)
        let next = Self.snapshot(title: "new", isPinned: true)

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: false
        )

        #expect(decision.workspaceSnapshotStorage == next)
        #expect(decision.pendingWorkspaceSnapshot == nil)
        #expect(!decision.hasDeferredWorkspaceObservationInvalidation)
    }

    static func snapshot(
        presentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey? = nil,
        title: String = "workspace",
        customDescription: String? = nil,
        isPinned: Bool = false,
        customColorHex: String? = nil,
        remoteConnectionStatusText: String = "Disconnected",
        latestConversationMessage: String? = nil,
        listeningPorts: [Int] = [],
        finderDirectoryPath: String? = nil,
        mediaActivity: BrowserMediaActivity = BrowserMediaActivity(),
        activeCodingAgentCount: Int = 0,
        attentionTaskStatus: WorkspaceTaskStatus? = nil,
        showsRaisedHand: Bool = false,
        monitoringAgentCount: Int = 0, // (cm-128.6)
        errors: [SidebarAgentStateEntry] = [],
        taskStatus: WorkspaceTaskStatus? = nil
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        var s = SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: presentationKey ?? Self.presentationKey(),
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            isMuted: false,
            customColorHex: customColorHex,
            cloudWorkspaceLabel: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: latestConversationMessage,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: listeningPorts,
            finderDirectoryPath: finderDirectoryPath,
            mediaActivity: mediaActivity,
            taskStatus: taskStatus,
            todoStatusMenuModel: nil,
            hasManualTaskStatus: false,
            attentionTaskStatus: attentionTaskStatus,
            checklistItems: [],
            checklistCompletedCount: 0,
            checklistTotalCount: 0,
            checklistFirstUncheckedText: nil
        )
        // cmux-rbf: changed on purpose (#cm-128.6): the three old fields are computed from the lists, so the counts become the lists they mean.
        s.agentLists = Self.lists(waiting: showsRaisedHand ? 1 : 0, running: activeCodingAgentCount,
                                  monitoring: monitoringAgentCount, errors: errors)
        return s
    }

    /// cm-128.6: the lists a fixture means by counts: one nameless entry for waiting and for running, Claude Code for
    /// monitoring (no nameless agent can monitor), and the given error entries.
    static func lists(waiting: Int = 0, running: Int = 0, monitoring: Int = 0,
                      errors: [SidebarAgentStateEntry] = []) -> SidebarAgentStateLists {
        func nameless(_ count: Int) -> [SidebarAgentStateEntry] {
            count > 0 ? [SidebarAgentStateEntry(statusKey: "", displayName: nil, paneCount: count, usageLimit: false)] : []
        }
        return SidebarAgentStateLists(
            waiting: nameless(waiting), error: errors, running: nameless(running),
            monitoring: monitoring > 0
                ? [SidebarAgentStateEntry(statusKey: "claude_code", displayName: "Claude Code", paneCount: monitoring, usageLimit: false)]
                : [])
    }

    static func presentationKey(
        showsWorkspaceDescription: Bool = true,
        usesVerticalBranchLayout: Bool = true,
        showsGitBranch: Bool = true,
        usesViewportAwarePath: Bool = false,
        showsAgentActivity: Bool = true,
        visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility = SidebarWorkspaceAuxiliaryDetailVisibility(
            showsMetadata: true,
            showsLog: true,
            showsProgress: true,
            showsBranchDirectory: true,
            showsPullRequests: true,
            showsPorts: true
        )
    ) -> SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: showsWorkspaceDescription,
            usesVerticalBranchLayout: usesVerticalBranchLayout,
            showsGitBranch: showsGitBranch,
            usesViewportAwarePath: usesViewportAwarePath,
            showsAgentActivity: showsAgentActivity,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails
        )
    }
}

@Suite struct SidebarSelectedWorkspaceScrollPolicyTests {
    @Test func skipsScrollWhenSelectedWorkspaceIdIsNil() {
        #expect(!SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: nil as String?,
            oldWorkspaceIds: ["a"],
            newWorkspaceIds: ["a"]
        ))
    }

    @Test func requestsScrollWhenSelectedWorkspaceFirstAppears() {
        #expect(SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "b",
            oldWorkspaceIds: ["a"],
            newWorkspaceIds: ["a", "b"]
        ))
    }

    @Test func requestsScrollWhenSelectedWorkspaceMovesToTop() {
        #expect(SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "c",
            oldWorkspaceIds: ["a", "b", "c"],
            newWorkspaceIds: ["c", "a", "b"]
        ))
    }

    @Test func requestsScrollWhenAnotherReorderShiftsSelectedWorkspaceIndex() {
        #expect(SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "b",
            oldWorkspaceIds: ["a", "b", "c"],
            newWorkspaceIds: ["c", "a", "b"]
        ))
    }

    @Test func skipsScrollWhenWorkspaceBeforeSelectedWorkspaceCloses() {
        #expect(!SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(selectedWorkspaceId: "d", oldWorkspaceIds: ["a", "b", "c", "d"], newWorkspaceIds: ["a", "c", "d"]))
    }
    @Test func skipsScrollWhenReorderLeavesSelectedWorkspaceIndexUnchanged() {
        #expect(!SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "a",
            oldWorkspaceIds: ["a", "b", "c"],
            newWorkspaceIds: ["a", "c", "b"]
        ))
    }

    @Test func skipsScrollWhenSelectedWorkspaceIsMissing() {
        #expect(!SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: "b",
            oldWorkspaceIds: ["a", "b"],
            newWorkspaceIds: ["a", "c"]
        ))
    }

    @Test func scrollTargetIsSelfWithoutGroup() {
        let workspaceId = UUID()
        #expect(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: workspaceId,
            group: nil
        ) == workspaceId)
    }

    @Test func scrollTargetIsSelfInExpandedGroup() {
        let workspaceId = UUID()
        #expect(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: workspaceId,
            group: makeGroup(isCollapsed: false, anchorWorkspaceId: UUID())
        ) == workspaceId)
    }

    @Test func scrollTargetIsGroupAnchorWhenGroupIsCollapsed() {
        let anchorId = UUID()
        #expect(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: UUID(),
            group: makeGroup(isCollapsed: true, anchorWorkspaceId: anchorId)
        ) == anchorId)
    }

    private func makeGroup(isCollapsed: Bool, anchorWorkspaceId: UUID) -> WorkspaceGroup {
        WorkspaceGroup(
            id: UUID(),
            name: "group",
            isCollapsed: isCollapsed,
            isPinned: false,
            anchorWorkspaceId: anchorWorkspaceId,
            customColor: nil,
            iconSymbol: nil
        )
    }
}
