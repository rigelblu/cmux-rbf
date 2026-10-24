public import Foundation
import CmuxSettings

/// One window's saved status-group folds. Absence of this record means an old window has not copied its color folds.
public struct WorkspaceStatusGroupsState: Codable, Equatable, Sendable {
    public var areaCollapsed: Bool
    public var collapsedStatusIds: Set<String>
    public var order: [String]?
    public var last: Bool?
    public var aboveRow: String?
    public var belowRow: String?
    /// Absent until this window's untouched legacy placement has been resolved.
    public var sectionOrder: WorkspaceSectionOrder?
    /// Missing records start unfolded; absence is retained while migration is pending.
    public var workspacesCollapsed: Bool?
    /// Missing records start unfolded; absence means unfolded. (#cm-110.5)
    public var pinnedCollapsed: Bool?

    /// Creates a record; a new window starts with the area and every status open.
    public init(areaCollapsed: Bool = false, collapsedStatusIds: Set<String> = [],
                order: [String]? = nil, last: Bool? = nil, aboveRow: String? = nil, belowRow: String? = nil,
                sectionOrder: WorkspaceSectionOrder? = nil, workspacesCollapsed: Bool? = nil,
                pinnedCollapsed: Bool? = nil) { // (#cm-110.5)
        self.areaCollapsed = areaCollapsed
        self.collapsedStatusIds = collapsedStatusIds
        self.order = order
        self.last = last
        self.aboveRow = aboveRow
        self.belowRow = belowRow
        self.sectionOrder = sectionOrder
        self.workspacesCollapsed = workspacesCollapsed
        self.pinnedCollapsed = pinnedCollapsed // (#cm-110.5)
        self = canonicalizingSectionOrder()
    }

    private enum CodingKeys: String, CodingKey {
        case areaCollapsed
        case collapsedStatusIds
        case order, last, aboveRow, belowRow
        case sectionOrder, workspacesCollapsed
        case pinnedCollapsed // (#cm-110.5)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        areaCollapsed = try values.decodeIfPresent(Bool.self, forKey: .areaCollapsed) ?? false
        collapsedStatusIds = Set(try values.decodeIfPresent([String].self, forKey: .collapsedStatusIds) ?? [])
        order = try values.decodeIfPresent([String].self, forKey: .order)
        last = try values.decodeIfPresent(Bool.self, forKey: .last)
        aboveRow = try values.decodeIfPresent(String.self, forKey: .aboveRow)
        belowRow = try values.decodeIfPresent(String.self, forKey: .belowRow)
        // A future order must not make the entire window undecodable.
        sectionOrder = try values.decodeIfPresent(String.self, forKey: .sectionOrder)
            .flatMap(WorkspaceSectionOrder.init(rawValue:))
        workspacesCollapsed = try values.decodeIfPresent(Bool.self, forKey: .workspacesCollapsed)
        pinnedCollapsed = try values.decodeIfPresent(Bool.self, forKey: .pinnedCollapsed) // (#cm-110.5)
        self = canonicalizingSectionOrder()
    }

    public func encode(to encoder: any Encoder) throws {
        let state = canonicalizingSectionOrder()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state.areaCollapsed, forKey: .areaCollapsed)
        try values.encode(state.collapsedStatusIds.sorted(), forKey: .collapsedStatusIds)
        try values.encodeIfPresent(state.order, forKey: .order)
        try values.encodeIfPresent(state.last, forKey: .last)
        try values.encodeIfPresent(state.aboveRow, forKey: .aboveRow)
        if state.last != true { try values.encodeIfPresent(state.belowRow, forKey: .belowRow) }
        try values.encodeIfPresent(state.sectionOrder?.rawValue, forKey: .sectionOrder)
        try values.encodeIfPresent(state.workspacesCollapsed, forKey: .workspacesCollapsed)
        try values.encodeIfPresent(state.pinnedCollapsed, forKey: .pinnedCollapsed) // (#cm-110.5)
    }

    /// Retains the old decoder's top/end placement as a copy of an already resolved order.
    /// Pending legacy records are returned unchanged, including their original anchors.
    public func canonicalizingSectionOrder() -> Self {
        guard let sectionOrder else { return self }
        var next = self
        next.aboveRow = "top"
        next.belowRow = nil
        next.last = sectionOrder == .workspacesFirst
        next.workspacesCollapsed = workspacesCollapsed ?? false
        return next
    }

    /// Saves a resolved section order and its legacy compatibility copy.
    /// - Parameter order: Which section precedes the other below pinned rows.
    public mutating func placeSections(_ order: WorkspaceSectionOrder) {
        sectionOrder = order
        self = canonicalizingSectionOrder()
    }

    /// Toggles only the ordinary workspace section, retaining all inner folds.
    public mutating func toggleWorkspaces() {
        workspacesCollapsed = !(workspacesCollapsed ?? false)
    }

    /// Toggles the pinned section fold, retaining all inner folds. (#cm-110.5)
    public mutating func togglePinned() {
        pinnedCollapsed = !(pinnedCollapsed ?? false)
    }

    /// Reveals a pinned workspace by unfolding the pinned section. (#cm-110.5)
    public mutating func revealPinned() {
        pinnedCollapsed = false
    }

    /// Reveals an ordinary selected workspace without changing the Statuses folds.
    public mutating func revealWorkspaces() {
        workspacesCollapsed = false
    }

    /// Copies a restored window's color folds into the statuses of the first list it uses.
    public static func seeded(
        list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String],
        collapsedColorHexes: Set<String>
    ) -> Self {
        let foldedHexes = Set(collapsedColorHexes.compactMap(WorkspaceColorHex.normalized))
        let foldedIds = list.entries.compactMap { entry -> String? in
            guard let rawHex = resolvedHexByStatusId[entry.id],
                  let hex = WorkspaceColorHex.normalized(rawHex), foldedHexes.contains(hex) else { return nil }
            return entry.id
        }
        return Self(collapsedStatusIds: Set(foldedIds))
    }

    /// Toggles one status by its stable id, retaining ids absent from the current list.
    public mutating func toggleStatus(id: String) {
        if collapsedStatusIds.remove(id) == nil { collapsedStatusIds.insert(id) }
    }

    /// Toggles the whole Statuses area.
    public mutating func toggleArea() {
        areaCollapsed.toggle()
    }

    /// Reveals a selected member by opening its group and the area, leaving other folds intact.
    public mutating func reveal(statusId: String) {
        areaCollapsed = false
        collapsedStatusIds.remove(statusId)
    }
}
