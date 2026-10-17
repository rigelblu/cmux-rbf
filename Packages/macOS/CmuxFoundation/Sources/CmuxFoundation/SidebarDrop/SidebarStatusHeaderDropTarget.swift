public import CoreGraphics
public import Foundation

/// One measured sidebar row, classified by its whole top-level item or status group.
public struct SidebarStatusHeaderDropTarget: Equatable, Sendable {
    public let rowId: UUID
    public let frame: CGRect
    public let topLevelRowId: String?
    public let statusId: String?
    public let isStatusesArea: Bool
    public let isPinned: Bool

    public init(rowId: UUID, frame: CGRect, topLevelRowId: String? = nil,
                statusId: String? = nil, isStatusesArea: Bool = false, isPinned: Bool = false) {
        self.rowId = rowId
        self.frame = frame
        self.topLevelRowId = topLevelRowId
        self.statusId = statusId
        self.isStatusesArea = isStatusesArea
        self.isPinned = isPinned
    }
}
