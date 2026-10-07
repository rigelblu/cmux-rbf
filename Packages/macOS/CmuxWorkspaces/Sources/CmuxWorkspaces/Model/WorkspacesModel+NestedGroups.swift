public import Foundation

// The nested versions of the model's order functions (#cm-106). Each upstream
// function in `WorkspacesModel+GroupInvariants.swift` and `+Ordering.swift`
// hands over here with one line when the window holds a nested group; a window
// with no nested group runs upstream's code and reaches only the helpers that
// answer for a flat window as upstream does: `hasNestedWorkspaceGroup`,
// `holdsWorkspaceGroups`, `workspaceIdsInside` (a group's direct workspaces),
// `groupHoldsNothing`, `workspaceGroupsParentFirst`, `isNestedWorkspaceGroupHeader`,
// `parentGroupIdIfNested`, `keepsHeaderWhenEmptied` and `giveGroupItsFirstOwnWorkspaceIfNeeded`.
//
// An operation reads the layout from what is stored, edits it, and writes it
// back once (design: "Two kinds of operation").
extension WorkspacesModel {
    /// Whether any group in this window sits inside another group.
    public var hasNestedWorkspaceGroup: Bool {
        workspaceGroups.contains { $0.parentGroupId != nil }
    }

    /// Whether a group holds at least one group. Always false in a flat window.
    public func holdsWorkspaceGroups(_ groupId: UUID) -> Bool {
        hasNestedWorkspaceGroup && !nestedGroupTree().children(of: groupId).isEmpty
    }

    /// Every workspace inside a group at any level, in tabs order, the workspace behind the group's name included. In a
    /// window with no nested group these are the group's direct members, as `groupId` says.
    public func workspaceIdsInside(_ groupId: UUID) -> [UUID] {
        guard hasNestedWorkspaceGroup else { return tabs.filter { $0.groupId == groupId }.map(\.id) }
        let tree = nestedGroupTree()
        return tabs.filter { tab in
            guard let id = tab.groupId else { return false }
            return id == groupId || tree.isInside(id, groupId)
        }.map(\.id)
    }

    /// Whether a group holds nothing: no workspace names it and no group names it as parent. This is the
    /// socket's `is_empty`.
    public func groupHoldsNothing(_ groupId: UUID) -> Bool {
        !tabs.contains { $0.groupId == groupId } && !workspaceGroups.contains { $0.parentGroupId == groupId }
    }

