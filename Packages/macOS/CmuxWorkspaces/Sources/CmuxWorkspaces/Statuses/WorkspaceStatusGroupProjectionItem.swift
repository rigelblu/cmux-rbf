public import Foundation

/// Value input representing one workspace for status group projection.
public struct WorkspaceStatusGroupProjectionItem: Equatable, Sendable {
    public let workspaceId: UUID
    public let groupId: UUID?
    public let isPinned: Bool
    public let isStatusHidden: Bool
    public let normalizedColorHex: String?
    public let resolution: WorkspaceStatusResolution

    public init(
        workspaceId: UUID,
        groupId: UUID? = nil,
        isPinned: Bool = false,
        isStatusHidden: Bool = false,
        normalizedColorHex: String? = nil,
        resolution: WorkspaceStatusResolution
    ) {
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isPinned = isPinned
        self.isStatusHidden = isStatusHidden
        self.normalizedColorHex = normalizedColorHex
        self.resolution = resolution
    }
}
