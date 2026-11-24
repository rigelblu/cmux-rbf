import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Workspace sidebar snapshot value types extracted from `ContentView.swift`, which sits at its file-length budget.
struct SidebarWorkspaceSnapshotBuilder {
    struct PresentationKey: Equatable {
        let showsWorkspaceDescription: Bool
        let usesVerticalBranchLayout: Bool
        let showsGitBranch: Bool
        let usesViewportAwarePath: Bool
        let showsAgentActivity: Bool
        var compactsAgentStatus = false
        var compactStatusIcons: [String: String] = [:]
        let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
        // Effective row color (manual color, else resolved origin color). Part of
        // the key so the cached snapshot is rebuilt when the color changes — e.g.
        // toggling the origin-colors flag or a mirror host resolving after appear,
        // neither of which is a Workspace @Published change that would otherwise
        // refresh the snapshot.
        let customColorHex: String?
        // Clear Color availability can change without changing the rendered color.
        var hasManualCustomColor = false
        // Host named after a colliding title (beta). Part of the key because it depends on the other
        // workspaces' titles, so a rename elsewhere must rebuild this row's cached snapshot.
        var hostTitleSuffix: String? = nil
    }

    struct VerticalBranchDirectoryLine: Equatable {
        let branch: String?
        // Ordered longest → shortest. Empty means no directory to show.
        // First element is the canonical display string when only one is needed.
        let directoryCandidates: [String]

        var directory: String? { directoryCandidates.first }
    }

    struct PullRequestDisplay: Identifiable, Equatable {
        let id: String
        let number: Int
        let label: String
        let url: URL
        let status: SidebarPullRequestStatus
        let isStale: Bool
    }

    struct Snapshot: Equatable {
        let presentationKey: PresentationKey
        let title: String
        let customDescription: String?
        let isPinned: Bool
        /// Whether any workspace-scoped notification mute is active.
        let isMuted: Bool
        // Effective row color: the manually chosen workspace color, else the
        // per-host origin color when that beta flag is on. Rendering reads this;
        // affordances that only make sense for a manual color (Clear Color)
        // check `hasManualCustomColor` instead.
        let customColorHex: String?
        let hasManualCustomColor: Bool
        /// Stable Cloud identity, independent of connection status and detail visibility.
        let cloudWorkspaceLabel: String?
        let remoteWorkspaceSidebarText: String?
        let remoteConnectionStatusText: String
        let remoteStateHelpText: String
        let showsRemoteReconnectAffordance: Bool
        let copyableSidebarSSHError: String?
        let latestConversationMessage: String?
        let metadataEntries: [SidebarStatusEntry]
        let metadataBlocks: [SidebarMetadataBlock]
        let latestLog: SidebarLogEntry?
        let progress: SidebarProgressState?
        let compactGitBranchSummaryText: String?
        let compactDirectoryCandidates: [String]
        let compactBranchDirectoryCandidates: [String]
        let branchDirectoryLines: [VerticalBranchDirectoryLine]
        let branchLinesContainBranch: Bool
        let pullRequestRows: [PullRequestDisplay]
        let listeningPorts: [Int]
        let finderDirectoryPath: String?
        let mediaActivity: BrowserMediaActivity
        // Workspace todo status/checklist; taskStatus is nil when the
        // workspace opted out of status display or the remote todo-controls
        // flag is off. Manual status draws a compact row indicator, while
        // automatic status drives the done-row dim — and, through
        // `attentionTaskStatus` below, the Accent Strip suppression.
        let taskStatus: WorkspaceTaskStatus?
        let todoStatusMenuModel: SidebarWorkspaceCompactStatusMenuModel?
        let hasManualTaskStatus: Bool
        /// The lane `#cm-22`'s Accent Strip suppression reads — the
        /// **effective** lane: the manual override when set, the inference
        /// otherwise. Deliberately ungated on `statusHidden`, unlike
        /// `taskStatus` above, which only exists when the user wants a status
        /// glyph shown.
        let attentionTaskStatus: WorkspaceTaskStatus?
        let checklistItems: [WorkspaceChecklistItem]
        let checklistCompletedCount: Int
        let checklistTotalCount: Int
        let checklistFirstUncheckedText: String?
        var taskStatusInput = SidebarWorkspaceTaskStatusSnapshot()
        /// For each state a mark draws, the agents in it (cm-128.6). The hand, the triangle, the spinner and the waveform
        /// each show when their list is not empty, and the three counts below are computed from it, with no setter, so
        /// production keeps one source. A memberwise init that does not name it gets no agents.
        var agentLists = SidebarAgentStateLists()
        /// Whether the raised hand indicator should show. (#cm-109.3)
        var showsRaisedHand: Bool { agentLists.showsRaisedHand } // (#cm-109.3) cm-128.6: computed from the lists
        /// The spinner's count: running agent panes plus running loaders. (cm-128.6: computed from the lists)
        var activeCodingAgentCount: Int { agentLists.activeCodingAgentCount }
        /// How many agent states are watching background work after their turn ended. (#cm-128.3, cm-128.6: computed)
        var monitoringAgentCount: Int { agentLists.monitoringAgentCount }

