public import Foundation

/// Places whole unpinned workspace groups by their own stored status, never by color.
/// A group's root is the outermost group in its chain with its own stored, listed status; everything inside the root
/// follows its placement while keeping its own independent status value. A pinned group keeps itself and everything
/// below it out. // (#cm-110.3) a root may sit inside another group; `cm-110.2` took top-level groups only.
public struct WorkspaceGroupStatusProjection: Equatable, Sendable {
    /// The containing status group for each projected group header, including nested headers.
    public let statusIdByGroupId: [UUID: String]
    /// The containing status group for every workspace inside a projected root, including its anchor.
    /// These are not loose status-group members and must not use the loose-workspace drop path.
    public let statusIdByWorkspaceId: [UUID: String]
    /// Display depths including the Statuses area and status header, keyed by group or workspace identity.
    public let depthById: [UUID: Int]
    /// The root of each projected group: the group that decided where it shows (a root maps to itself). // (#cm-110.3)
    public let rootIdByGroupId: [UUID: UUID]
    /// Every root, top-level or nested. // (#cm-110.3)
    public let rootGroupIds: Set<UUID>
    /// The roots that sit inside another group: the groups the sidebar draws away from their parent. // (#cm-110.3)
    public let nestedRootGroupIds: Set<UUID>

    /// Resolves the group's placement without modifying model order or fold state.
    /// - Parameters:
    ///   - groups: The window's group values.
    ///   - workspaces: Workspace membership in tab order, including anchors.
    ///   - list: The active status list; only listed statuses have a status group.
    public init(groups: [WorkspaceGroup], workspaces: [WorkspaceGroupWorkspaceItem] = [], list: WorkspaceStatusList) {
        let tree = WorkspaceGroupTree(groups: groups)
        let listed = Set(list.entries.map(\.id))
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var roots: [UUID: String] = [:]
        var rootOf: [UUID: UUID] = [:]
        if list.source != .cmux {
            for group in groups {
                // The chain from the top: the first group with its own listed status is the root. A pinned group on
                // the way keeps itself and everything below it out (`Pinned` shows its own glyph and color). // (#cm-110.3)
                for id in tree.ancestors(of: group.id).reversed() + [group.id] {
                    guard let candidate = byId[id], !candidate.isPinned else { break }
                    if let status = candidate.statusId, listed.contains(status) {
                        roots[candidate.id] = status
                        rootOf[group.id] = candidate.id
                        break
                    }
                }
            }
        }
        var groupStatuses: [UUID: String] = [:]
        var workspaceStatuses: [UUID: String] = [:]
        var depths: [UUID: Int] = [:]
        for group in groups {
            guard let root = rootOf[group.id], let status = roots[root] else { continue }
            groupStatuses[group.id] = status
            // Measured from the root, so a nested root draws at the depth of a top-level root. // (#cm-110.3)
            depths[group.id] = tree.depth(of: group.id) - tree.depth(of: root) + 2
        }
        for workspace in workspaces {
            guard let groupId = workspace.groupId, let status = groupStatuses[groupId], let root = rootOf[groupId] else { continue }
            workspaceStatuses[workspace.id] = status
            depths[workspace.id] = tree.depth(of: groupId) - tree.depth(of: root) + 3
        }
        statusIdByGroupId = groupStatuses
        statusIdByWorkspaceId = workspaceStatuses
        depthById = depths
        rootIdByGroupId = rootOf
        rootGroupIds = Set(roots.keys)
        nestedRootGroupIds = Set(roots.keys.filter { tree.parent(of: $0) != nil })
    }
}
