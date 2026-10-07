public import Foundation

// MARK: - The layout rules and the words (#cm-106)
//
// Nested workspace groups: a workspace group can sit inside another one. The rest of the code cites these rules
// by number ("rule 4"). They describe a window that is at rest, and `WorkspaceGroupLayout` writes one back.
//
// The six rules
//  1. Every group's run is unbroken in `tabs`, and a child group's run lies inside its parent's run.
//  2. Inside a run: the group's own workspace first when it has one, then its pinned rows, then its unpinned rows.
//     A workspace row's tier is the workspace's pin. A group row's tier is the group's pin. The own workspace is the
//     group's header and not a row, so no edit places it: the first workspace put into a group that has none
//     becomes its own workspace wherever it was aimed.
//  3. At the top level: pinned rows, then unpinned rows. (Rules 2 and 3 are one partition, applied at every level.
//     None of rules 1 to 3 sorts rows inside a tier, which is what keeps a row where it was put.)
//  4. `workspaceGroups` lists a parent before its children. Among the groups beside each other, those that have a
//     run are listed in the order their runs start. A group that has no run has no place in `tabs`, so it is drawn
//     just above the next group listed after it, beside it and of its own tier, that has a run; with none, below
//     the other rows of its tier. Where such a group sits in the list follows upstream, which writes it two ways:
//     when an operation placed rows, every group is listed in the order of its rows (`NoRunRule.followRows`);
//     when nothing placed rows, a group with no run keeps its index among the groups beside it
//     (`NoRunRule.keepSiblingSlot`).
//  5. Parent ids form no loop, and each names a group in the same window. `WorkspaceGroupTree` repairs a loop by
//     reading the first group in list order that is on it as top-level, and a parent that names no group as
//     top-level.
//  6. Every `groupId` names a group in the window, or is nil. A layout reads one that names no group as nil.
//
// The words
// - row: one line in a level: a workspace, or a child group standing for everything inside it.
// - level: the top level, or the inside of one group.
// - run: every workspace inside a group, at every level, as one unbroken stretch of `tabs`.
// - tier: the two bands of rows in a level, pinned first, then unpinned.
// - beside: in the same level, that is, with the same parent group.
// - area: a top-level group with everything inside it.
// - holds nothing: no workspace names the group and no group names it as parent. This is the socket's `is_empty`.
//   A group that holds nothing has no run; so does one that holds only groups that have no run.
// - own workspace: upstream's anchor, the workspace behind the group's name (`liveAnchorWorkspaceId`). It is the
//   group's header, not a row.
// - folded: upstream's collapsed (`isCollapsed`).
// - flat window: a window in which no group sits inside another group.
//
// The writer lists each group's descendants straight after the group (depth first); rule 4 asks only that a parent
// be listed before its children.

/// Input workspace representation for ``WorkspaceGroupLayout``.
public struct WorkspaceGroupWorkspaceItem: Equatable, Sendable {
    public var id: UUID
    public var groupId: UUID?
    public var isPinned: Bool

    public init(id: UUID, groupId: UUID?, isPinned: Bool) {
        self.id = id
        self.groupId = groupId
        self.isPinned = isPinned
    }

    @MainActor
    public init<Tab: WorkspaceTabRepresenting>(_ tab: Tab) {
        self.id = tab.id
        self.groupId = tab.groupId
        self.isPinned = tab.isPinned
    }
}

/// Pure value type modelling the nested layout of groups and workspaces.
///
/// Holds the ordered rows for each level, provides two edits (move a row, reorder a
/// group among the groups beside it), and writes back to tabs and groups orders.
/// A pin is not an edit: the caller stores the flag and reads the layout again.
///
/// The layout remembers whether an edit ran and writes accordingly: after an edit the
/// groups follow their rows; in the bare repair a group with no workspace inside keeps
/// its index among the groups beside it.
struct WorkspaceGroupLayout: Sendable {
    enum Row: Hashable, Sendable {
        case workspace(UUID)
        case group(UUID)
    }

