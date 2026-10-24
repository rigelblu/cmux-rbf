// Frozen downgrade reader from fork v0.34.0 (262c0f8f22a7). Only the type name/visibility and module import differ.
import CmuxWorkspaces
public import Foundation
import CmuxSettings

/// One window's saved status-group folds. Absence of this record means an old window has not copied its color folds.
struct ReleasedWorkspaceStatusGroupsState: Codable, Equatable, Sendable {
    public var areaCollapsed: Bool
    public var collapsedStatusIds: Set<String>
    public var order: [String]?
    public var last: Bool?
    public var aboveRow: String?
    public var belowRow: String?

    /// Creates a record; a new window starts with the area and every status open.
    public init(areaCollapsed: Bool = false, collapsedStatusIds: Set<String> = [],
                order: [String]? = nil, last: Bool? = nil, aboveRow: String? = nil, belowRow: String? = nil) {
        self.areaCollapsed = areaCollapsed
        self.collapsedStatusIds = collapsedStatusIds
        self.order = order
        self.last = last
        self.aboveRow = aboveRow
        self.belowRow = belowRow
    }

    private enum CodingKeys: String, CodingKey {
        case areaCollapsed
        case collapsedStatusIds
        case order, last, aboveRow, belowRow
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        areaCollapsed = try values.decodeIfPresent(Bool.self, forKey: .areaCollapsed) ?? false
        collapsedStatusIds = Set(try values.decodeIfPresent([String].self, forKey: .collapsedStatusIds) ?? [])
        order = try values.decodeIfPresent([String].self, forKey: .order)
        last = try values.decodeIfPresent(Bool.self, forKey: .last)
        aboveRow = try values.decodeIfPresent(String.self, forKey: .aboveRow)
        belowRow = try values.decodeIfPresent(String.self, forKey: .belowRow)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(areaCollapsed, forKey: .areaCollapsed)
        try values.encode(collapsedStatusIds.sorted(), forKey: .collapsedStatusIds)
        try values.encodeIfPresent(order, forKey: .order)
        try values.encodeIfPresent(last, forKey: .last)
        try values.encodeIfPresent(aboveRow, forKey: .aboveRow)
        if last != true { try values.encodeIfPresent(belowRow, forKey: .belowRow) }
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
