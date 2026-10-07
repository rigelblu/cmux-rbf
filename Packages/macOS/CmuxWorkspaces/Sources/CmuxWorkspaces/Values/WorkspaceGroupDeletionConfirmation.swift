public import Foundation

/// Current workspace-group membership used to confirm destructive group deletion.
public struct WorkspaceGroupDeletionConfirmation: Equatable, Sendable {
    /// The group's stable identity.
    public let groupId: UUID
    /// The group's current display name.
    public let groupName: String
    /// The stable identity represented by the group header. For an empty group
    /// this is a placeholder id and `memberWorkspaceIds` is empty.
    public let anchorWorkspaceId: UUID
    /// Whether ``memberWorkspaceIds`` includes the anchor workspace.
    public let includesAnchorWorkspace: Bool
    /// Workspace identifiers that destructive deletion will close, in window order.
    public let memberWorkspaceIds: [UUID]
    /// The groups inside the group, at every level, parent before child (#cm-106). Empty in a flat window.
    public let containedGroupIds: [UUID]
    /// Whether the window held a nested group when this was taken (#cm-106). Such a confirmation is always
    /// pressed through the nested delete, even if the window has gone flat since.
    let takenInNestedWindow: Bool
    /// Whether this was taken on a rendered header whose group record was already gone (#cm-106). Upstream's
    /// press closes the header's workspace, in a nested window as in a flat one.
    let forStaleHeader: Bool

    /// Number of workspaces that destructive deletion would close.
    public var memberCount: Int { memberWorkspaceIds.count }

    /// Number of child workspaces inside the group, excluding the group header workspace.
    public var containedWorkspaceCount: Int {
        max(memberWorkspaceIds.count - (includesAnchorWorkspace ? 1 : 0), 0)
    }

    /// Number of groups inside the group, at every level (#cm-106).
    public var containedGroupCount: Int { containedGroupIds.count }

    init(
        groupId: UUID,
        groupName: String,
        anchorWorkspaceId: UUID,
        includesAnchorWorkspace: Bool,
        memberWorkspaceIds: [UUID],
        containedGroupIds: [UUID] = [], // (#cm-106)
        takenInNestedWindow: Bool = false, // (#cm-106)
        forStaleHeader: Bool = false // (#cm-106)
    ) {
        self.groupId = groupId
        self.groupName = groupName
        self.anchorWorkspaceId = anchorWorkspaceId
        self.includesAnchorWorkspace = includesAnchorWorkspace
        self.memberWorkspaceIds = memberWorkspaceIds
        self.containedGroupIds = containedGroupIds // (#cm-106)
        self.takenInNestedWindow = takenInNestedWindow // (#cm-106)
        self.forStaleHeader = forStaleHeader // (#cm-106)
    }
}