    /// Where an edit puts a row inside its destination level.
    enum Place: Sendable {
        case index(Int)
        case firstOfTier
        case lastOfTier
        case directlyBelow(Row)
        /// After the level's last workspace row of the moved row's tier; first of the tier when there is none.
        case afterLastWorkspaceOfTier
    }

    enum MoveResult: Equatable, Sendable {
        case moved
        case rowNotFound
        case destinationNotFound
        case destinationIsSelfOrInside
        /// The workspace stands behind a group's name, which is not a row, so it does not move.
        case standsBehindGroupName
    }

    /// How rule 4 (see "The six rules" above) orders a group with no run in the written list.
    enum NoRunRule: Sendable {
        /// The list follows the rows: a no-run group is written where its row sits.
        case followRows
        /// Upstream's flat reading, per level: a no-run group keeps its index among
        /// the groups beside it; groups with a run are projected into the other slots.
        case keepSiblingSlot
    }

    struct Output: Equatable, Sendable {
        var tabOrder: [UUID]
        var groupOrder: [UUID]
        var groupIdByWorkspace: [UUID: UUID?]
        var parentByGroup: [UUID: UUID?]
        var anchorByGroup: [UUID: UUID]

        init(
            tabOrder: [UUID],
            groupOrder: [UUID],
            groupIdByWorkspace: [UUID: UUID?],
            parentByGroup: [UUID: UUID?],
            anchorByGroup: [UUID: UUID]
        ) {
            self.tabOrder = tabOrder
            self.groupOrder = groupOrder
            self.groupIdByWorkspace = groupIdByWorkspace
            self.parentByGroup = parentByGroup
            self.anchorByGroup = anchorByGroup
        }
    }

    /// Ordered rows per level (nil = top level). The workspace behind a group's
    /// name is not a row; it is `anchor[group]`.
    private(set) var rows: [UUID?: [Row]] = [:]
    private(set) var anchor: [UUID: UUID] = [:]
    private(set) var parent: [UUID: UUID] = [:]
    private(set) var groupPinned: [UUID: Bool] = [:]
    private(set) var workspacePinned: [UUID: Bool] = [:]
    /// Groups per level in list order, kept for `NoRunRule.keepSiblingSlot`.
    private(set) var siblingOrder: [UUID?: [UUID]] = [:]
    private(set) var levelOfWorkspace: [UUID: UUID] = [:]
    private(set) var workspaceIds: Set<UUID> = []
    /// Whether an edit ran; it picks how `output()` writes a group with no workspace inside.
    private(set) var edited = false

    init(
        tree: WorkspaceGroupTree,
        groups: [WorkspaceGroup],
        workspaces: [WorkspaceGroupWorkspaceItem]
    ) {
        let groupIds = Set(groups.map(\.id))
        for group in groups {
            groupPinned[group.id] = group.isPinned
            if let p = tree.parent(of: group.id) {
                parent[group.id] = p
            }
            siblingOrder[tree.parent(of: group.id), default: []].append(group.id)
        }

        // Rule 6 (see "The six rules" above) on read: a groupId that names no group is read as nil.
        var effectiveGroup: [UUID: UUID] = [:]
        var firstMember: [UUID: UUID] = [:]
        var members: [UUID: Set<UUID>] = [:]
        for workspace in workspaces {
            workspaceIds.insert(workspace.id)
            workspacePinned[workspace.id] = workspace.isPinned
            guard let g = workspace.groupId, groupIds.contains(g) else { continue }
            effectiveGroup[workspace.id] = g
            if firstMember[g] == nil {
                firstMember[g] = workspace.id
            }
            members[g, default: []].insert(workspace.id)
        }
        levelOfWorkspace = effectiveGroup

        // The workspace behind the name: the stored one when it is a direct
        // member, else the first direct member in tabs order (upstream's repair).
        for group in groups {
            if let stored = group.liveAnchorWorkspaceId, members[group.id]?.contains(stored) == true {
                anchor[group.id] = stored
            } else if let first = firstMember[group.id] {
                anchor[group.id] = first
            }
        }

        // Rows by first encounter in tabs order.
        var seenGroups = Set<UUID>()
        for workspace in workspaces {
            guard let g = effectiveGroup[workspace.id] else {
                rows[nil, default: []].append(.workspace(workspace.id))
                continue
            }
            if anchor[g] != workspace.id {
                rows[g, default: []].append(.workspace(workspace.id))
            }
            var cursor: UUID? = g
            while let c = cursor {
                if seenGroups.insert(c).inserted {
                    rows[parent[c], default: []].append(.group(c))
                }
                cursor = parent[c]
            }
        }

        // Rules 2 and 3 (see "The six rules" above): stable partition, pinned rows then unpinned rows.
        for level in Array(rows.keys) {
            rows[level] = partitioned(rows[level] ?? [])
        }

        // Rule 4 (see "The six rules" above) on read.
        var levels = Set(siblingOrder.keys)
        levels.formUnion(rows.keys)
        for level in levels {
            rows[level] = placingNoRunGroups(
                into: rows[level] ?? [],
                siblings: siblingOrder[level] ?? [],
                withRun: seenGroups
            )
        }
    }

