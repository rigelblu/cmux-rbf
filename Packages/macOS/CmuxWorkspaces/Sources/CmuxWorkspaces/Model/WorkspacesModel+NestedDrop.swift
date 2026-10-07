import Foundation

// The nested commit of a sidebar drop (#cm-106). The drop planner (in `CmuxFoundation`) names a place as an index into
// `tabs` plus the group that holds it. Each function here checks that place against the live tree, reads the layout,
// moves the rows, and writes once, only when an edit applied. A plan can be older than the model: it was made from a
// drawing pass, and the AppKit table commits one made while hovering. So a place that is no longer a boundary between
// two of the group's own rows, or a group that is gone or no longer holds the row, refuses the drop and changes nothing.
extension WorkspacesModel {
    enum NestedDropResult: Equatable {
        /// The plan no longer fits the model. Nothing changed.
        case refused
        /// The plan fits and the rows are already there.
        case unchanged
        case moved
    }

    /// Where a row starts in `remaining` (`tabs` with every moving row taken out), or nil when it has no workspace inside.
    private func nestedRowStart(
        _ row: WorkspaceGroupLayout.Row,
        in remaining: [UUID]
    ) -> Int? {
        switch row {
        case .workspace(let id):
            return remaining.firstIndex(of: id)
        case .group(let id):
            let inside = Set(workspaceIdsInside(id))
            return remaining.firstIndex { inside.contains($0) }
        }
    }

    /// The boundaries of a level, as indexes into `remaining`, over the rows that stay put: the start of each such row,
    /// the end of the last, and the start of the level's rows.
    private func nestedLegalPlaces(
        level: UUID,
        staying rows: [WorkspaceGroupLayout.Row],
        in remaining: [UUID]
    ) -> Set<Int> {
        var places = Set<Int>()
        for row in rows {
            guard let start = nestedRowStart(row, in: remaining) else { continue }
            places.insert(start)
            let length: Int
            switch row {
            case .workspace:
                length = 1
            case .group(let id):
                length = workspaceIdsInside(id).filter { remaining.contains($0) }.count
            }
            places.insert(start + length)
        }
        if let own = workspaceGroups.first(where: { $0.id == level })?.liveAnchorWorkspaceId,
           let anchorIndex = remaining.firstIndex(of: own) {
            places.insert(anchorIndex + 1)
        } else {
            let inside = Set(workspaceIdsInside(level))
            if let first = remaining.firstIndex(where: { inside.contains($0) }) { places.insert(first) }
        }
        return places
    }

    /// The row a moving row goes directly below: the row before `reference` among the rows that stay, else the last row
    /// that stays when nothing stays at or after the place.
    private func nestedRowBefore(
        staying: [WorkspaceGroupLayout.Row],
        reference: WorkspaceGroupLayout.Row?
    ) -> WorkspaceGroupLayout.Row? {
        guard let reference else { return staying.last }
        guard let index = staying.firstIndex(of: reference), index > 0 else { return nil }
        return staying[index - 1]
    }

    /// Moves rows, in the order given, to one level at one place: each row of a pin tier directly below the previous row of
    /// the same tier, the first of a tier directly below `rowBefore`; the layout then holds a row of the other tier to its
    /// own tier, so a pinned row dropped among unpinned ones goes to the end of the pinned rows and an unpinned one dropped
    /// among pinned ones goes first of the unpinned rows, as a flat window does it. Returns false when a move is refused.
    private func nestedMoveRows(
        _ rows: [WorkspaceGroupLayout.Row],
        in layout: inout WorkspaceGroupLayout,
        to level: UUID?,
        below rowBefore: WorkspaceGroupLayout.Row?
    ) -> Bool {
        var previousOfTier: [Bool: WorkspaceGroupLayout.Row] = [:]
        for row in rows {
            let tier = layout.isPinned(row)
            let place: WorkspaceGroupLayout.Place
            if let previous = previousOfTier[tier] {
                place = .directlyBelow(previous)
            } else if let rowBefore {
                place = .directlyBelow(rowBefore)
            } else {
                place = .index(0)
            }
            guard layout.move(row, to: level, at: place) == .moved else { return false }
            previousOfTier[tier] = row
        }
        return true
    }

