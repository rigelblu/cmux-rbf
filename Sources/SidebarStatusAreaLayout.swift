import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// Values needed to place the entire area and classify measured rows; no observable store is retained.
@MainActor
struct SidebarStatusAreaLayout {
    private let items: [SidebarWorkspaceRenderItem]
    private let itemById: [SidebarWorkspaceRenderItemID: SidebarWorkspaceRenderItem]
    private let owners: [SidebarWorkspaceRenderItemID: String]
    private let pinnedRows: Set<SidebarWorkspaceRenderItemID>
    private let statusIdByMember: [UUID: String]

    init(items: [SidebarWorkspaceRenderItem], tabs: [Workspace] = [], groups: [WorkspaceGroup] = [],
         statusProjection: WorkspaceStatusGroupProjection? = nil) {
        self.items = items
        itemById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let effectiveGroups = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: tabs, groupsById: groupsById)
        func rootGroup(_ id: UUID) -> WorkspaceGroup? {
            var current = groupsById[id]
            var seen = Set<UUID>()
            while let group = current, seen.insert(group.id).inserted,
                  let parent = group.parentGroupId, let next = groupsById[parent] { current = next }
            return current
        }
        var owners: [SidebarWorkspaceRenderItemID: String] = [:]
        var pinned = Set<SidebarWorkspaceRenderItemID>()
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for item in items {
            switch item {
            case .workspace(let id):
                if let groupId = effectiveGroups[id] ?? nil, let root = rootGroup(groupId) {
                    owners[item.id] = "group:\(root.id.uuidString)"
                    if root.isPinned { pinned.insert(item.id) }
                } else {
                    owners[item.id] = "workspace:\(id.uuidString)"
                    if tabsById[id]?.isPinned == true { pinned.insert(item.id) }
                }
            case .groupHeader(let id, _):
                let root = rootGroup(id)
                owners[item.id] = "group:\((root?.id ?? id).uuidString)"
                if root?.isPinned == true { pinned.insert(item.id) }
            case .colorSectionHeader(let section):
                let isPinned = section.id.pinTier == .pinned
                let key = isPinned ? "pinned-color:\(section.id.normalizedHex)" : "color:\(section.id.normalizedHex)"
                owners[item.id] = key
                if isPinned { pinned.insert(item.id) }
                for member in section.memberWorkspaceIds {
                    owners[.workspace(member)] = key
                    if isPinned { pinned.insert(.workspace(member)) }
                }
            case .statusesHeader, .statusGroupHeader: break
            }
        }
        // Color headers precede their members, so apply whole-color ownership after visiting all rows.
        for item in items {
            guard case .colorSectionHeader(let section) = item else { continue }
            let key = (section.id.pinTier == .pinned ? "pinned-color:" : "color:") + section.id.normalizedHex
            for member in section.memberWorkspaceIds { owners[.workspace(member)] = key }
        }
        self.owners = owners
        pinnedRows = pinned
        var byMember: [UUID: String] = [:]
        for group in statusProjection?.groups ?? [] {
            for id in group.memberWorkspaceIds { byMember[id] = group.statusId }
        }
        statusIdByMember = byMember
    }

    func owner(of row: SidebarWorkspaceRenderItemID) -> String? {
        if case .workspace(let id)? = itemById[row], statusIdByMember[id] != nil { return nil }
        return owners[row]
    }

    var topLevelRowIds: Set<String> {
        Set(items.compactMap { pinnedRows.contains($0.id) ? nil : owner(of: $0.id) })
    }

    func placing(area: [SidebarWorkspaceRenderItem], state: WorkspaceStatusGroupsState?) -> [SidebarWorkspaceRenderItem] {
        guard !area.isEmpty, let state, state.last != true else { return items + area }
        let pinBoundary = items.indices.last(where: { pinnedRows.contains(items[$0].id) }).map { $0 + 1 } ?? 0
        let insertion: Int
        if state.aboveRow == "top" { insertion = pinBoundary }
        else if let above = state.aboveRow, let index = items.indices.last(where: { owner(of: items[$0].id) == above }) {
            insertion = max(pinBoundary, index + 1)
        } else if let below = state.belowRow, let index = items.firstIndex(where: { owner(of: $0.id) == below }) {
            insertion = max(pinBoundary, index)
        } else { insertion = items.count }
        return Array(items[..<insertion]) + area + Array(items[insertion...])
    }

    func saving(state: WorkspaceStatusGroupsState?) -> WorkspaceStatusGroupsState? {
        saving(state: state, movingWorkspaceIds: [], movingGroupIds: [])
    }

    /// Saves the area's neighbours as `saving(state:)` does, but never anchors it to a row that is about to leave: an
    /// owner whose every row is moving is skipped, so the area keeps the next row that stays. (#cm-110.1)
    func saving(state: WorkspaceStatusGroupsState?, movingWorkspaceIds: Set<UUID>, movingGroupIds: Set<UUID>) -> WorkspaceStatusGroupsState? {
        guard var state, let areaIndex = items.firstIndex(where: { if case .statusesHeader = $0 { return true }; return false }) else { return state }
        let leaving = leavingOwners(movingWorkspaceIds: movingWorkspaceIds, movingGroupIds: movingGroupIds)
        func anchors(_ item: SidebarWorkspaceRenderItem) -> Bool {
            guard !pinnedRows.contains(item.id), let owner = owner(of: item.id) else { return false }
            return !leaving.contains(owner)
        }
        let above = items[..<areaIndex].last(where: anchors)
        let below = items.dropFirst(areaIndex + 1).first(where: anchors)
        state.aboveRow = above.flatMap { owner(of: $0.id) } ?? "top"
        state.belowRow = below.flatMap { owner(of: $0.id) }
        state.last = below == nil
        return state
    }

    /// Owners that have rows and all of them are moving. A group moves whole when its own header is dragged; a member
    /// leaving one group, or one workspace of a color group, leaves the owner in place. (#cm-110.1)
    private func leavingOwners(movingWorkspaceIds: Set<UUID>, movingGroupIds: Set<UUID>) -> Set<String> {
        guard !movingWorkspaceIds.isEmpty || !movingGroupIds.isEmpty else { return [] }
        var moving = Set<String>(), staying = Set<String>(), wholeGroups = Set<String>()
        for item in items {
            guard let owner = owner(of: item.id) else { continue }
            switch item {
            case .workspace(let id):
                if movingWorkspaceIds.contains(id) { moving.insert(owner) } else { staying.insert(owner) }
            case .groupHeader(let id, let anchorId):
                let dragged = movingGroupIds.contains(id) || movingWorkspaceIds.contains(anchorId)
                if dragged && owner == "group:\(id.uuidString)" { wholeGroups.insert(owner) } else { staying.insert(owner) }
            case .colorSectionHeader(let section):
                let members = section.memberWorkspaceIds
                if !members.isEmpty && members.allSatisfy(movingWorkspaceIds.contains) { moving.insert(owner) } else { staying.insert(owner) }
            case .statusesHeader, .statusGroupHeader: break
            }
        }
        return wholeGroups.union(moving.subtracting(staying))
    }

    func headerDropTargets(measured: [SidebarWorkspaceReorderDropOverlay.Target]) -> [SidebarStatusHeaderDropTarget] {
        measured.compactMap { target in
            let rowId = target.renderItemId ?? .workspace(target.workspaceId)
            guard let item = itemById[rowId] else { return nil }
            let statusId: String?
            let isArea: Bool
            switch item {
            case .statusesHeader: statusId = nil; isArea = true
            case .statusGroupHeader(let id): statusId = id; isArea = false
            case .workspace(let id): statusId = statusIdByMember[id]; isArea = false
            default: statusId = nil; isArea = false
            }
            return .init(rowId: target.workspaceId, frame: target.frame,
                         topLevelRowId: statusId == nil && !isArea ? owner(of: rowId) : nil,
                         statusId: statusId, isStatusesArea: isArea, isPinned: pinnedRows.contains(rowId))
        }
    }
}
