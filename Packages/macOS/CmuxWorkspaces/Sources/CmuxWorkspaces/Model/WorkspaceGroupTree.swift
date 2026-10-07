public import Foundation

/// Pure value type capturing parent-child relationships among workspace groups.
///
/// Holds no references to live workspaces or stored state. Repairs unknown parents
/// and loops on initialization and lists each repair in ``repairs``; a caller that
/// wants a log line writes one per repair.
public struct WorkspaceGroupTree: Sendable {
    public enum Repair: Equatable, Sendable {
        case unknownParent(group: UUID, parent: UUID)
        case loop(group: UUID)
    }

    /// Group ids in list order.
    public let order: [UUID]
    private let effectiveParent: [UUID: UUID]
    private let childrenByLevel: [UUID?: [UUID]]
    public let repairs: [Repair]

    public init(groups: [WorkspaceGroup]) {
        self.init(items: groups.map { ($0.id, $0.parentGroupId) })
    }

    init(items: [(id: UUID, parentGroupId: UUID?)]) {
        let known = Set(items.map(\.id))
        var parent: [UUID: UUID] = [:]
        var repairs: [Repair] = []

        for item in items {
            guard let p = item.parentGroupId else { continue }
            if known.contains(p) {
                parent[item.id] = p
            } else {
                repairs.append(.unknownParent(group: item.id, parent: p))
            }
        }

        // Rule 5 (WorkspaceGroupLayout.swift, "The six rules"): For loops, each group's chain of parents is walked with a
        // record of the groups already seen, so the walk ends; the first group
        // in list order that is on a loop is read as top-level, which opens that
        // loop, and this repeats until none is left. A group whose chain leads
        // into a loop it is not on stays under its parent.
        for item in items {
            var cursor = parent[item.id]
            var pathSeen = Set<UUID>([item.id])
            while let c = cursor {
                if c == item.id {
                    parent[item.id] = nil
                    repairs.append(.loop(group: item.id))
                    break
                }
                if !pathSeen.insert(c).inserted {
                    break
                }
                cursor = parent[c]
            }
        }

        var children: [UUID?: [UUID]] = [:]
        for item in items {
            children[parent[item.id], default: []].append(item.id)
        }

        self.order = items.map(\.id)
        self.effectiveParent = parent
        self.childrenByLevel = children
        self.repairs = repairs
    }

    /// The groups with each repaired parent written in (an unknown parent and a loop read as top-level),
    /// and the repairs, for a caller that stores the groups and logs each repair once (#cm-106).
    public static func repairingParents(of groups: [WorkspaceGroup]) -> (groups: [WorkspaceGroup], repairs: [Repair]) {
        let tree = WorkspaceGroupTree(groups: groups)
        var repaired = groups
        for index in repaired.indices where repaired[index].parentGroupId != tree.parent(of: repaired[index].id) {
            repaired[index].parentGroupId = tree.parent(of: repaired[index].id)
        }
        return (repaired, tree.repairs)
    }

    /// One log line for a repair.
    public static func message(for repair: Repair) -> String {
        switch repair {
        case .unknownParent(let group, let parent):
            return "Repaired unknown parent for group \(group.uuidString): parent \(parent.uuidString) not found"
        case .loop(let group):
            return "Repaired loop for group \(group.uuidString) by clearing parent"
        }
    }

    public func contains(_ id: UUID) -> Bool {
        effectiveParent[id] != nil || childrenByLevel[nil]?.contains(id) == true
    }

    public func parent(of id: UUID) -> UUID? {
        effectiveParent[id]
    }

    /// Groups directly at a level (nil = top level), in list order.
    public func children(of level: UUID?) -> [UUID] {
        childrenByLevel[level] ?? []
    }

    /// Every group above a group, nearest first.
    public func ancestors(of id: UUID) -> [UUID] {
        var out: [UUID] = []
        var cursor = effectiveParent[id]
        while let c = cursor {
            out.append(c)
            cursor = effectiveParent[c]
        }
        return out
    }

    /// Every group inside a group, parent before child.
    public func descendants(of id: UUID) -> [UUID] {
        var out: [UUID] = []
        for child in children(of: id) {
            out.append(child)
            out.append(contentsOf: descendants(of: child))
        }
        return out
    }

    public func depth(of id: UUID) -> Int {
        ancestors(of: id).count
    }

    /// Strictly inside.
    public func isInside(_ id: UUID, _ other: UUID) -> Bool {
        ancestors(of: id).contains(other)
    }

    public func outermost(of id: UUID) -> UUID {
        ancestors(of: id).last ?? id
    }
}