    @MainActor
    init<Tab: WorkspaceTabRepresenting>(
        tree: WorkspaceGroupTree,
        groups: [WorkspaceGroup],
        tabs: [Tab]
    ) {
        self.init(
            tree: tree,
            groups: groups,
            workspaces: tabs.map { WorkspaceGroupWorkspaceItem($0) }
        )
    }

    // MARK: - Reads

    func rows(of level: UUID?) -> [Row] {
        rows[level] ?? []
    }

    func isPinned(_ row: Row) -> Bool {
        switch row {
        case .workspace(let id):
            workspacePinned[id] ?? false
        case .group(let id):
            groupPinned[id] ?? false
        }
    }

    func level(of row: Row) -> UUID?? {
        switch row {
        case .workspace(let id):
            guard workspaceIds.contains(id) else { return nil }
            return .some(levelOfWorkspace[id])
        case .group(let id):
            guard groupPinned[id] != nil else { return nil }
            return .some(parent[id])
        }
    }

    /// Whether at least one workspace sits somewhere inside the group.
    func hasRun(_ group: UUID) -> Bool {
        if anchor[group] != nil {
            return true
        }
        return rows(of: group).contains { row in
            switch row {
            case .workspace:
                return true
            case .group(let child):
                return hasRun(child)
            }
        }
    }

    func ancestors(of group: UUID) -> [UUID] {
        var out: [UUID] = []
        var cursor = parent[group]
        while let c = cursor {
            out.append(c)
            cursor = parent[c]
        }
        return out
    }

    private func partitioned(_ list: [Row]) -> [Row] {
        list.filter { isPinned($0) } + list.filter { !isPinned($0) }
    }

    /// Rule 4 (see "The six rules" above): a group with no run sits before the next group beside it of the same
    /// tier that has a run (list order), else last of its tier. `base` holds the
    /// level's rows without the groups that have no run.
    private func placingNoRunGroups(into base: [Row], siblings: [UUID], withRun: Set<UUID>) -> [Row] {
        var before: [UUID: [UUID]] = [:]
        var trailingPinned: [UUID] = []
        var trailingUnpinned: [UUID] = []
        for (index, sibling) in siblings.enumerated() where !withRun.contains(sibling) {
            let tier = groupPinned[sibling] ?? false
            let next = siblings[(index + 1)...].first {
                withRun.contains($0) && (groupPinned[$0] ?? false) == tier
            }
            if let next {
                before[next, default: []].append(sibling)
            } else if tier {
                trailingPinned.append(sibling)
            } else {
                trailingUnpinned.append(sibling)
            }
        }
        var placed: [Row] = []
        for row in base {
            if case .group(let id) = row {
                placed.append(contentsOf: (before[id] ?? []).map { Row.group($0) })
            }
            placed.append(row)
        }
        let firstUnpinned = placed.firstIndex { !isPinned($0) } ?? placed.count
        placed.insert(contentsOf: trailingPinned.map { Row.group($0) }, at: firstUnpinned)
        placed.append(contentsOf: trailingUnpinned.map { Row.group($0) })
        return placed
    }

