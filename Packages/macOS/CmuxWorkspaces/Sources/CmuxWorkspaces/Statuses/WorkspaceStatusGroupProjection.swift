public import Foundation

/// Projects loose workspaces into ordered status groups according to the active status list and resolutions.
public struct WorkspaceStatusGroupProjection: Equatable, Sendable {
    public let groups: [WorkspaceStatusGroup]
    public let allMemberWorkspaceIds: Set<UUID>
    public let statusGroupStatusIds: Set<String>
    /// Whole workspace groups, kept separate from loose workspace drop membership.
    public let workspaceGroups: WorkspaceGroupStatusProjection?

    public init(groups: [WorkspaceStatusGroup], workspaceGroups: WorkspaceGroupStatusProjection? = nil) {
        self.groups = groups
        self.workspaceGroups = workspaceGroups
        var memberIds = Set<UUID>()
        var statusIds = Set<String>()
        for group in groups {
            statusIds.insert(group.statusId)
            memberIds.formUnion(group.memberWorkspaceIds)
        }
        self.allMemberWorkspaceIds = memberIds
        self.statusGroupStatusIds = statusIds
    }

    /// The sidebar's sections show only for a nonempty file list with its controls enabled.
    public static func showsSections(list: WorkspaceStatusList, controlsEnabled: Bool) -> Bool {
        controlsEnabled && list.source != .cmux && !list.entries.isEmpty
    }

    public func contains(workspaceId: UUID) -> Bool {
        allMemberWorkspaceIds.contains(workspaceId)
    }

    public func group(for statusId: String) -> WorkspaceStatusGroup? {
        groups.first { $0.statusId == statusId }
    }

    /// Every workspace hidden by folding a status group, including anchors and nested group members.
    /// - Parameter statusId: The containing status group's id.
    /// - Returns: Unique workspace identities, distinct from the loose-workspace drop membership.
    public func displayMemberWorkspaceIds(for statusId: String) -> Set<UUID> {
        var ids = Set(group(for: statusId)?.memberWorkspaceIds ?? [])
        for (id, status) in workspaceGroups?.statusIdByWorkspaceId ?? [:] where status == statusId { ids.insert(id) }
        return ids
    }

    /// Every workspace hidden by folding the entire Statuses area.
    public var allDisplayMemberWorkspaceIds: Set<UUID> {
        allMemberWorkspaceIds.union(workspaceGroups?.statusIdByWorkspaceId.keys.map { $0 } ?? [])
    }

    /// Projects workspaces into status groups.
    /// Returns `nil` when there is no list in use (`source == .cmux`) or the list has no entries.
    public static func project(
        workspaces: [WorkspaceStatusGroupProjectionItem],
        list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String] = [:],
        storedOrder: [String]? = nil
    ) -> WorkspaceStatusGroupProjection? {
        // With no list in use (source == .cmux, cmux's five) or an empty file list, there is no area at all (09:493, 09:496, 09:512)
        guard showsSections(list: list, controlsEnabled: true) else { return nil }

        var membersByStatusId: [String: [UUID]] = [:]
        for item in workspaces {
            if let statusId = targetStatusId(for: item, list: list, resolvedHexByStatusId: resolvedHexByStatusId) {
                membersByStatusId[statusId, default: []].append(item.workspaceId)
            }
        }

        let order = orderedStatusIds(entries: list.entries, storedOrder: storedOrder)
        let groups = order.map { statusId in
            WorkspaceStatusGroup(statusId: statusId, memberWorkspaceIds: membersByStatusId[statusId] ?? [])
        }
        return WorkspaceStatusGroupProjection(groups: groups)
    }

    /// Works out the status group order from the file entries and optional saved drag order.
    public static func orderedStatusIds(
        entries: [WorkspaceStatusEntry],
        storedOrder: [String]?
    ) -> [String] {
        let fileIds = entries.map(\.id)
        guard let storedOrder = storedOrder, !storedOrder.isEmpty else {
            return fileIds
        }
        let fileIdSet = Set(fileIds)
        var seen = Set<String>()
        var result: [String] = []
        for id in storedOrder {
            if fileIdSet.contains(id), seen.insert(id).inserted {
                result.append(id)
            }
        }
        var resultSet = Set(result)

        for (index, fileId) in fileIds.enumerated() {
            guard !resultSet.contains(fileId) else { continue }
            var inserted = false
            for prevIndex in stride(from: index - 1, through: 0, by: -1) {
                let prevId = fileIds[prevIndex]
                if let pos = result.firstIndex(of: prevId) {
                    result.insert(fileId, at: pos + 1)
                    resultSet.insert(fileId)
                    inserted = true
                    break
                }
            }
            if !inserted {
                for nextIndex in (index + 1)..<fileIds.count {
                    let nextId = fileIds[nextIndex]
                    if let pos = result.firstIndex(of: nextId) {
                        result.insert(fileId, at: pos)
                        resultSet.insert(fileId)
                        inserted = true
                        break
                    }
                }
            }
            if !inserted {
                result.append(fileId)
                resultSet.insert(fileId)
            }
        }
        return result
    }

    private static func targetStatusId(
        for item: WorkspaceStatusGroupProjectionItem,
        list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String]
    ) -> String? {
        // A pinned workspace, and one in a workspace group, joins no status group (04:11, 04:71)
        guard !item.isPinned, item.groupId == nil else { return nil }

        // None is no status, whatever color the workspace wears (Decisions 2026-10-27). (#cm-110.13)
        guard !item.isStatusHidden else { return nil } // (#cm-110.13)

        switch item.resolution {
        case .ownInEffect(let entry):
            return list.entry(id: entry.id) != nil ? entry.id : nil
        case .cmuxInEffect(let entry, offered: true):
            return list.entry(id: entry.id) != nil ? entry.id : nil
        case .detected(.done), .cmuxLapsed(detected: .done):
            if list.entry(id: "done") != nil {
                return "done"
            }
            return statusIdMatchingColor(item.normalizedColorHex, in: list, resolvedHexByStatusId: resolvedHexByStatusId)
        case .detected(.review), .cmuxLapsed(detected: .review):
            if list.entry(id: "review") != nil {
                return "review"
            }
            return statusIdMatchingColor(item.normalizedColorHex, in: list, resolvedHexByStatusId: resolvedHexByStatusId)
        case .detected(.todo), .detected(.working), .detected(.needsAttention):
            return statusIdMatchingColor(item.normalizedColorHex, in: list, resolvedHexByStatusId: resolvedHexByStatusId)
        case .ownNotListed:
            return statusIdMatchingColor(item.normalizedColorHex, in: list, resolvedHexByStatusId: resolvedHexByStatusId)
        case .cmuxInEffect(_, offered: false):
            return statusIdMatchingColor(item.normalizedColorHex, in: list, resolvedHexByStatusId: resolvedHexByStatusId)
        case .cmuxLapsed:
            return statusIdMatchingColor(item.normalizedColorHex, in: list, resolvedHexByStatusId: resolvedHexByStatusId)
        }
    }

    private static func statusIdMatchingColor(
        _ normalizedHex: String?,
        in list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String]
    ) -> String? {
        guard let normalizedHex = normalizedHex, !normalizedHex.isEmpty else { return nil }
        for entry in list.entries {
            if let entryHex = resolvedHexByStatusId[entry.id],
               !entryHex.isEmpty,
               entryHex.caseInsensitiveCompare(normalizedHex) == .orderedSame {
                return entry.id
            }
        }
        return nil
    }
}
