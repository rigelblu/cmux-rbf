public import Foundation

/// A status-group landing with a semantic anchor that can be checked again before any write.
public struct SidebarStatusGroupWorkspaceDropPlan: Equatable, Sendable {
    public enum Placement: Equatable, Sendable {
        /// Resolve the current first member; an empty or folded header remains a valid target.
        case first
        /// A cached member edge is valid only while this member still belongs to the target group.
        case member(UUID, insertBefore: Bool)
    }

    public let statusId: String
    public let placement: Placement
    public let setsStatus: Bool
    public let indicator: SidebarDropIndicator
    /// Transient header admission proof, checked again before any mutation; never persisted or sent on the wire. // (#cm-110.8)
    public let headerPlacement: SidebarStatusGroupHeaderPlacementPlan? // (#cm-110.8)

    public init(statusId: String, placement: Placement, setsStatus: Bool, indicator: SidebarDropIndicator, // (#cm-110.8)
                headerPlacement: SidebarStatusGroupHeaderPlacementPlan? = nil) { // (#cm-110.8)
        self.statusId = statusId
        self.placement = placement
        self.setsStatus = setsStatus
        self.indicator = indicator
        self.headerPlacement = headerPlacement // (#cm-110.8)
    }
}
