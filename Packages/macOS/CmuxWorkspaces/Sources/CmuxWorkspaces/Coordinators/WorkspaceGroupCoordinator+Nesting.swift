public import Foundation
import CmuxSettings
internal import OSLog

private let nestedGroupLogger = Logger(subsystem: "com.cmuxterm.app", category: "WorkspaceGroupNesting")

// The nested versions of the group coordinator's operations (#cm-106). Each upstream function in
// `WorkspaceGroupCoordinator.swift` and `+DeletionConfirmation.swift` hands over here with one line
// when the window holds a nested group. A window with no nested group reaches three things here, and no more:
// `nestedPlaceNewWorkspaceGroup` (every new group goes through it; it makes the window's first nested group when the
// first workspace the new group takes sits in a group), `moveMenu(for:)` (a header asks for its menu in every window)
// and `moveWorkspaceGroup(groupId:intoParent:)` (the menu's action; it makes the first nested group from the menu).
//
// An operation that changes a row's level or place reads the layout from what is stored, edits it,
// and writes it back once; it writes only when an edit applied.
extension WorkspaceGroupCoordinator {
    // MARK: - A new group made in place

    /// The nested `createWorkspaceGroup`, after the group and its own workspace are stored. When the first eligible
    /// workspace in sidebar order sits in a group, the new group's row goes into that group at that workspace's
    /// place, and each eligible workspace then moves into it in sidebar order: read the layout, two kinds of edit,
    /// write once. A group made from grouped workspaces so stays inside the group. Returns false, having changed
    /// nothing, when the first eligible workspace sits in no group; upstream's assignment and placement then run.
    ///
    /// The new group already has its own workspace here, so the layout reads it as a group with a run and does not
    /// snap it back to the place rule 4 (WorkspaceGroupLayout.swift, "The six rules") gives a group with none.
    @discardableResult
    func nestedPlaceNewWorkspaceGroup(groupId: UUID, anchorId: UUID, eligibleChildren: [UUID]) -> Bool {
        let eligible = Set(eligibleChildren)
        guard !eligible.isEmpty,
              let first = model.tabs.first(where: { eligible.contains($0.id) }),
              let holder = first.groupId,
              model.workspaceGroups.contains(where: { $0.id == holder }) else { return false }
        var layout = model.nestedGroupLayout()
        let level = layout.level(of: .workspace(first.id)) ?? nil
        guard let index = layout.rows(of: level).firstIndex(of: .workspace(first.id)) else { return false }
        guard layout.move(.group(groupId), to: level, at: .index(index)) == .moved else { return false }
        for tab in model.tabs where eligible.contains(tab.id) {
            guard layout.move(.workspace(tab.id), to: groupId, at: .lastOfTier) == .moved else { continue }
        }
        model.applyGroupLayout(layout)
        if model.selectedTabId == anchorId { model.expandWorkspaceGroupForSelectionIfNeeded() }
        return true
    }

    // MARK: - Move Group to

    /// What `Move Group to` offers a group: `Top Level`, then every group it may go into, each with its depth,
    /// the group's current place ticked. A header asks for it in every window, flat or not.
    public func moveMenu(for groupId: UUID) -> WorkspaceGroupMoveMenu? {
        WorkspaceGroupMoveMenu.menu(for: groupId, groups: model.workspaceGroupsParentFirst())
    }

    /// `Move Group to`: puts a group inside another group, or at the top level when `parentId` is nil. Reads the
    /// layout, moves the group's row, writes once, and only when it moved. It has no switch: it is how the first
    /// nested group in a window is made. A refused move changes nothing.
    ///
    /// Into a group, the group is the last row of its pin tier there. To the top level, it sits directly below the
    /// top-level row it came out of; a pinned group is the last of the pinned rows, and an unpinned group that
    /// leaves a pinned row is the first of the unpinned rows. A group with no workspace inside cannot sit between
    /// two workspaces: it is listed where its row was put and drawn by rule 4 (WorkspaceGroupLayout.swift, "The six rules").
    @discardableResult
    public func moveWorkspaceGroup(groupId: UUID, intoParent parentId: UUID?) -> WorkspaceGroupMoveIntoResult {
        let result = moveWorkspaceGroupIntoParent(groupId: groupId, parentId: parentId)
        switch result {
        case .moved, .unchanged:
            break
        case .groupNotFound, .destinationNotFound, .destinationIsSelfOrInside:
            logNestedRefusal("Move Group to refused (\(result)): group \(groupId.uuidString), destination \(parentId?.uuidString ?? "top level")")
        }
        return result
    }

