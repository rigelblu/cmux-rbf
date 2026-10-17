public import Foundation

/// Header-only intent; no workspace status, color, pin or membership mutation is possible here.
public struct SidebarStatusHeaderDropPlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case statusGroup(targetStatusId: String, insertBefore: Bool)
        case area(aboveRow: String, belowRow: String?, last: Bool)
    }
    public let indicator: SidebarDropIndicator
    public let action: Action

    public init(indicator: SidebarDropIndicator, action: Action) {
        self.indicator = indicator
        self.action = action
    }
}
