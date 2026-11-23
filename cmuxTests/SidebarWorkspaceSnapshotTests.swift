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

@Suite struct SidebarWorkspaceSnapshotTests {
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

    /// cmux-rbf: changed on purpose (#cm-128.6): the fork's fixture parameters stay (fork suites build rows from
    /// them); the counts become the agent lists they mean, since the snapshot computes its three old fields from them.
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
            hasManualCustomColor: false,
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
            checklistFirstUncheckedText: nil,
            compactStatusGlyph: nil
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
        ),
        customColorHex: String? = nil
    ) -> SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: showsWorkspaceDescription,
            usesVerticalBranchLayout: usesVerticalBranchLayout,
            showsGitBranch: showsGitBranch,
            usesViewportAwarePath: usesViewportAwarePath,
            showsAgentActivity: showsAgentActivity,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails,
            customColorHex: customColorHex
        )
    }

    /// The effective row color is part of the presentation key so the cached
    /// sidebar snapshot is rebuilt when the color changes — e.g. toggling the
    /// origin-colors flag or a mirror host resolving after the row first appears.
    /// Without this, the row re-evaluates but renders the stale cached color.
    @Test func presentationKeyDistinguishesEffectiveColor() {
        let uncolored = Self.presentationKey(customColorHex: nil)
        let tinted = Self.presentationKey(customColorHex: "#1565C0")
        #expect(uncolored != tinted)
        #expect(tinted == Self.presentationKey(customColorHex: "#1565C0"))
        #expect(Self.presentationKey(customColorHex: "#922B21") != tinted)
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

/// cmux-rbf: upstream renamed `SidebarWorkspaceSnapshotRefreshPolicyTests` to `SidebarWorkspaceSnapshotTests` when it
/// deleted the refresh policy (40160ee0f4). Fork suites (#cm-109.3, #cm-128.4, #cm-128.6) still build rows through the
/// old name; this keeps them compiling until each is renamed. Reject this hunk once no file says the old name.
typealias SidebarWorkspaceSnapshotRefreshPolicyTests = SidebarWorkspaceSnapshotTests
