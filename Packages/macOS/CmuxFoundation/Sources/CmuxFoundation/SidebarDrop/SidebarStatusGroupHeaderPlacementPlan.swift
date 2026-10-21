public import Foundation

/// Places a group under a status by moving only intervening loose workspaces across its run.
public struct SidebarStatusGroupHeaderPlacementPlan: Equatable, Sendable {
    /// One loose row or complete group run in the target status, including hidden members.
    public struct Row: Equatable, Sendable {
        /// The loose workspace or group's anchor (the group identity for an empty target group).
        public let referenceId: UUID
        /// Every workspace in this row's run, in model order; empty for an empty target group.
        public let workspaceIds: [UUID]
        /// Whether the row represents a whole workspace group rather than a loose workspace.
        public let isGroup: Bool
        /// The row's position in the full model order, including rows outside this status.
        public let order: Int
        /// The first painted row, normally the workspace or group anchor identity.
        public let firstVisibleRowId: UUID
        /// The last painted row; a folded group ends at its header.
        public let lastVisibleRowId: UUID

        /// Creates an immutable row from model membership and visible endpoints.
        /// - Parameters:
        ///   - referenceId: The stable row reference used for placement.
        ///   - workspaceIds: The entire run, including unpainted members.
        ///   - isGroup: Whether the row is a group block.
        ///   - order: Its full model-order position.
        ///   - firstVisibleRowId: Its first painted identity, defaulting to its reference.
        ///   - lastVisibleRowId: Its last painted identity, defaulting to its reference.
        public init(referenceId: UUID, workspaceIds: [UUID], isGroup: Bool, order: Int,
                    firstVisibleRowId: UUID? = nil, lastVisibleRowId: UUID? = nil) {
            self.referenceId = referenceId
            self.workspaceIds = workspaceIds
            self.isGroup = isGroup
            self.order = order
            self.firstVisibleRowId = firstVisibleRowId ?? referenceId
            self.lastVisibleRowId = lastVisibleRowId ?? referenceId
        }
    }

    /// The opposite side of the unchanged source run to which loose rows cross.
    public enum Side: Equatable, Sendable {
        /// Rows originally after the group move immediately before it.
        case beforeGroup
        /// Rows originally before the group move immediately after it.
        case afterGroup
    }

    /// A semantic landing that can be resolved again against current model membership.
    public let landing: SidebarStatusGroupWorkspaceDropPlan.Placement
    /// Crossed loose workspaces in their existing model order.
    public let crossingWorkspaceIds: [UUID]
    /// The destination side, or nil when the drop moves no loose workspaces.
    public let destinationSide: Side?
    /// The visible gap promised by this landing, at the status group's indent.
    public let indicator: SidebarDropIndicator
    /// The order of calls that preserves row order when each call places a row against the run.
    public var workspaceIdsInMoveOrder: [UUID] {
        destinationSide == .afterGroup ? crossingWorkspaceIds.reversed() : crossingWorkspaceIds
    }

    /// Resolves a requested edge without moving the source run or another group.
    /// - Parameters:
    ///   - rows: Target-status loose rows and whole groups in model order, possibly including the source.
    ///   - source: The nonempty dragged group run, at its unchanged model position.
    ///   - placement: The requested status header or member edge.
    ///   - statusHeaderId: The painted status header identity.
    ///   - isFolded: Whether only the status header is painted.
    ///   - movesSource: False for nested or pinned headers, whose line only marks the status being set.
    public init?(rows: [Row], source: Row, placement: SidebarStatusGroupWorkspaceDropPlan.Placement,
                 statusHeaderId: UUID, isFolded: Bool = false, movesSource: Bool = true) {
        guard source.isGroup, !source.workspaceIds.isEmpty else { return nil }
        let remaining = rows.filter { $0.referenceId != source.referenceId }.sorted { $0.order < $1.order }
        let current = remaining.prefix { $0.order < source.order }.count
        let requested: Int
        var requestedIndicator: SidebarDropIndicator?
        switch placement {
        case .first:
            requested = 0
            requestedIndicator = .init(tabId: statusHeaderId, edge: .bottom)
        case .member(let id, let before):
            if !movesSource, let ancestor = remaining.firstIndex(where: {
                $0.isGroup && $0.workspaceIds.contains(source.referenceId)
                    && ($0.referenceId == id || $0.workspaceIds.contains(id))
            }) {
                // A nested source inside its target ancestor has no outside side of its own.
                requested = ancestor
                requestedIndicator = .init(tabId: remaining[ancestor].firstVisibleRowId, edge: .top)
            } else if source.referenceId == id || source.workspaceIds.contains(id) {
                requested = current
                requestedIndicator = .init(tabId: source.firstVisibleRowId, edge: .top)
            } else {
                guard let index = remaining.firstIndex(where: {
                    $0.referenceId == id || $0.workspaceIds.contains(id)
                }) else { return nil }
                let row = remaining[index]
                if row.isGroup {
                    // A member edge never means joining or passing the containing group.
                    requested = index + (row.order < source.order ? 1 : 0)
                } else {
                    requested = index + (before ? 0 : 1)
                    requestedIndicator = .init(tabId: before ? row.firstVisibleRowId : row.lastVisibleRowId,
                                               edge: before ? .top : .bottom)
                }
            }
        }
        let gap: Int
        if movesSource {
            let lower = remaining[..<current].lastIndex(where: \.isGroup).map { $0 + 1 } ?? 0
            let upper = remaining[current...].firstIndex(where: \.isGroup) ?? remaining.count
            gap = min(max(requested, lower), upper)
        } else { gap = requested }
        if gap != requested { requestedIndicator = nil }

        if gap == 0 { landing = .first }
        else if gap < remaining.count { landing = .member(remaining[gap].referenceId, insertBefore: true) }
        else if let last = remaining.last { landing = .member(last.referenceId, insertBefore: false) }
        else { landing = .first }

        let crossing: [Row]
        if !movesSource || gap == current {
            crossing = []
            destinationSide = nil
        } else if gap > current {
            crossing = Array(remaining[current..<gap])
            destinationSide = .beforeGroup
        } else {
            crossing = Array(remaining[gap..<current])
            destinationSide = .afterGroup
        }
        // Clamping already excludes groups; retain the check if future placement rules grow.
        guard crossing.allSatisfy({ !$0.isGroup }) else { return nil }
        crossingWorkspaceIds = crossing.map(\.referenceId)

        if isFolded {
            indicator = .init(tabId: statusHeaderId, edge: .bottom)
        } else if let requestedIndicator {
            indicator = requestedIndicator
        } else if movesSource && gap == current && rows.contains(where: { $0.referenceId == source.referenceId }) {
            indicator = .init(tabId: source.firstVisibleRowId, edge: .top)
        } else if gap < remaining.count {
            indicator = .init(tabId: remaining[gap].firstVisibleRowId, edge: .top)
        } else if let last = remaining.last {
            indicator = .init(tabId: last.lastVisibleRowId, edge: .bottom)
        } else {
            indicator = .init(tabId: statusHeaderId, edge: .bottom)
        }
    }
}