    /// Group rows dropped inside their parent: one layout edit per group, in sidebar order, then one write.
    ///
    /// `targetIndex` is an index into `tabs` with every moving group's whole stretch taken out. Every group must sit in
    /// `parent` now. Returns `.refused` when a group is gone or sits elsewhere, or when the place is not a boundary
    /// between two of `parent`'s rows that stay.
    func nestedDropGroupRows(groupIds movingGroupIds: [UUID], grabbed: UUID, parent: UUID, toIndex targetIndex: Int) -> NestedDropResult {
        let tree = nestedGroupTree()
        guard workspaceGroups.contains(where: { $0.id == parent }),
              movingGroupIds.contains(grabbed),
              movingGroupIds.allSatisfy({ id in workspaceGroups.contains { $0.id == id } && tree.parent(of: id) == parent })
        else { return .refused }

        let movingInside = Set(movingGroupIds.flatMap { workspaceIdsInside($0) })
        let remaining = tabs.map(\.id).filter { !movingInside.contains($0) }
        guard targetIndex >= 0, targetIndex <= remaining.count else { return .refused }

        var layout = nestedGroupLayout()
        let moving = Set(movingGroupIds.map { WorkspaceGroupLayout.Row.group($0) })
        let staying = layout.rows(of: parent).filter { !moving.contains($0) }
        guard nestedLegalPlaces(level: parent, staying: staying, in: remaining).contains(targetIndex) else {
            return .refused
        }
        // The first row that stays at or after the place; the movers go directly before it.
        let reference = staying.first { row in
            nestedRowStart(row, in: remaining).map { $0 >= targetIndex } ?? false
        }
        // Where each moving group's run starts in `tabs`, read once with the tree built above, not once per comparison.
        let runStart = Dictionary(
            movingGroupIds.map { groupId in
                (groupId, tabs.firstIndex { tab in tab.groupId.map { $0 == groupId || tree.isInside($0, groupId) } ?? false } ?? Int.max)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let ordered = movingGroupIds.sorted { (runStart[$0] ?? Int.max) < (runStart[$1] ?? Int.max) }
        let before = layout.output()
        guard nestedMoveRows(
            ordered.map { WorkspaceGroupLayout.Row.group($0) },
            in: &layout, to: parent,
            below: nestedRowBefore(staying: staying, reference: reference)
        ) else { return .refused }
        let after = layout.output()
        if after.tabOrder == tabs.map(\.id), after.parentByGroup == before.parentByGroup, after.groupOrder == workspaceGroups.map(\.id) {
            return .unchanged
        }
        applyGroupLayout(layout)
        return .moved
    }

    /// Workspaces dropped into a group: every one goes to that level, as row moves in sidebar order, then one write.
    /// (A drop at the top level is `nestedDropWorkspacesToTopLevel`.)
    ///
    /// `targetIndex` is an index into `tabs` with every moving workspace taken out. A group with no workspace of its own
    /// takes the first workspace as its own. Returns `.refused` when the group is gone, a workspace is gone or stands
    /// behind a group's name, or the place is not a boundary between two of the level's rows that stay.
    func nestedDropWorkspaces(_ movingIds: [UUID], grabbed: UUID, intoGroup groupId: UUID, toIndex targetIndex: Int) -> NestedDropResult {
        guard let group = workspaceGroups.first(where: { $0.id == groupId }),
              movingIds.contains(grabbed),
              movingIds.allSatisfy({ id in tabs.contains { $0.id == id } && !workspaceGroups.contains { $0.liveAnchorWorkspaceId == id } })
        else { return .refused }

        let tree = nestedGroupTree()
        let movingSet = Set(movingIds)
        let remaining = tabs.map(\.id).filter { !movingSet.contains($0) }
        guard targetIndex >= 0, targetIndex <= remaining.count else { return .refused }

        var layout = nestedGroupLayout()
        let moving = Set(movingIds.map { WorkspaceGroupLayout.Row.workspace($0) })
        let ordered = tabs.map(\.id).filter(movingSet.contains)
        let rows = ordered.map { WorkspaceGroupLayout.Row.workspace($0) }
        let before = layout.output()
        let beforeGroups = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.groupId) })