    /// One line for a refused nested move: to the app log at debug level and, in a debug build, to the test seam. Nothing is shown to the user.
    func logNestedRefusal(_ line: String) {
        nestedGroupLogger.debug("\(line, privacy: .public)")
#if DEBUG
        model.nestedGroupLog?(line)
#endif
    }

    private func moveWorkspaceGroupIntoParent(groupId: UUID, parentId: UUID?) -> WorkspaceGroupMoveIntoResult {
        guard let group = model.workspaceGroups.first(where: { $0.id == groupId }) else { return .groupNotFound }
        if let parentId, !model.workspaceGroups.contains(where: { $0.id == parentId }) { return .destinationNotFound }
        let tree = model.nestedGroupTree()
        if let parentId, parentId == groupId || tree.isInside(parentId, groupId) { return .destinationIsSelfOrInside }
        let current = tree.parent(of: groupId)
        if current == parentId { return .unchanged }

        var layout = model.nestedGroupLayout()
        let place: WorkspaceGroupLayout.Place
        if parentId != nil {
            place = .lastOfTier
        } else {
            // Out to the top level: below the top-level row it came out of, within its own pin tier.
            let cameOutOf = WorkspaceGroupLayout.Row.group(tree.outermost(of: groupId))
            if group.isPinned {
                place = .lastOfTier
            } else if layout.isPinned(cameOutOf) {
                place = .firstOfTier
            } else {
                place = .directlyBelow(cameOutOf)
            }
        }
        switch layout.move(.group(groupId), to: parentId, at: place) {
        case .moved:
            break
        case .rowNotFound:
            return .groupNotFound
        case .destinationNotFound:
            return .destinationNotFound
        case .destinationIsSelfOrInside:
            return .destinationIsSelfOrInside
        case .standsBehindGroupName:
            return .groupNotFound
        }
        model.applyGroupLayout(layout)
        // The destination opens only if the moved group holds the selected workspace.
        if let selected = model.selectedTabId,
           let selectedGroup = model.tabs.first(where: { $0.id == selected })?.groupId,
           selectedGroup == groupId || model.nestedGroupTree().isInside(selectedGroup, groupId) {
            model.expandWorkspaceGroupForSelectionIfNeeded()
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: model.workspaceIdsInside(groupId))
        return .moved
    }

    // MARK: - Landing rules

    /// Where a workspace added to a group lands among the group's rows.
    func nestedPlace(
        for placement: WorkspaceGroupNewPlacement?,
        groupId: UUID,
        referenceWorkspaceId: UUID?,
        workspaceId: UUID? = nil
    ) -> WorkspaceGroupLayout.Place {
        guard let placement else {
            // No place named: as today, first when the workspace came from above the group, last when from below.
            let tree = model.nestedGroupTree()
            let runStart = model.tabs.firstIndex { tab in
                guard let id = tab.groupId else { return false }
                return id == groupId || tree.isInside(id, groupId)
            }
            if let workspaceId, let runStart, let index = model.tabs.firstIndex(where: { $0.id == workspaceId }), index < runStart {
                return .firstOfTier
            }
            return .afterLastWorkspaceOfTier
        }
        switch placement {
        case .afterCurrent:
            // The workspace behind the group's name is not a row: right after it is the first row.
            let isHeader = model.workspaceGroups.first { $0.id == groupId }?.liveAnchorWorkspaceId == referenceWorkspaceId
            if let referenceWorkspaceId, !isHeader,
               model.tabs.contains(where: { $0.id == referenceWorkspaceId && $0.groupId == groupId }) {
                return .directlyBelow(.workspace(referenceWorkspaceId))
            }
            return .firstOfTier
        case .top:
            return .firstOfTier
        case .end:
            return .afterLastWorkspaceOfTier
        }
    }

