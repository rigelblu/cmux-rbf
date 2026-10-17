public import CoreGraphics
public import Foundation

/// Plans header moves against measured whole blocks, independently of workspace-drop rules.
public struct SidebarStatusHeaderDropPlanner: Sendable {
    public init() {}

    /// nil draggedStatusId means the entire Statuses area. A nil result refuses without an indicator.
    public func plan(point: CGPoint, draggedStatusId: String?,
                     targets: [SidebarStatusHeaderDropTarget]) -> SidebarStatusHeaderDropPlan? {
        let rows = targets.sorted { $0.frame.minY < $1.frame.minY }
        guard let area = rows.first(where: \.isStatusesArea), let last = rows.last else { return nil }
        let belowAll = point.y > last.frame.maxY
        let hit = rows.first { point.y <= $0.frame.maxY } ?? last
        if let draggedStatusId {
            guard rows.contains(where: { $0.statusId == draggedStatusId }) else { return nil }
            if belowAll {
                guard let statusId = last.statusId, statusId != draggedStatusId else { return nil }
                return .init(indicator: .init(tabId: last.rowId, edge: .bottom),
                             action: .statusGroup(targetStatusId: statusId, insertBefore: false))
            }
            if hit.isStatusesArea {
                guard let first = rows.first(where: { $0.statusId != nil }),
                      let statusId = first.statusId, statusId != draggedStatusId else { return nil }
                return .init(indicator: .init(tabId: area.rowId, edge: .bottom),
                             action: .statusGroup(targetStatusId: statusId, insertBefore: true))
            }
            guard let statusId = hit.statusId, statusId != draggedStatusId else { return nil }
            let block = rows.filter { $0.statusId == statusId }
            guard let first = block.first, let end = block.last else { return nil }
            let before = point.y < (first.frame.minY + end.frame.maxY) / 2
            return .init(indicator: .init(tabId: before ? first.rowId : end.rowId, edge: before ? .top : .bottom),
                         action: .statusGroup(targetStatusId: statusId, insertBefore: before))
        }

        guard !hit.isStatusesArea, hit.statusId == nil || belowAll else { return nil }
        var owners: [String] = []
        for row in rows where !row.isPinned {
            if let owner = row.topLevelRowId, !owners.contains(owner) { owners.append(owner) }
        }
        let boundary: Int
        let indicator: SidebarDropIndicator
        if hit.isPinned {
            boundary = 0
            let first = rows.first { !$0.isPinned }
            indicator = .init(tabId: first?.rowId ?? area.rowId, edge: .top)
        } else if belowAll {
            boundary = owners.count
            if let owner = owners.last, let end = rows.last(where: { $0.topLevelRowId == owner }) {
                indicator = .init(tabId: end.rowId, edge: .bottom)
            } else {
                indicator = .init(tabId: area.rowId, edge: .top)
            }
        } else {
            guard let owner = hit.topLevelRowId, let index = owners.firstIndex(of: owner) else { return nil }
            let block = rows.filter { $0.topLevelRowId == owner }
            guard let first = block.first, let end = block.last else { return nil }
            let before = point.y < (first.frame.minY + end.frame.maxY) / 2
            boundary = index + (before ? 0 : 1)
            indicator = .init(tabId: before ? first.rowId : end.rowId, edge: before ? .top : .bottom)
        }
        return .init(indicator: indicator, action: .area(
            aboveRow: boundary == 0 ? "top" : owners[boundary - 1],
            belowRow: boundary < owners.count ? owners[boundary] : nil,
            last: boundary == owners.count
        ))
    }
}