    // MARK: - Edits

    /// "Move this row to that level at that place."
    @discardableResult
    mutating func move(_ row: Row, to destination: UUID?, at place: Place) -> MoveResult {
        guard let source = level(of: row) else { return .rowNotFound }
        if let destination, groupPinned[destination] == nil {
            return .destinationNotFound
        }
        if case .group(let id) = row, let destination,
           destination == id || ancestors(of: destination).contains(id) {
            return .destinationIsSelfOrInside
        }

        // A group's own workspace is not a row; moving it would hand the name to another workspace.
        if case .workspace(let id) = row, let g = source, anchor[g] == id {
            return .standsBehindGroupName
        }
        edited = true
        // The groups of every level follow their rows, as a write after an edit and a fresh read
        // would leave them, so a following `moveGroupInList` never starts from a stale list.
        defer { bringSiblingOrderUpToDate() }

        // Take it out.
        switch row {
        case .workspace(let id):
            rows[source]?.removeAll { $0 == row }
            levelOfWorkspace[id] = destination
        case .group(let id):
            rows[source]?.removeAll { $0 == row }
            parent[id] = destination
        }

        // Put it in.
        if case .workspace(let id) = row, let destination, anchor[destination] == nil {
            // The first workspace a group owns stands behind its name.
            anchor[destination] = id
            return .moved
        }

        var list = rows[destination] ?? []
        let tier = isPinned(row)
        let index: Int
        switch place {
        case .index(let i):
            index = max(0, min(i, list.count))
        case .firstOfTier:
            index = tier ? 0 : (list.firstIndex { !isPinned($0) } ?? list.count)
        case .lastOfTier:
            index = tier ? (list.firstIndex { !isPinned($0) } ?? list.count) : list.count
        case .directlyBelow(let reference):
            index = list.firstIndex(of: reference).map { $0 + 1 } ?? list.count
        case .afterLastWorkspaceOfTier:
            let last = list.lastIndex { candidate in
                if case .workspace = candidate, isPinned(candidate) == tier {
                    return true
                }
                return false
            }
            if let last {
                index = last + 1
            } else {
                index = tier ? 0 : (list.firstIndex { !isPinned($0) } ?? list.count)
            }
        }
        list.insert(row, at: index)
        rows[destination] = partitioned(list)
        return .moved
    }

    /// Reorder a group among the groups beside it (same parent), upstream's way, at any level:
    /// 1. move it in the list of those groups, the target clamped to the stretch from the first
    ///    to the last of them that share its pin state;
    /// 2. place each group with no workspace inside again by the reading rule from the moved list;
    /// 3. the groups that have a workspace take, in list order and per pin state, the rows such
    ///    groups held at that level. Workspaces and every other row stay where they are.
    /// Returns false, changing nothing, when the clamped target is where the group already is.
    @discardableResult
    mutating func moveGroupInList(_ group: UUID, toSiblingIndex requested: Int) -> Bool {
        guard let tier = groupPinned[group] else { return false }
        let level = parent[group]
        var siblings = siblingOrder[level] ?? []
        guard let from = siblings.firstIndex(of: group) else { return false }
        let same = siblings.indices.filter { (groupPinned[siblings[$0]] ?? false) == tier }
        guard let first = same.first, let last = same.last else { return false }
        let target = max(first, min(requested, last))
        guard target != from else { return false }
        edited = true
        siblings.remove(at: from)
        siblings.insert(group, at: max(0, min(target, siblings.count)))

        let withRun = Set(siblings.filter { hasRun($0) })
        func isNoRunRow(_ row: Row) -> Bool {
            if case .group(let id) = row {
                return !withRun.contains(id)
            }
            return false
        }
        let base = partitioned(rows[level] ?? []).filter { !isNoRunRow($0) }
        var placed = placingNoRunGroups(into: base, siblings: siblings, withRun: withRun)
        for pinState in [true, false] {
            let slots = placed.indices.filter { index in
                if case .group(let id) = placed[index] {
                    return withRun.contains(id) && (groupPinned[id] ?? false) == pinState
                }
                return false
            }
            let occupants = siblings.filter { withRun.contains($0) && (groupPinned[$0] ?? false) == pinState }
            for (slot, occupant) in zip(slots, occupants) {
                placed[slot] = .group(occupant)
            }
        }
        rows[level] = placed
        // Leave every level as a write and a fresh read would, so a following edit starts from it.
        bringSiblingOrderUpToDate()
        return true
    }

