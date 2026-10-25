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
/// the rows inside it. A folded group shows its header and nothing inside it, at any depth, except a group the sidebar
/// draws under a status (`groupsShownUnderAStatus`, #cm-110.3): folding its parent does not hide it (Decisions,
/// 2026-10-24 rulings, (7)), though its own fold and the folds inside it still do. The workspace behind a group's name
/// is the header and not a row. Both sidebar renderers draw this one list.
public enum WorkspaceGroupRowWalk {
    /// - Parameter groupsShownUnderAStatus: The nested groups the sidebar draws under a status group. The app derives
    ///   it from the same `WorkspaceGroupStatusProjection` the renderer uses; empty means "as today". // (#cm-110.3)
    public static func rows(
        groups: [WorkspaceGroup],
        workspaces: [WorkspaceGroupWorkspaceItem],
        groupsShownUnderAStatus shown: Set<UUID> = []
    ) -> [WorkspaceGroupWalkRow] {
        let tree = WorkspaceGroupTree(groups: groups)
        let layout = WorkspaceGroupLayout(tree: tree, groups: groups, workspaces: workspaces)
        let collapsed = Dictionary(groups.map { ($0.id, $0.isCollapsed) }, uniquingKeysWith: { first, _ in first })
        // Groups that hold a workspace at any level; a shown root outside this set is empty. // (#cm-110.3)
        var hasRun = Set<UUID>()
        if !shown.isEmpty {
            for workspace in workspaces {
                guard let groupId = workspace.groupId else { continue }
                hasRun.insert(groupId)
                hasRun.formUnion(tree.ancestors(of: groupId))
            }
        }
        var out: [WorkspaceGroupWalkRow] = []
        out.reserveCapacity(workspaces.count + groups.count)
        /// `hidden`: a folded group is above, so only a shown root (and what is inside it) comes out. // (#cm-110.3)
        func walk(_ level: UUID?, _ depth: Int, hidden: Bool) {
            var rows = layout.rows(of: level)
            if !shown.isEmpty {
                // An empty root shown under a status sorts where its parent's run starts (ruling (26)). // (#cm-110.3)
                let empty = rows.filter { if case .group(let id) = $0 { return shown.contains(id) && !hasRun.contains(id) }; return false }
                rows = empty + rows.filter { !empty.contains($0) }
            }
            for row in rows {
                switch row {
                case .workspace(let id):
                    if !hidden { out.append(WorkspaceGroupWalkRow(kind: .workspace(id), depth: depth)) }
                case .group(let id):
                    let isShownRoot = shown.contains(id)
                    if hidden && !isShownRoot {
                        if !shown.isEmpty { walk(id, depth + 1, hidden: true) }
                        continue
                    }
                    out.append(WorkspaceGroupWalkRow(kind: .header(groupId: id), depth: depth))
                    if collapsed[id] != true {
                        walk(id, depth + 1, hidden: false)
                    } else if !shown.isEmpty && !isShownRoot {
                        walk(id, depth + 1, hidden: true)
                    }
                }
            }
        }
        walk(nil, 0, hidden: false)
        return out
    }

    /// The groups with a folded group above them, at any level. Their rows are hidden, so no workspace in them has a
    /// number (`⌘1…9` ranges over the rows that are shown). Empty when no group is nested. A group shown under a status
    /// is not hidden by what is above it: only the folds from it down count (#cm-110.3).
    public static func groupIdsUnderAFoldedGroup(
        groups: [WorkspaceGroup],
        groupsShownUnderAStatus shown: Set<UUID> = []
    ) -> Set<UUID> {
        guard groups.contains(where: { $0.parentGroupId != nil }) else { return [] }
        let tree = WorkspaceGroupTree(groups: groups)
        let folded = Set(groups.filter(\.isCollapsed).map(\.id))
        return Set(groups.map(\.id).filter { id in
            if shown.contains(id) { return false } // (#cm-110.3)
            var cursor = tree.parent(of: id)
            while let ancestor = cursor {
                if folded.contains(ancestor) { return true }
                if shown.contains(ancestor) { return false } // (#cm-110.3) what is above the root does not hide this
                cursor = tree.parent(of: ancestor)
            }
            return false
        })
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
