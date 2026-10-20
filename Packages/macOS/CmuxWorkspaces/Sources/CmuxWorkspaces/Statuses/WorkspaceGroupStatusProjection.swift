public import Foundation

/// Places entire top-level unpinned workspace groups by their own stored status, never by color.
/// Descendants inherit the root's placement while retaining their own independent status values.
public struct WorkspaceGroupStatusProjection: Equatable, Sendable {
    /// The containing status group for each projected group header, including nested headers.
    public let statusIdByGroupId: [UUID: String]
    /// The containing status group for every workspace inside a projected root, including its anchor.
    /// These are not loose status-group members and must not use the loose-workspace drop path.
    public let statusIdByWorkspaceId: [UUID: String]
    /// Display depths including the Statuses area and status header, keyed by group or workspace identity.
    public let depthById: [UUID: Int]

    /// Resolves the group's placement without modifying model order or fold state.
    /// - Parameters:
    ///   - groups: The window's group values.
    ///   - workspaces: Workspace membership in tab order, including anchors.
    ///   - list: The active status list; only listed statuses have a status group.
    public init(groups: [WorkspaceGroup], workspaces: [WorkspaceGroupWorkspaceItem] = [], list: WorkspaceStatusList) {
        let tree = WorkspaceGroupTree(groups: groups)
        let listed = Set(list.entries.map(\.id))
        var roots: [UUID: String] = [:]
        if list.source != .cmux {
            for group in groups where tree.parent(of: group.id) == nil && !group.isPinned {
                if let status = group.statusId, listed.contains(status) { roots[group.id] = status }
            }
        }
        var groupStatuses: [UUID: String] = [:]
        var workspaceStatuses: [UUID: String] = [:]
        var depths: [UUID: Int] = [:]
        for group in groups {
            guard let status = roots[tree.outermost(of: group.id)] else { continue }
            groupStatuses[group.id] = status
            depths[group.id] = tree.depth(of: group.id) + 2
        }
        for workspace in workspaces {
            guard let groupId = workspace.groupId, let status = groupStatuses[groupId] else { continue }
            workspaceStatuses[workspace.id] = status
            depths[workspace.id] = tree.depth(of: groupId) + 3
        }
        statusIdByGroupId = groupStatuses
        statusIdByWorkspaceId = workspaceStatuses
        depthById = depths
    }
}