    /// Put one level's rows in a given order (same rows, new order), pinned before unpinned.
    /// Returns false, changing nothing, when `new` is not a reordering of the level's rows.
    /// Not one of the two edits. It is internal, not private: `WorkspacesModel.nestedSetTopLevelOrder` puts the
    /// top-level rows in a caller's order with it, and the tests that compare with upstream's flat reorders use it.
    @discardableResult
    mutating func setRows(of level: UUID?, _ new: [Row]) -> Bool {
        let current = rows[level] ?? []
        guard Set(current) == Set(new), current.count == new.count else { return false }
        edited = true
        rows[level] = partitioned(new)
        // Leave every level as a write and a fresh read would, so a following edit starts from it.
        bringSiblingOrderUpToDate()
        return true
    }

    // MARK: - Write back

    /// The group order a write gives one level.
    private func groupSequence(of level: UUID?, using noRunRule: NoRunRule) -> [UUID] {
        let rowGroups: [UUID] = partitioned(rows(of: level)).compactMap { row in
            if case .group(let id) = row {
                return id
            }
            return nil
        }
        switch noRunRule {
        case .followRows:
            return rowGroups
        case .keepSiblingSlot:
            var withRun = rowGroups.filter { hasRun($0) }[...]
            return (siblingOrder[level] ?? []).map { sibling in
                if hasRun(sibling), let next = withRun.popFirst() {
                    return next
                }
                return sibling
            }
        }
    }

    /// Leaves each level as a write after an edit and a fresh read would: the list of groups is the
    /// written order, and a group with no workspace inside is placed again by rule 4 (see "The six rules" above) from that list.
    private mutating func bringSiblingOrderUpToDate() {
        for level in Set(siblingOrder.keys).union(rows.keys) {
            let written = groupSequence(of: level, using: .followRows)
            siblingOrder[level] = written
            let withRun = Set(written.filter { hasRun($0) })
            let base = partitioned(rows[level] ?? []).filter { row in
                if case .group(let id) = row {
                    return withRun.contains(id)
                }
                return true
            }
            rows[level] = placingNoRunGroups(into: base, siblings: written, withRun: withRun)
        }
    }

    func output() -> Output {
        output(using: edited ? .followRows : .keepSiblingSlot)
    }

    func output(using noRunRule: NoRunRule) -> Output {
        var tabOrder: [UUID] = []
        var groupOrder: [UUID] = []
        var groupIdByWorkspace: [UUID: UUID?] = [:]
        var parentByGroup: [UUID: UUID?] = [:]

        func emitTabs(_ level: UUID?) {
            for row in partitioned(rows(of: level)) {
                switch row {
                case .workspace(let id):
                    tabOrder.append(id)
                    groupIdByWorkspace[id] = level
                case .group(let id):
                    if let a = anchor[id] {
                        tabOrder.append(a)
                        groupIdByWorkspace[a] = id
                    }
                    emitTabs(id)
                }
            }
        }

        func emitGroups(_ level: UUID?) {
            for id in groupSequence(of: level, using: noRunRule) {
                groupOrder.append(id)
                parentByGroup[id] = parent[id]
                emitGroups(id)
            }
        }

        emitTabs(nil)
        emitGroups(nil)

        return Output(
            tabOrder: tabOrder,
            groupOrder: groupOrder,
            groupIdByWorkspace: groupIdByWorkspace,
            parentByGroup: parentByGroup,
            anchorByGroup: anchor
        )
    }
}
