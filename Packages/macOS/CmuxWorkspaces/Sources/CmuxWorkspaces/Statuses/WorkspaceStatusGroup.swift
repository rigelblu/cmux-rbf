public import Foundation

/// Value output representing one status group in the sidebar with its member workspaces.
public struct WorkspaceStatusGroup: Equatable, Sendable {
    public let statusId: String
    public let memberWorkspaceIds: [UUID]

    public init(statusId: String, memberWorkspaceIds: [UUID]) {
        self.statusId = statusId
        self.memberWorkspaceIds = memberWorkspaceIds
    }
}
