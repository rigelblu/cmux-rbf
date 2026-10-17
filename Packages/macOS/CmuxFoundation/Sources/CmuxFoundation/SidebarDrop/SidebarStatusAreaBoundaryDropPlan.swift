public import Foundation

/// Captures an ordinary move verbatim while the app reconciles the existing Statuses-area place.
public struct SidebarStatusAreaBoundaryDropPlan: Equatable, Sendable {
    public enum Move: Equatable, Sendable {
        case workspaces(targetIndex: Int, usesTopLevelRows: Bool, explicitGroupId: UUID?)
        case group(targetIndex: Int)
    }
    public let boundary: SidebarStatusGroupDropRules.AreaBoundary
    public let move: Move
    public init(boundary: SidebarStatusGroupDropRules.AreaBoundary, move: Move) {
        self.boundary = boundary
        self.move = move
    }
}