    /// Reads the layout, moves one workspace into a group, writes once. Returns whether it moved.
    @discardableResult
    func nestedMoveWorkspace(_ workspaceId: UUID, toGroup groupId: UUID?, at place: WorkspaceGroupLayout.Place) -> Bool {
        var layout = model.nestedGroupLayout()
        guard layout.move(.workspace(workspaceId), to: groupId, at: place) == .moved else { return false }
        model.applyGroupLayout(layout)
        return true
    }

    // MARK: - Membership

    func nestedAddWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement?,
        referenceWorkspaceId: UUID?
    ) {
        let place = nestedPlace(for: placement, groupId: groupId, referenceWorkspaceId: referenceWorkspaceId, workspaceId: workspaceId)
        guard nestedMoveWorkspace(workspaceId, toGroup: groupId, at: place) else { return }
        // A nested window shows the selection only when the reassigned workspace is the selected one.
        if model.selectedTabId == workspaceId { model.expandWorkspaceGroupForSelectionIfNeeded() }
        host?.workspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    func nestedRemoveWorkspaceFromGroup(workspaceId: UUID, groupId: UUID) {
        let parent = model.parentGroupIdIfNested(of: groupId)
        guard nestedMoveWorkspace(workspaceId, toGroup: parent, at: .directlyBelow(.group(groupId))) else { return }
        host?.workspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    func nestedPlaceNewWorkspace(
        _ newWorkspace: Tab,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?
    ) {
        let place = nestedPlace(for: placement, groupId: groupId, referenceWorkspaceId: referenceWorkspaceId)
        nestedMoveWorkspace(newWorkspace.id, toGroup: groupId, at: place)
        if model.selectedTabId == newWorkspace.id { model.expandWorkspaceGroupForSelectionIfNeeded() }
        host?.workspaceOrderDidChange(movedWorkspaceIds: [newWorkspace.id])
    }

    // MARK: - Ungroup

    /// Nested Ungroup: each direct workspace (the one behind the name included) takes the group's
    /// parent, each child group takes the group's parent as its own, and the group is removed.
    /// "Holds nothing" counts child groups, so a pinned header with groups inside can be ungrouped.
    func nestedUngroupWorkspaceGroup(group: WorkspaceGroup) -> WorkspaceGroupUngroupResult {
        let tree = model.nestedGroupTree()
        let childGroupIds = tree.children(of: group.id)
        let parent = tree.parent(of: group.id)
        let memberIds = model.tabs.filter { $0.groupId == group.id }.map(\.id)
        // Read before the group is removed: every workspace inside, at every level, takes a new place with it.
        let insideIds = model.workspaceIdsInside(group.id)
        guard !memberIds.isEmpty || !childGroupIds.isEmpty || !group.isPinned else {
            return .emptyPinnedCannotUngroup
        }
        for tab in model.tabs where tab.groupId == group.id {
            tab.groupId = parent
        }
        var groups = model.workspaceGroups
        for index in groups.indices where childGroupIds.contains(groups[index].id) {
            groups[index].parentGroupId = parent
        }
        groups.removeAll { $0.id == group.id }
        model.workspaceGroups = groups
        model.giveGroupItsFirstOwnWorkspaceIfNeeded(parent)
        // The rows keep the places the run held; the repair splits each level by tier.
        model.normalizeWorkspaceGroupContiguity()
        host?.workspaceOrderDidChange(movedWorkspaceIds: insideIds)
        return .dissolved(keptWorkspaceCount: memberIds.count)
    }

    // MARK: - Fold

    /// Nested fold: the hidden rows are everything inside the group, at every level.
    func nestedToggleWorkspaceGroupCollapsed(groupId: UUID) {
        guard let host else { return }
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        let nextCollapsed = !model.workspaceGroups[index].isCollapsed
        if nextCollapsed {
            let tree = model.nestedGroupTree()
            let inside = Set([groupId] + tree.descendants(of: groupId))
            let anchorId = model.workspaceGroups[index].liveAnchorWorkspaceId
            let hiddenIds = Set(
                model.tabs
                    .filter { tab in tab.groupId.map(inside.contains) == true && tab.id != anchorId }
                    .map(\.id)
            )
            // The selection moves to the group's own workspace, and stays where it is when there is none.
            if let anchorId,
               let selectedTabId = model.selectedTabId,
               hiddenIds.contains(selectedTabId),
               let anchor = model.tabs.first(where: { $0.id == anchorId }) {
                host.selectWorkspace(anchor)
            }
            // Dropped from the multi-selection whether or not the group has a workspace of its own.
            if !hiddenIds.isEmpty, !host.sidebarSelectedWorkspaceIds.isDisjoint(with: hiddenIds) {
                let focusedWorkspaceId: UUID? = (anchorId != nil && model.selectedTabId == anchorId) ? anchorId : nil
                host.subtractSidebarSelection(hiddenWorkspaceIds: hiddenIds, focusedWorkspaceId: focusedWorkspaceId)
            }
        }
        setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: nextCollapsed)
    }

    // MARK: - Reorder among the groups beside

    /// Nested `moveWorkspaceGroup(groupId:toIndex:)`: the target is the group at that index of the list of
    /// groups, and the move is the layout's reorder among the groups beside it. A target that sits in
    /// another parent is not among the group's siblings, so nothing moves.
    func nestedMoveWorkspaceGroup(groupId: UUID, toIndex targetIndex: Int) {
        _ = moveWorkspaceGroupReportingResult(groupId: groupId, toIndex: targetIndex)
    }

    /// The same move, saying what happened: `.moved`, `.unchanged` (the group already sat there), or a refusal. The
    /// socket uses it in a window with a nested group to tell a refused target from a move; it answers `.unchanged`
    /// as plain success, the same payload as `.moved`, as the base release answered a move that changed nothing.
    public func moveWorkspaceGroupReportingResult(groupId: UUID, toIndex targetIndex: Int) -> WorkspaceGroupMoveBesideResult {
        let groups = model.workspaceGroups
        guard groups.contains(where: { $0.id == groupId }), !groups.isEmpty else { return .groupNotFound }
        let tree = model.nestedGroupTree()
        let parent = tree.parent(of: groupId)
        let siblings = tree.children(of: parent)
        // An index past either end is the nearest slot among the groups beside it, as today.
        let siblingIndex: Int
        if targetIndex < 0 {
            siblingIndex = 0
        } else if targetIndex > groups.count - 1 {
            siblingIndex = siblings.count - 1
        } else if let index = siblings.firstIndex(of: groups[targetIndex].id) {
            siblingIndex = index
        } else {
            logNestedRefusal("Move by index refused (targetNotBeside): group \(groupId.uuidString), index \(targetIndex)")
            return .targetNotBeside
        }
        var layout = model.nestedGroupLayout()
        guard layout.moveGroupInList(groupId, toSiblingIndex: siblingIndex) else { return .unchanged }
        model.applyGroupLayout(layout)
        // Every workspace inside the moved group, at every level, changed place with it.
        host?.workspaceOrderDidChange(movedWorkspaceIds: model.workspaceIdsInside(groupId))
        return .moved
    }

    /// `workspace.group.move --before` or `--after`: puts a group directly before or after a group beside it,
    /// after that group's whole run. The target must sit in the same parent. Reads the layout, moves the group's
    /// row among the groups beside it, writes once, and only when it moved; says what happened.
    public func moveWorkspaceGroup(groupId: UUID, beside siblingId: UUID, after: Bool) -> WorkspaceGroupMoveBesideResult {
        guard model.workspaceGroups.contains(where: { $0.id == groupId }) else { return .groupNotFound }
        guard model.workspaceGroups.contains(where: { $0.id == siblingId }) else { return .targetNotFound }
        let tree = model.nestedGroupTree()
        let parent = tree.parent(of: groupId)
        guard tree.parent(of: siblingId) == parent else {
            logNestedRefusal("Move beside refused (targetNotBeside): group \(groupId.uuidString), target \(siblingId.uuidString)")
            return .targetNotBeside
        }
        if siblingId == groupId { return .unchanged }
        let siblings = tree.children(of: parent)
        guard let from = siblings.firstIndex(of: groupId), let at = siblings.firstIndex(of: siblingId) else { return .groupNotFound }
        // The final position among the groups beside it, as `moveGroupInList` reads it.
        let final = after ? (from < at ? at : at + 1) : (from < at ? at - 1 : at)
        var layout = model.nestedGroupLayout()
        guard layout.moveGroupInList(groupId, toSiblingIndex: final) else { return .unchanged }
        model.applyGroupLayout(layout)
        // Every workspace inside the moved group, at every level, changed place with it.
        host?.workspaceOrderDidChange(movedWorkspaceIds: model.workspaceIdsInside(groupId))
        return .moved
    }

    // MARK: - Delete

    /// Nested confirmation: every workspace inside, at every level, and the id of every group inside.
    func nestedDeletionConfirmation(group: WorkspaceGroup) -> WorkspaceGroupDeletionConfirmation {
        let tree = model.nestedGroupTree()
        let insideGroupIds = tree.descendants(of: group.id)
        let inside = Set([group.id] + insideGroupIds)
        let liveAnchorId = group.liveAnchorWorkspaceId
        let includesAnchorWorkspace = liveAnchorId.map { anchorId in
            model.tabs.contains { $0.id == anchorId }
        } ?? false
        var memberWorkspaceIds: [UUID] = {
            guard includesAnchorWorkspace, let liveAnchorId else { return [] }
            return [liveAnchorId]
        }()
        memberWorkspaceIds.append(
            contentsOf: model.tabs.compactMap { tab in
                guard let groupId = tab.groupId, inside.contains(groupId), tab.id != liveAnchorId else { return nil }
                return tab.id
            }
        )
        return WorkspaceGroupDeletionConfirmation(
            groupId: group.id,
            groupName: group.name,
            anchorWorkspaceId: group.anchorWorkspaceId,
            includesAnchorWorkspace: includesAnchorWorkspace,
            memberWorkspaceIds: memberWorkspaceIds,
            containedGroupIds: insideGroupIds,
            takenInNestedWindow: true
        )
    }

    /// Nested Delete Group: closes only the confirmed workspaces that are still inside the group when
    /// Delete is pressed, innermost groups first and each group's own workspace after its others, the
    /// deleted group's own last. If the group is gone nothing closes. A workspace that joined meanwhile
    /// goes to the group that held the deleted one, or to the top level.
    func nestedDeleteWorkspaceGroup(
        confirmed confirmation: WorkspaceGroupDeletionConfirmation,
        recordHistory: Bool
    ) -> Int {
        guard let host else { return 0 }
        guard model.workspaceGroups.contains(where: { $0.id == confirmation.groupId }) else { return 0 }
        // What the window looked like when Delete was pressed, to name the workspaces that took a new place or group.
        let orderAtPress = model.tabs.map(\.id)
        let groupAtPress = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.groupId) })
        let tree = model.nestedGroupTree()
        let parentOfDeleted = tree.parent(of: confirmation.groupId)
        let confirmedIds = Set(confirmation.memberWorkspaceIds)
        // The groups the question named, still inside. A group that joined the area while it was open was
        // not named: it is not deleted, and goes to the group that held the deleted one, or to the top level.
        // What was named and now sits inside such a late group is left alone too, group or workspace.
        // `descendants` lists a parent before its children, so one pass sees each parent first.
        let confirmedGroupIds = Set(confirmation.containedGroupIds)
        let liveDescendants = tree.descendants(of: confirmation.groupId)
        var insideGroups: Set<UUID> = [confirmation.groupId]
        for groupId in liveDescendants {
            if confirmedGroupIds.contains(groupId), let parent = tree.parent(of: groupId), insideGroups.contains(parent) {
                insideGroups.insert(groupId)
            }
        }
        let lateGroupIds = liveDescendants.filter { !confirmedGroupIds.contains($0) }
        // The order groups close in is fixed: the deepest level first, the groups of one level in the order they stand in
        // the sidebar, and the deleted group last (it is the shallowest of them).
        let layout = model.nestedGroupLayout()
        func insideGroupsInSidebarOrder(_ level: UUID?) -> [UUID] {
            layout.rows(of: level).flatMap { row -> [UUID] in
                guard case .group(let id) = row, insideGroups.contains(id) else { return [] }
                return [id] + insideGroupsInSidebarOrder(id)
            }
        }
        let walked = insideGroupsInSidebarOrder(tree.parent(of: confirmation.groupId))
        // A group the walk did not reach (none should be missed) still closes, after the others of its level.
        let inSidebarOrder = walked + ([confirmation.groupId] + liveDescendants).filter { insideGroups.contains($0) && !walked.contains($0) }
        let depthOfInsideGroup = Dictionary(inSidebarOrder.map { ($0, tree.depth(of: $0)) }, uniquingKeysWith: { first, _ in first })
        let deepestFirst = Set(depthOfInsideGroup.values).sorted(by: >).flatMap { depth in
            inSidebarOrder.filter { depthOfInsideGroup[$0] == depth }
        }

        // A confirmed workspace closes only while it is still inside a group being deleted. The loops below
        // visit only such groups, so this is a guard against a caller that hands a wider set.
        func closable(_ tab: Tab) -> Bool {
            confirmedIds.contains(tab.id) && tab.groupId.map(insideGroups.contains) == true
        }
        func close(_ tab: Tab) -> Bool {
            if model.tabs.count <= 1 {
                _ = host.createWorkspaceForGroup(
                    title: nil,
                    workingDirectory: nil,
                    initialSurface: .terminal,
                    initialBrowserURL: nil,
                    initialBrowserOmnibarVisible: false,
                    initialBrowserTransparentBackground: false,
                    inheritWorkingDirectory: true,
                    select: true,
                    applyCreationTitleAsCustomTitle: true
                )
            }
            let countBefore = model.tabs.count
            host.closeWorkspaceForGroupDeletion(tab, recordHistory: recordHistory)
            return model.tabs.count < countBefore
        }

        var closed = 0
        for groupId in deepestFirst {
            // The workspace behind the name is read afresh: an earlier close can pass it on.
            let others = model.tabs.filter { tab in
                tab.groupId == groupId && closable(tab)
                    && tab.id != model.workspaceGroups.first(where: { $0.id == groupId })?.liveAnchorWorkspaceId
            }
            for tab in others where close(tab) { closed += 1 }
            if let ownId = model.workspaceGroups.first(where: { $0.id == groupId })?.liveAnchorWorkspaceId,
               let own = model.tabs.first(where: { $0.id == ownId }), closable(own), close(own) {
                closed += 1
            }
        }

        for tab in model.tabs where tab.groupId.map(insideGroups.contains) == true {
            tab.groupId = parentOfDeleted
        }
        var groups = model.workspaceGroups
        for index in groups.indices where lateGroupIds.contains(groups[index].id) {
            if let parent = tree.parent(of: groups[index].id), insideGroups.contains(parent) {
                groups[index].parentGroupId = parentOfDeleted
            }
        }
        groups.removeAll { insideGroups.contains($0.id) }
        model.workspaceGroups = groups
        model.giveGroupItsFirstOwnWorkspaceIfNeeded(parentOfDeleted)
        model.normalizeWorkspaceGroupContiguity()
        // The confirmed workspaces, and every workspace left that joined meanwhile and went up a group, or whose place among
        // the workspaces left changed (a group that joined meanwhile and went up takes its run with it).
        let left = model.tabs.map(\.id)
        let leftSet = Set(left)
        let placeAtPress = Dictionary(uniqueKeysWithValues: orderAtPress.filter(leftSet.contains).enumerated().map { ($1, $0) })
        let tookANewPlace = left.enumerated().compactMap { index, id -> UUID? in
            let changedGroup = (groupAtPress[id] ?? nil) != model.tabs[index].groupId
            return changedGroup || placeAtPress[id] != index ? id : nil
        }
        let named = Set(confirmation.memberWorkspaceIds)
        host.workspaceOrderDidChange(movedWorkspaceIds: confirmation.memberWorkspaceIds + tookANewPlace.filter { !named.contains($0) })
        return closed
    }
}
