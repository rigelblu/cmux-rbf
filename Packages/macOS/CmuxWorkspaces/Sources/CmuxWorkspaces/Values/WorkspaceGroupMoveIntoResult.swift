public import Foundation

/// The outcome of `Move Group to` (#cm-106).
public enum WorkspaceGroupMoveIntoResult: Equatable, Sendable {
    /// The group now sits in the destination.
    case moved
    /// The destination is where the group already is. Nothing changed.
    case unchanged
    case groupNotFound
    case destinationNotFound
    /// The destination is the group or a group inside it. The menu never offers it; the model refuses it anyway.
    case destinationIsSelfOrInside
}

/// One place a group may go into, as `Move Group to` lists it (#cm-106).
public struct WorkspaceGroupMoveDestination: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    /// How many groups hold the destination; the menu indents by it.
    public let depth: Int
    /// Whether the group already sits in this destination (the menu ticks it).
    public let isCurrent: Bool

    public init(id: UUID, name: String, depth: Int, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.depth = depth
        self.isCurrent = isCurrent
    }
}

/// What `Move Group to` offers one group: `Top Level`, then every group it may go into (#cm-106).
public struct WorkspaceGroupMoveMenu: Equatable, Sendable {
    /// Whether the group is at the top level (the menu ticks `Top Level`).
    public let topLevelIsCurrent: Bool
    /// Every group but the group and the groups inside it, in sidebar order: a parent before its children.
    public let destinations: [WorkspaceGroupMoveDestination]

    public init(topLevelIsCurrent: Bool, destinations: [WorkspaceGroupMoveDestination]) {
        self.topLevelIsCurrent = topLevelIsCurrent
        self.destinations = destinations
    }
}

/// The outcome of moving a group beside another group, by `workspace.group.move` (#cm-106).
public enum WorkspaceGroupMoveBesideResult: Equatable, Sendable {
    /// The group moved.
    case moved
    /// The group is already where the request puts it, or the move was clamped to where it already is.
    case unchanged
    case groupNotFound
    case targetNotFound
    /// The target sits in a different parent from the group. Nothing changed.
    case targetNotBeside
}

extension WorkspaceGroupMoveMenu {
    /// What `Move Group to` offers one group, worked out from plain values: `Top Level`, then every group but the
    /// group and the ones inside it, in the order given (a parent before its children), each with its depth. The
    /// SwiftUI header gets this as a value built above the lazy boundary; the AppKit header reads the same through
    /// the coordinator when its menu opens. Nil when the group is not in `groups`.
    public static func menu(for groupId: UUID, groups: [WorkspaceGroup]) -> WorkspaceGroupMoveMenu? {
        guard groups.contains(where: { $0.id == groupId }) else { return nil }
        let tree = WorkspaceGroupTree(groups: groups)
        let current = tree.parent(of: groupId)
        let excluded = Set([groupId] + tree.descendants(of: groupId))
        let destinations = groups.compactMap { group -> WorkspaceGroupMoveDestination? in
            guard !excluded.contains(group.id) else { return nil }
            return WorkspaceGroupMoveDestination(
                id: group.id,
                name: group.name,
                depth: tree.depth(of: group.id),
                isCurrent: group.id == current
            )
        }
        return WorkspaceGroupMoveMenu(topLevelIsCurrent: current == nil, destinations: destinations)
    }
}