        if group.liveAnchorWorkspaceId == nil {
            // A group with no workspace of its own: the first workspace stands behind its name, the rest are its rows.
            guard layout.move(rows[0], to: groupId, at: .index(0)) == .moved,
                  nestedMoveRows(Array(rows.dropFirst()), in: &layout, to: groupId, below: nil) else { return .refused }
        } else {
            let staying = layout.rows(of: groupId).filter { !moving.contains($0) }
            guard nestedLegalPlaces(level: groupId, staying: staying, in: remaining).contains(targetIndex) else {
                return .refused
            }
            let reference = staying.first { row in
                nestedRowStart(row, in: remaining).map { $0 >= targetIndex } ?? false
            }
            guard nestedMoveRows(rows, in: &layout, to: groupId, below: nestedRowBefore(staying: staying, reference: reference)) else {
                return .refused
            }
        }
        return nestedFinishWorkspaceDrop(layout: layout, before: before, beforeGroups: beforeGroups, ordered: ordered)
    }

    /// Workspaces dropped at the top level directly before the top-level row `rowId` (a loose workspace, or the
    /// workspace or header identity a group stands behind, or the first workspace of a group's stretch), or at the end when nil. Every one goes to the top level, as
    /// row moves in sidebar order, then one write. Returns `.refused` when the row is not a top-level row that stays.
    func nestedDropWorkspacesToTopLevel(_ movingIds: [UUID], grabbed: UUID, before rowId: UUID?) -> NestedDropResult {
        guard movingIds.contains(grabbed),
              movingIds.allSatisfy({ id in tabs.contains { $0.id == id } && !workspaceGroups.contains { $0.liveAnchorWorkspaceId == id } })
        else { return .refused }
        var layout = nestedGroupLayout()
        let movingSet = Set(movingIds)
        let moving = Set(movingIds.map { WorkspaceGroupLayout.Row.workspace($0) })
        let staying = layout.rows(of: nil).filter { !moving.contains($0) }
        var reference: WorkspaceGroupLayout.Row?
        if let rowId {
            reference = staying.first { row in
                switch row {
                case .workspace(let id): return id == rowId
                case .group(let id): return workspaceGroups.first { $0.id == id }?.anchorWorkspaceId == rowId
                }
            }
            if reference == nil {
                // A workspace inside a group stands for the outermost group that holds it, when it is the first workspace
                // of that group's stretch (the place is then directly before the group).
                let tree = nestedGroupTree()
                if let groupId = tabs.first(where: { $0.id == rowId })?.groupId, tree.contains(groupId) {
                    let outermost = tree.outermost(of: groupId)
                    let inside = Set(workspaceIdsInside(outermost))
                    if tabs.first(where: { inside.contains($0.id) })?.id == rowId {
                        reference = staying.first { $0 == .group(outermost) }
                    }
                }
            }
            guard reference != nil else { return .refused }
        }
        let ordered = tabs.map(\.id).filter(movingSet.contains)
        let before = layout.output()
        let beforeGroups = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.groupId) })
        guard nestedMoveRows(
            ordered.map { WorkspaceGroupLayout.Row.workspace($0) },
            in: &layout, to: nil,
            below: nestedRowBefore(staying: staying, reference: reference)
        ) else { return .refused }
        return nestedFinishWorkspaceDrop(layout: layout, before: before, beforeGroups: beforeGroups, ordered: ordered)
    }

    private func nestedFinishWorkspaceDrop(
        layout: WorkspaceGroupLayout,
        before: WorkspaceGroupLayout.Output,
        beforeGroups: [UUID: UUID?],
        ordered: [UUID]
    ) -> NestedDropResult {
        let after = layout.output()
        let unchangedGroups = ordered.allSatisfy { after.groupIdByWorkspace[$0] == beforeGroups[$0] }
        if after.tabOrder == tabs.map(\.id), unchangedGroups, after.anchorByGroup == before.anchorByGroup {
            return .unchanged
        }
        applyGroupLayout(layout)
        return .moved
    }
}
