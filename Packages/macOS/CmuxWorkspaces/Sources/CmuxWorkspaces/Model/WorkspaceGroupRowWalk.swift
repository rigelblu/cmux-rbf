public import Foundation

/// One row of the sidebar's nested list (#cm-106): a group's header or a workspace, with the level it is drawn at.
public struct WorkspaceGroupWalkRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case header(groupId: UUID)
        case workspace(UUID)
    }

    public var kind: Kind
    /// 0 at the top level; one more for each group above the row. A header's depth is the number of groups
    /// that hold it, and a workspace's is one more than the group it sits in.
    public var depth: Int

    public init(kind: Kind, depth: Int) {
        self.kind = kind
        self.depth = depth
    }
}

/// The nested list of rows, worked out from plain values: walks the layout, level by level, header first and then
/// the rows inside it. A folded group shows its header and nothing inside it, at any depth. The workspace behind a
/// group's name is the header and not a row. Both sidebar renderers draw this one list.
public enum WorkspaceGroupRowWalk {
    public static func rows(
        groups: [WorkspaceGroup],
        workspaces: [WorkspaceGroupWorkspaceItem]
    ) -> [WorkspaceGroupWalkRow] {
        let tree = WorkspaceGroupTree(groups: groups)
        let layout = WorkspaceGroupLayout(tree: tree, groups: groups, workspaces: workspaces)
        let collapsed = Dictionary(groups.map { ($0.id, $0.isCollapsed) }, uniquingKeysWith: { first, _ in first })
        var out: [WorkspaceGroupWalkRow] = []
        out.reserveCapacity(workspaces.count + groups.count)
        func walk(_ level: UUID?, _ depth: Int) {
            for row in layout.rows(of: level) {
                switch row {
                case .workspace(let id):
                    out.append(WorkspaceGroupWalkRow(kind: .workspace(id), depth: depth))
                case .group(let id):
                    out.append(WorkspaceGroupWalkRow(kind: .header(groupId: id), depth: depth))
                    if collapsed[id] != true { walk(id, depth + 1) }
                }
            }
        }
        walk(nil, 0)
        return out
    }

    /// The groups with a folded group above them, at any level. Their rows are hidden, so no workspace in them has a
    /// number (`⌘1…9` ranges over the rows that are shown). Empty when no group is nested.
    public static func groupIdsUnderAFoldedGroup(groups: [WorkspaceGroup]) -> Set<UUID> {
        guard groups.contains(where: { $0.parentGroupId != nil }) else { return [] }
        let tree = WorkspaceGroupTree(groups: groups)
        let folded = Set(groups.filter(\.isCollapsed).map(\.id))
        return Set(groups.map(\.id).filter { id in tree.ancestors(of: id).contains(where: folded.contains) })
    }

    /// Every workspace inside each group at any level, in tabs order. The workspace behind a group's name
    /// is included, and so are the workspaces of the groups inside it.
    public static func workspaceIdsInside(
        groups: [WorkspaceGroup],
        workspaces: [WorkspaceGroupWorkspaceItem]
    ) -> [UUID: [UUID]] {
        let tree = WorkspaceGroupTree(groups: groups)
        let known = Set(groups.map(\.id))
        var result: [UUID: [UUID]] = [:]
        for workspace in workspaces {
            guard let groupId = workspace.groupId, known.contains(groupId) else { continue }
            result[groupId, default: []].append(workspace.id)
            for ancestor in tree.ancestors(of: groupId) {
                result[ancestor, default: []].append(workspace.id)
            }
        }
        return result
    }
}