    /// The groups in list order with every parent ahead of its children. A legal window already lists them
    /// so (rule 4, WorkspaceGroupLayout.swift, "The six rules"); this keeps the promise to a caller reading an at-rest-broken one. Equal to the stored
    /// list in a flat window.
    public func workspaceGroupsParentFirst() -> [WorkspaceGroup] {
        guard hasNestedWorkspaceGroup else { return workspaceGroups }
        let tree = nestedGroupTree()
        let byId = Dictionary(workspaceGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<UUID>()
        var out: [WorkspaceGroup] = []
        func place(_ id: UUID) {
            guard placed.insert(id).inserted, let group = byId[id] else { return }
            if let parent = tree.parent(of: id) { place(parent) }
            out.append(group)
        }
        for group in workspaceGroups { place(group.id) }
        return out
    }

    /// A group that had no workspace of its own and has just gained one takes the first it owns as the one
    /// behind its name, as `assignGroup` does for a header with none. Callers that hand a dissolved or
    /// deleted group's workspaces to its parent call this for the parent.
    func giveGroupItsFirstOwnWorkspaceIfNeeded(_ groupId: UUID?) {
        guard let groupId,
              let index = workspaceGroups.firstIndex(where: { $0.id == groupId }),
              workspaceGroups[index].liveAnchorWorkspaceId == nil,
              let first = tabs.first(where: { $0.groupId == groupId }) else { return }
        workspaceGroups[index].anchor = .workspace(first.id)
        workspaceGroups[index].anchorWorkspaceProvenance = .user
    }

    /// Whether the workspace stands behind the name of a group that sits inside another group.
    public func isNestedWorkspaceGroupHeader(_ workspaceId: UUID) -> Bool {
        guard hasNestedWorkspaceGroup,
              let group = workspaceGroups.first(where: { $0.liveAnchorWorkspaceId == workspaceId }) else { return false }
        return nestedGroupTree().parent(of: group.id) != nil
    }

    /// Whether a group keeps its header when the workspace behind its name closes or leaves the window:
    /// a pinned group does, and so does one that holds groups.
    func keepsHeaderWhenEmptied(_ group: WorkspaceGroup) -> Bool {
        group.isPinned || holdsWorkspaceGroups(group.id)
    }

    /// The group a group sits in, or nil. Always nil in a flat window.
    func parentGroupIdIfNested(of groupId: UUID) -> UUID? {
        hasNestedWorkspaceGroup ? nestedGroupTree().parent(of: groupId) : nil
    }

    /// The tree of the stored groups, with unknown parents and loops repaired.
    func nestedGroupTree() -> WorkspaceGroupTree {
#if DEBUG
        nestedGroupTreeBuilds += 1
#endif
        return WorkspaceGroupTree(groups: workspaceGroups)
    }

    /// The layout read from the stored workspaces and groups.
    func nestedGroupLayout() -> WorkspaceGroupLayout {
        WorkspaceGroupLayout(tree: nestedGroupTree(), groups: workspaceGroups, tabs: tabs)
    }

    /// The outermost group holding each group, by group id (a top-level group maps to itself).
    func outermostGroupIdsByGroupId() -> [UUID: UUID] {
        let tree = nestedGroupTree()
        return Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, tree.outermost(of: $0.id)) })
    }

    /// Writes the layout back: the order of `tabs`, each workspace's group, each group's
    /// parent and live anchor, and, when asked, the order of `workspaceGroups`.
    /// Writes nothing the layout did not decide.
    func applyGroupLayout(
        _ layout: WorkspaceGroupLayout,
        writesTabs: Bool = true,
        writesGroupOrder: Bool = true,
        groupOrderRule: WorkspaceGroupLayout.NoRunRule? = nil
    ) {
        let out = groupOrderRule.map { layout.output(using: $0) } ?? layout.output()
        if writesTabs { applyTabs(out) }
        applyGroupFacts(out, writesGroupOrder: writesGroupOrder)
    }

    private func applyTabs(_ out: WorkspaceGroupLayout.Output) {
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var reordered = out.tabOrder.compactMap { tabsById[$0] }
        if reordered.count != tabs.count {
            let placed = Set(reordered.map(\.id))
            reordered.append(contentsOf: tabs.filter { !placed.contains($0.id) })
        }
        for tab in reordered {
            if let groupId = out.groupIdByWorkspace[tab.id], tab.groupId != groupId {
                tab.groupId = groupId
            }
        }
        tabs = reordered
    }

    /// Writes the parents and live anchors of an output, and optionally the group order.
    private func applyGroupFacts(_ out: WorkspaceGroupLayout.Output, writesGroupOrder: Bool) {
        var groups = workspaceGroups
        for index in groups.indices {
            let id = groups[index].id
            if let parent = out.parentByGroup[id], groups[index].parentGroupId != parent {
                groups[index].parentGroupId = parent
            }
            if let anchor = out.anchorByGroup[id] {
                if groups[index].liveAnchorWorkspaceId != anchor {
                    groups[index].anchor = .workspace(anchor)
                    groups[index].anchorWorkspaceProvenance = .user
                }
            } else if groups[index].liveAnchorWorkspaceId != nil {
                groups[index].anchor = .empty(id)
                groups[index].anchorWorkspaceProvenance = .unknown
            }
        }
        if writesGroupOrder {
            let byId = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
            var ordered = out.groupOrder.compactMap { byId[$0] }
            let placed = Set(ordered.map(\.id))
            ordered.append(contentsOf: groups.filter { !placed.contains($0.id) })
            groups = ordered
        }
        workspaceGroups = groups
    }

    /// The layout's top-level row a top-level row id stands for: an ungrouped workspace,
    /// or the top-level group whose header workspace (or placeholder identity) it is.
    private func nestedTopLevelRow(
        forId id: UUID,
        topLevelRows: Set<WorkspaceGroupLayout.Row>,
        topLevelGroupByAnchorId: [UUID: UUID]
    ) -> WorkspaceGroupLayout.Row? {
        if let groupId = topLevelGroupByAnchorId[id], topLevelRows.contains(.group(groupId)) {
            return .group(groupId)
        }
        return topLevelRows.contains(.workspace(id)) ? .workspace(id) : nil
    }

    /// Puts the layout's top-level rows in the given order; rows the order does not
    /// mention keep their relative order after it.
    private func nestedSetTopLevelOrder(_ layout: inout WorkspaceGroupLayout, desiredIds: [UUID]) {
        let current = layout.rows(of: nil)
#if DEBUG
        nestedTopLevelRowSetBuilds += 1
#endif
        let currentSet = Set(current)
        let topLevelGroupByAnchorId = Dictionary(
            workspaceGroups.filter { currentSet.contains(.group($0.id)) }.map { ($0.anchorWorkspaceId, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<WorkspaceGroupLayout.Row>()
        var ordered: [WorkspaceGroupLayout.Row] = []
        for id in desiredIds {
            guard let row = nestedTopLevelRow(forId: id, topLevelRows: currentSet, topLevelGroupByAnchorId: topLevelGroupByAnchorId),
                  seen.insert(row).inserted else { continue }
            ordered.append(row)
        }
        ordered.append(contentsOf: current.filter { !seen.contains($0) })
        layout.setRows(of: nil, ordered)
    }

    // MARK: - The order functions

    /// Nested `normalizeWorkspaceGroupRunsPreservingOrder`: every top-level group's whole
    /// run, inner order kept, by rules 1 and 2 (WorkspaceGroupLayout.swift, "The six rules"). Writes `tabs`, and any parent id the tree repaired.
    /// (The order of groups is the sync function's to write.)
    func nestedNormalizeWorkspaceGroupRunsPreservingOrder(_ desiredIds: [UUID]) {
        var layout = nestedGroupLayout()
        nestedSetTopLevelOrder(&layout, desiredIds: desiredIds)
        applyGroupLayout(layout, writesGroupOrder: false)
    }

    /// Nested `syncWorkspaceGroupsOrderToAnchorOrder`: rule 4 (WorkspaceGroupLayout.swift, "The six rules"), both ways, per level.
    /// Handed an order, the groups follow their rows; handed none, the bare repair.
    func nestedSyncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: [UUID]?) {
        var layout = nestedGroupLayout()
        if let preferredTopLevelIds {
            nestedSetTopLevelOrder(&layout, desiredIds: preferredTopLevelIds)
            applyGroupLayout(layout, writesTabs: false, groupOrderRule: .followRows)
        } else {
            applyGroupLayout(layout, writesTabs: false, groupOrderRule: .keepSiblingSlot)
        }
    }

    /// Nested `expandWorkspaceGroupForSelectionIfNeeded`: opens the selected workspace's group
    /// and every group above it. A selected group header workspace keeps its own group as it is.
    func nestedExpandWorkspaceGroupForSelectionIfNeeded() {
        guard let selectedTabId,
              let groupId = tabs.first(where: { $0.id == selectedTabId })?.groupId else { return }
        let tree = nestedGroupTree()
        let own = workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId == selectedTabId
        for id in (own ? [] : [groupId]) + tree.ancestors(of: groupId) {
            if let index = workspaceGroups.firstIndex(where: { $0.id == id }), workspaceGroups[index].isCollapsed {
                workspaceGroups[index].isCollapsed = false
            }
        }
    }

    /// Nested `moveWorkspaceGroupMembersAfterAnchors`: each named workspace that is not its
    /// group's header goes first among the rows of its tier in its own group; nothing else moves.
    func nestedMoveWorkspaceGroupMembersAfterAnchors(workspaceIds: [UUID]) {
        var layout = nestedGroupLayout()
        var changed = false
        var seen = Set<UUID>()
        let named = workspaceIds.filter { seen.insert($0).inserted }
        // First named ends up first: apply from the last.
        for id in named.reversed() {
            guard let tab = tabs.first(where: { $0.id == id }), let groupId = tab.groupId,
                  workspaceGroups.first(where: { $0.id == groupId })?.anchorWorkspaceId != id else { continue }
            if layout.move(.workspace(id), to: groupId, at: .firstOfTier) == .moved { changed = true }
        }
        guard changed else { return }
        applyGroupLayout(layout, writesGroupOrder: false)
    }

    // MARK: - Reads

    /// Nested `topLevelWorkspaceIds(for:)`. A copy of `topLevelWorkspaceIds(for:)` in `WorkspacesModel+Ordering.swift` at
    /// fb9df71ba0 (v0.31.0), with one substitution: the group looked up for a grouped workspace is the outermost group
    /// that holds it, not the group it names.
    func nestedTopLevelWorkspaceIds(for workspaces: [Tab]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let outermost = outermostGroupIdsByGroupId()
        var emittedIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            let topLevelId: UUID
            if let groupId = workspace.groupId,
               let group = groupsById[outermost[groupId] ?? groupId] {
                topLevelId = group.anchorWorkspaceId
            } else {
                topLevelId = workspace.id
            }
            if emittedIds.insert(topLevelId).inserted {
                ids.append(topLevelId)
            }
        }
        return ids
    }

    /// Nested `sidebarTopLevelWorkspaceIds(promotingWorkspaceId:)`. A copy of that function in `WorkspacesModel+Ordering.swift`
    /// at fb9df71ba0 (v0.31.0), with one substitution: a grouped workspace stands for its outermost group (`topGroup`),
    /// where upstream uses the group it names.
    func nestedSidebarTopLevelWorkspaceIds(promotingWorkspaceId promotedWorkspaceId: UUID?) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let outermost = outermostGroupIdsByGroupId()
        func topGroup(_ groupId: UUID?) -> WorkspaceGroup? {
            groupId.flatMap { groupsById[outermost[$0] ?? $0] }
        }
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)
        for tab in tabs {
            if let group = topGroup(tab.groupId) {
                if emittedGroupIds.insert(group.id).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }
        if let promotedWorkspaceId,
           !ids.contains(promotedWorkspaceId),
           let tab = tabsById[promotedWorkspaceId],
           let group = topGroup(tab.groupId),
           let groupIndex = ids.firstIndex(of: group.anchorWorkspaceId) {
            ids.insert(
                promotedWorkspaceId,
                at: promotedTopLevelInsertionIndexForNested(
                    ids: ids,
                    groupIndex: groupIndex,
                    promotedIsPinned: tab.isPinned,
                    tabsById: tabsById,
                    groupsByAnchorId: groupsByAnchorId
                )
            )
        }
        return ids
    }

    /// A copy of the private `promotedTopLevelInsertionIndex` in `WorkspacesModel+Ordering.swift` at fb9df71ba0 (v0.31.0),
    /// unchanged. It is copied because upstream's is private; the name differs only so the two cannot be confused.
    private func promotedTopLevelInsertionIndexForNested(
        ids: [UUID],
        groupIndex: Int,
        promotedIsPinned: Bool,
        tabsById: [UUID: Tab],
        groupsByAnchorId: [UUID: WorkspaceGroup]
    ) -> Int {
        let desiredIndex = min(groupIndex + 1, ids.count)
        let pinnedCount = ids.reduce(into: 0) { count, id in
            if groupsByAnchorId[id]?.isPinned ?? (tabsById[id]?.isPinned == true) { count += 1 }
        }
        return promotedIsPinned ? min(desiredIndex, pinnedCount) : max(desiredIndex, pinnedCount)
    }

    /// Nested `topLevelWorkspaceIdsPreservingOrder(_:)`. A copy of that function in `WorkspacesModel+Ordering.swift` at
    /// fb9df71ba0 (v0.31.0), with one substitution: a grouped workspace stands for its outermost group, where upstream
    /// uses the group it names.
    func nestedTopLevelWorkspaceIdsPreservingOrder(_ desiredIds: [UUID]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let outermost = outermostGroupIdsByGroupId()
        var emittedWorkspaceIds = Set<UUID>()
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)

        func appendTopLevelId(for id: UUID) {
            guard let tab = tabsById[id],
                  emittedWorkspaceIds.insert(tab.id).inserted else { return }
            if let groupId = tab.groupId,
               let group = groupsById[outermost[groupId] ?? groupId] {
                if emittedGroupIds.insert(group.id).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }

        for id in desiredIds {
            appendTopLevelId(for: id)
        }
        for tab in tabs where !emittedWorkspaceIds.contains(tab.id) {
            appendTopLevelId(for: tab.id)
        }
        return ids
    }

    /// Nested `sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(preservingTopLevelIds:)`. A copy of that function in
    /// `WorkspacesModel+Ordering.swift` at fb9df71ba0 (v0.31.0), with one substitution: the groups placed by the list of
    /// groups are the top-level groups with no workspace anywhere inside them (`hasRun`), where upstream uses the groups
    /// marked empty.
    func nestedSidebarTopLevelWorkspaceIdsIncludingEmptyGroups(
        preservingTopLevelIds baseIds: [UUID]
    ) -> [UUID] {
        let tree = nestedGroupTree()
        let outermost = outermostGroupIdsByGroupId()
        var hasRun = Set<UUID>()
        for tab in tabs {
            if let groupId = tab.groupId, outermost[groupId] != nil {
                hasRun.formUnion([groupId])
                hasRun.formUnion(tree.ancestors(of: groupId))   // the outermost group is the last of these
            }
        }
        let topLevelGroups = workspaceGroups.filter { tree.parent(of: $0.id) == nil }
        let emptyGroups = topLevelGroups.filter { !hasRun.contains($0.id) }
        guard !emptyGroups.isEmpty else { return baseIds }

        let baseIdSet = Set(baseIds)
        var nextPinnedGroup: WorkspaceGroup?
        var nextUnpinnedGroup: WorkspaceGroup?
        var nextLiveSameTierById: [UUID: WorkspaceGroup?] = [:]
        for group in topLevelGroups.reversed() {
            nextLiveSameTierById[group.id] = group.isPinned ? nextPinnedGroup : nextUnpinnedGroup
            guard hasRun.contains(group.id) else { continue }
            if group.isPinned {
                nextPinnedGroup = group
            } else {
                nextUnpinnedGroup = group
            }
        }

        var emptyBeforeAnchor: [UUID: [UUID]] = [:]
        var trailingPinned: [UUID] = []
        var trailingUnpinned: [UUID] = []
        for group in emptyGroups {
            if let nextGroup = nextLiveSameTierById[group.id] ?? nil,
               baseIdSet.contains(nextGroup.anchorWorkspaceId) {
                emptyBeforeAnchor[nextGroup.anchorWorkspaceId, default: []].append(group.anchorWorkspaceId)
            } else if group.isPinned {
                trailingPinned.append(group.anchorWorkspaceId)
            } else {
                trailingUnpinned.append(group.anchorWorkspaceId)
            }
        }

        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        func isPinnedRow(_ id: UUID) -> Bool {
            groupsByAnchorId[id]?.isPinned ?? tabsById[id]?.isPinned ?? false
        }

        var ids: [UUID] = []
        ids.reserveCapacity(baseIds.count + emptyGroups.count)
        var emittedIds = Set<UUID>()
        for id in baseIds {
            for emptyId in emptyBeforeAnchor[id] ?? [] where emittedIds.insert(emptyId).inserted {
                ids.append(emptyId)
            }
            if emittedIds.insert(id).inserted {
                ids.append(id)
            }
        }
        if !trailingPinned.isEmpty {
            let firstUnpinnedIndex = ids.firstIndex { !isPinnedRow($0) } ?? ids.count
            let inserted = trailingPinned.filter { emittedIds.insert($0).inserted }
            ids.insert(contentsOf: inserted, at: firstUnpinnedIndex)
        }
        ids.append(contentsOf: trailingUnpinned.filter { emittedIds.insert($0).inserted })
        return ids
    }

    /// Nested `isGlobalPinnedRow(_:)`. A copy of that function in `WorkspacesModel+Ordering.swift` at fb9df71ba0
    /// (v0.31.0), with one substitution: the pin read is the outermost group's, where upstream reads the group the
    /// workspace names.
    func nestedIsGlobalPinnedRow(_ tab: Tab) -> Bool {
        if let groupId = tab.groupId {
            let outermost = outermostGroupIdsByGroupId()
            if let group = workspaceGroups.first(where: { $0.id == (outermost[groupId] ?? groupId) }) {
                return group.isPinned
            }
        }
        return tab.isPinned
    }

    /// Nested `clampedGroupedMemberReorderIndex(for:clampedTargetIndex:)`. A copy of that function in
    /// `WorkspacesModel+Ordering.swift` at fb9df71ba0 (v0.31.0), with one substitution: the range clamped to is the
    /// group's whole run (every workspace inside it at any level), where upstream uses the group's direct members. A
    /// member is held inside the run, after the workspace behind the group's name and inside its own pin tier among
    /// the group's direct members.
    func nestedClampedGroupedMemberReorderIndex(
        for workspace: Tab,
        clampedTargetIndex: Int
    ) -> Int? {
        guard let groupId = workspace.groupId,
              let group = workspaceGroups.first(where: { $0.id == groupId }),
              workspace.id != group.liveAnchorWorkspaceId else {
            return nil
        }
        let tree = nestedGroupTree()
        let runIndices = tabs.indices.filter { index in
            guard let id = tabs[index].groupId else { return false }
            return id == groupId || tree.isInside(id, groupId)
        }
        guard let firstIndex = runIndices.first, let lastIndex = runIndices.last else { return nil }
        let pinnedMemberCount = runIndices.reduce(into: 0) { count, index in
            let member = tabs[index]
            if member.groupId == groupId, member.id != group.liveAnchorWorkspaceId, member.isPinned {
                count += 1
            }
        }
        let lowerBound = workspace.isPinned
            ? min(firstIndex + 1, lastIndex)
            : min(firstIndex + 1 + pinnedMemberCount, lastIndex)
        let upperBound = workspace.isPinned
            ? max(firstIndex + pinnedMemberCount, lowerBound)
            : lastIndex
        return min(max(clampedTargetIndex, lowerBound), upperBound)
    }
}