        /// One menu decision for both renderers, their popovers, and tests. (#cm-110.13)
        func statusMenuModel(controlsEnabled: Bool) -> SidebarWorkspaceCompactStatusMenuModel? { // (#cm-110.13)
            guard controlsEnabled else { return nil } // (#cm-110.13)
            guard taskStatusInput.isHidden else { return todoStatusMenuModel } // (#cm-110.13)
            guard let picker = taskStatusInput.picker else { return nil } // (#cm-110.13)
            return SidebarWorkspaceCompactStatusMenuModel( // (#cm-110.13)
                inferred: taskStatusInput.inferred, // (#cm-110.13)
                activeOverride: taskStatusInput.activeOverride, // (#cm-110.13)
                picker: picker, // (#cm-110.13)
                colorHexes: taskStatusInput.colorHexes, // (#cm-110.13)
                isNone: true // (#cm-110.13)
            ) // (#cm-110.13)
        } // (#cm-110.13)
        var deviceWorkspaceLabel: String? = nil
        /// The single leading status glyph when `sidebar.compactAgentStatus`
        /// is on (agent status entries then leave `metadataEntries`).
        var compactStatusGlyph: SidebarCompactStatusGlyph? = nil

        var remoteWorkspaceBadgeLabel: String? { deviceWorkspaceLabel ?? cloudWorkspaceLabel }
        var remoteWorkspaceBadgeSymbol: String { deviceWorkspaceLabel == nil ? "cloud" : "desktopcomputer" }

        /// Remote host named after the title when another workspace shares it (beta), else nil.
        var hostTitleSuffix: String? = nil

        /// The title as the row shows it. Renaming and other title affordances keep using `title`.
        var displayTitle: String {
            guard let hostTitleSuffix else { return title }
            let format = String(
                localized: "sidebar.workspace.titleWithHost",
                defaultValue: "%1$@ · %2$@"
            )
            return String(format: format, title, hostTitleSuffix)
        }

        func accessibilityLabel(index: Int, workspaceCount: Int) -> String {
            let positionFormat = String(
                localized: "accessibility.workspacePosition",
                defaultValue: "%1$@, workspace %2$lld of %3$lld"
            )
            let position = String(
                format: positionFormat,
                displayTitle,
                Int64(index + 1),
                Int64(workspaceCount)
            )
            let cloudDirectory = cloudWorkspaceLabel == nil ? nil
                : (compactDirectoryCandidates.first ?? branchDirectoryLines.first?.directory)
            return [position, remoteWorkspaceBadgeLabel, cloudDirectory].compactMap { $0 }.joined(separator: ", ")
        }
    }
}
