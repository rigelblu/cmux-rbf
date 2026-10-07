public import Foundation

/// Immutable workspace group data used by the sidebar workspace reorder resolver.
public struct SidebarWorkspaceReorderGroupSnapshot: Equatable, Sendable {
    /// The group identifier.
    public let id: UUID

    /// The workspace id rendered as the group's header row.
    public let anchorWorkspaceId: UUID

    /// Whether the group belongs to the leading pinned tier.
    public let isPinned: Bool

    /// Whether the group currently has no live workspace member.
    public let isEmpty: Bool

    /// The group this group sits inside, or `nil` at the top level (#cm-106).
    public let parentGroupId: UUID?

    /// Creates a workspace group snapshot for sidebar reorder planning.
    ///
    /// - Parameters:
    ///   - id: The group identifier.
    ///   - anchorWorkspaceId: The workspace id rendered as the group's header row.
    ///   - isPinned: Whether the group belongs to the leading pinned tier.
    ///   - isEmpty: Whether the group is represented by a header-only row.
    ///   - parentGroupId: The group one level out, or `nil` at the top level (#cm-106).
    public init(id: UUID, anchorWorkspaceId: UUID, isPinned: Bool, isEmpty: Bool = false, parentGroupId: UUID? = nil) {
        self.id = id
        self.anchorWorkspaceId = anchorWorkspaceId
        self.isPinned = isPinned
        self.isEmpty = isEmpty
        self.parentGroupId = parentGroupId
    }
}
