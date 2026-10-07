import CoreGraphics
import Foundation

// The drop planner's rules for a window that holds a workspace group inside another (#cm-106).
//
// `SidebarWorkspaceReorderDropResolver.plan(for:)` hands a request over here with one line when some group in
// its snapshot names a parent. A window with no nested group never reaches this file and plans exactly as
// v0.31.0 does. The planner's package cannot see the model, so this file keeps its own copy of the group tree
// and of each group's run, over the plain snapshots the request carries.
//
// A group's run is every workspace inside it at any level, in `workspaces` order. The workspace behind a
// group's name comes first. Inside a run the group's rows follow it: its own workspaces, and each child
// group's whole run as one row.
//
// What this file decides, by what is dragged:
// - A workspace: the level it lands in. The innermost group at the pointer on the right half of the sidebar,
//   the group outside the outermost group that ends at the edge on the left half, and the top level when
//   there is none. A top-level place is the unchanged planner's, run over the same request with every group
//   read as its outermost group; what is rebuilt here is how the plan says it (an index among the top-level rows
//   with every moving row taken out, and a line drawn from that index), so that the line and the landing agree.
// - A nested header that has a workspace: only a place among its parent's rows of the same pin tier.
// - A header with no workspace of its own: only an index among the groups beside it. A top-level one with no
//   workspace anywhere inside it takes the unchanged planner's index, over the flattened request (the split by the
//   half of the row); one that holds groups, and a nested one, split by the half of the group's whole block.
// - A top-level header that has a workspace: the unchanged planner's plan, over the flattened request.
//
// Several rows dragged together (a selection): every moving row is taken out before a boundary is judged, so a plan's
// index is an index into `workspaces` with all of them removed, and the commit reads it the same way.

#if DEBUG
/// Counts the flattened requests built while a test plans a drop (#cm-106). Only a test sets `counter`.
final class SidebarNestedFlattenCounter: @unchecked Sendable {
    var builds = 0
}

enum SidebarNestedFlattenProbe {
    /// A task-local, so plans that other tests run at the same time are not counted.
    @TaskLocal static var counter: SidebarNestedFlattenCounter?
}
#endif

/// The tree of the request's groups, with an unknown parent and a loop read as top-level, as the model reads them.
struct SidebarNestedGroupTree {
    private let known: Set<UUID>
    private let parentById: [UUID: UUID]
    private let childrenByLevel: [UUID?: [UUID]]

    init(groups: [SidebarWorkspaceReorderGroupSnapshot]) {
        let known = Set(groups.map(\.id))
        var parent: [UUID: UUID] = [:]
        for group in groups {
            if let p = group.parentGroupId, known.contains(p) { parent[group.id] = p }
        }
        // A group on a loop is read as top-level, which opens the loop; first in list order.
        for group in groups {
            var cursor = parent[group.id]
            var seen: Set<UUID> = [group.id]
            while let c = cursor {
                if c == group.id {
                    parent[group.id] = nil
                    break
                }
                if !seen.insert(c).inserted { break }
                cursor = parent[c]
            }
        }
        var children: [UUID?: [UUID]] = [:]
        for group in groups { children[parent[group.id], default: []].append(group.id) }
        self.known = known
        self.parentById = parent
        self.childrenByLevel = children
    }

    func contains(_ id: UUID) -> Bool { known.contains(id) }

    func parent(of id: UUID) -> UUID? { parentById[id] }

    /// Groups directly at a level (nil = top level), in list order.
    func children(of level: UUID?) -> [UUID] { childrenByLevel[level] ?? [] }

    /// The group, then every group above it, nearest first. Empty for nil or an unknown id.
    func chain(from id: UUID?) -> [UUID] {
        guard let id, known.contains(id) else { return [] }
        var out = [id]
        var cursor = parentById[id]
        while let c = cursor {
            out.append(c)
            cursor = parentById[c]
        }
        return out
    }

    func outermost(of id: UUID) -> UUID { chain(from: id).last ?? id }
}

/// Where a candidate lands inside a group.
enum SidebarNestedDropPlace: Equatable {
    /// At an index into `workspaces` (before the workspace now at that index).
    case tabs(Int)
    /// Into the group itself, below its header: first of its tier, or its own workspace when it has none.
    case afterHeader
}

/// Where a workspace dropped at one pointer position can land.
enum SidebarNestedDropCandidate: Equatable {
    case root
    case group(UUID, SidebarNestedDropPlace)
}

/// What the pointer position means: one candidate, or one per half of the sidebar.
enum SidebarNestedDropDecision: Equatable {
    case single(SidebarNestedDropCandidate)
    case split(right: SidebarNestedDropCandidate, left: SidebarNestedDropCandidate)
}

/// One row of a level: a workspace, or a child group with its whole run.
struct SidebarNestedDropRow: Equatable {
    enum Kind: Equatable {
        case workspace(UUID)
        case group(UUID)
    }

    var kind: Kind
    var start: Int
    var end: Int
    var isPinned: Bool
}

/// The row boundaries of a level, as indexes into `workspaces`.
struct SidebarNestedDropBoundaries {
    let rows: [SidebarNestedDropRow]
    /// One more than the rows: before each row, then the end of the last.
    let positions: [Int]
    let pinnedRows: Int
}

/// The request read as a tree of runs.
struct SidebarNestedGroupDropContext {
    let request: SidebarWorkspaceReorderDropRequest
    let sortedTargets: [SidebarWorkspaceReorderDropTarget]
    let tree: SidebarNestedGroupTree
    let groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    let tabIndex: [UUID: Int]
    /// The group a workspace names, when that group exists.
    let directGroup: [UUID: UUID]
    /// The stretch of `workspaces` inside each group at any level. Absent for a group with no workspace inside.
    let ranges: [UUID: Range<Int>]
    /// The indexes in `workspaces` of every row that moves with the drag, sorted. Empty until `setMoving`.
    private(set) var movingTabs: [Int] = []
    /// The groups that move with the drag (a header block).
    private(set) var movingGroups: Set<UUID> = []

    init(request: SidebarWorkspaceReorderDropRequest, sortedTargets: [SidebarWorkspaceReorderDropTarget]) {
        let tree = SidebarNestedGroupTree(groups: request.groups)
        var tabIndex: [UUID: Int] = [:]
        var direct: [UUID: UUID] = [:]
        var ranges: [UUID: Range<Int>] = [:]
        for (index, workspace) in request.workspaces.enumerated() {
            tabIndex[workspace.id] = index
            guard let groupId = workspace.groupId, tree.contains(groupId) else { continue }
            direct[workspace.id] = groupId
            for group in tree.chain(from: groupId) {
                if let range = ranges[group] {
                    ranges[group] = min(range.lowerBound, index)..<max(range.upperBound, index + 1)
                } else {
                    ranges[group] = index..<(index + 1)
                }
            }
        }
        self.request = request
        self.sortedTargets = sortedTargets
        self.tree = tree
        self.groupsById = Dictionary(request.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.tabIndex = tabIndex
        self.directGroup = direct
        self.ranges = ranges
    }

    /// Declares what the drag takes out of the list: the workspaces, and the groups with all their rows.
    mutating func setMoving(workspaces ids: Set<UUID>, groups: Set<UUID>) {
        var indexes = Set(ids.compactMap { tabIndex[$0] })
        for group in groups {
            if let range = ranges[group] { indexes.formUnion(range) }
        }
        movingTabs = indexes.sorted()
        movingGroups = groups
    }

    /// An index into `workspaces` as an index into `workspaces` with every moving row taken out.
    func reduced(_ index: Int) -> Int {
        var count = 0
        for moving in movingTabs { if moving < index { count += 1 } else { break } }
        return index - count
    }

    func isMoving(_ target: SidebarWorkspaceReorderDropTarget) -> Bool {
        if let index = tabIndex[target.workspaceId], movingTabs.contains(index) { return true }
        return chain(of: target).contains { movingGroups.contains($0) }
    }

    // MARK: - Reads

    /// The workspace behind a group's name, when the group has one among the request's workspaces.
    func ownWorkspaceId(of group: UUID) -> UUID? {
        guard let snapshot = groupsById[group], !snapshot.isEmpty,
              tabIndex[snapshot.anchorWorkspaceId] != nil,
              directGroup[snapshot.anchorWorkspaceId] == group else { return nil }
        return snapshot.anchorWorkspaceId
    }

    /// The groups a visible row sits in, innermost first. A header is in its own group.
    func chain(of target: SidebarWorkspaceReorderDropTarget) -> [UUID] {
        tree.chain(from: target.groupId)
    }

    /// Where a group's run starts, or where its row is drawn when it has no workspace inside (rule 4, CmuxWorkspaces' WorkspaceGroupLayout.swift, "The six rules": before the
    /// next group beside it of the same pin tier that has one, else last of its tier).
    func blockStart(of group: UUID) -> Int { ranges[group]?.lowerBound ?? emptySlot(of: group) }

    func blockEnd(of group: UUID) -> Int { ranges[group]?.upperBound ?? emptySlot(of: group) }

    private func emptySlot(of group: UUID) -> Int {
        let parent = tree.parent(of: group)
        let siblings = tree.children(of: parent)
        let tier = groupsById[group]?.isPinned ?? false
        if let index = siblings.firstIndex(of: group),
           let next = siblings[(index + 1)...].first(where: { ranges[$0] != nil && groupsById[$0]?.isPinned == tier }),
           let range = ranges[next] {
            return range.lowerBound
        }
        guard let bounds = boundaries(of: parent) else {
            return parent.flatMap { ranges[$0]?.upperBound } ?? request.workspaces.count
        }
        return tier ? bounds.positions[bounds.pinnedRows] : bounds.positions[bounds.rows.count]
    }

    /// The rows of a level that have a workspace, in `workspaces` order. A group with no workspace has no stretch of
    /// `workspaces` and so no row here.
    func rows(of level: UUID?) -> [SidebarNestedDropRow] {
        var result: [SidebarNestedDropRow] = []
        var groupRow: [UUID: Int] = [:]
        let ownHeader = level.flatMap(ownWorkspaceId(of:))
        for (index, workspace) in request.workspaces.enumerated() {
            let row: SidebarNestedDropRow.Kind
            let group = directGroup[workspace.id]
            if let level {
                guard let group else { continue }
                if group == level {
                    if workspace.id == ownHeader { continue }
                    row = .workspace(workspace.id)
                } else if let child = tree.chain(from: group).first(where: { tree.parent(of: $0) == level }) {
                    row = .group(child)
                } else {
                    continue
                }
            } else if let group {
                row = .group(tree.outermost(of: group))
            } else {
                row = .workspace(workspace.id)
            }
            switch row {
            case .workspace:
                result.append(SidebarNestedDropRow(kind: row, start: index, end: index + 1, isPinned: workspace.isPinned))
            case .group(let child):
                if let existing = groupRow[child] {
                    result[existing].end = index + 1
                } else {
                    groupRow[child] = result.count
                    result.append(SidebarNestedDropRow(
                        kind: row, start: index, end: index + 1, isPinned: groupsById[child]?.isPinned ?? false
                    ))
                }
            }
        }
        return result
    }

    func boundaries(of level: UUID?) -> SidebarNestedDropBoundaries? {
        let rows = rows(of: level)
        var positions = rows.map(\.start)
        if let last = rows.last {
            positions.append(last.end)
        } else if let level {
            guard let own = ownWorkspaceId(of: level), let index = tabIndex[own] else { return nil }
            positions = [index + 1]
        } else {
            positions = [0]
        }
        let pinned = rows.prefix { $0.isPinned }.count
        return SidebarNestedDropBoundaries(rows: rows, positions: positions, pinnedRows: pinned)
    }

    /// The rows of a level that stay, and their boundaries, as indexes into `workspaces` with every moving row taken out.
    func stayingBoundaries(of level: UUID?) -> SidebarNestedDropBoundaries? {
        let staying = rows(of: level).filter { row in
            switch row.kind {
            case .workspace(let id): return !(tabIndex[id].map(movingTabs.contains) ?? false)
            case .group(let id): return !movingGroups.contains(id)
            }
        }.map { row -> SidebarNestedDropRow in
            var copy = row
            copy.start = reduced(row.start)
            copy.end = reduced(row.end)
            return copy
        }
        var positions = staying.map(\.start)
        if let last = staying.last {
            positions.append(last.end)
        } else if let level {
            guard let own = ownWorkspaceId(of: level), let index = tabIndex[own] else { return nil }
            positions = [reduced(index + 1)]
        } else {
            positions = [0]
        }
        return SidebarNestedDropBoundaries(rows: staying, positions: positions, pinnedRows: staying.prefix { $0.isPinned }.count)
    }

    /// A requested boundary of a level (an index into `workspaces`), as an index into `workspaces` with every moving row
    /// taken out, moved into the dragged row's pin tier; nil when it is not a boundary between two of the level's own
    /// rows that stay (a place inside a child group's run is never legal).
    func legalBoundary(level: UUID?, isPinned: Bool, requested: Int) -> Int? {
        guard let bounds = stayingBoundaries(of: level), bounds.positions.contains(reduced(requested)) else { return nil }
        let lower = isPinned ? 0 : bounds.pinnedRows
        let upper = isPinned ? bounds.pinnedRows : bounds.rows.count
        return min(max(reduced(requested), bounds.positions[lower]), bounds.positions[upper])
    }

    // MARK: - Visible rows

    /// What is dropped, for where a header with no workspace of its own stands against the place.
    struct Dropper {
        var isPinned: Bool
        var isGroup: Bool
    }

    /// Where a header with no workspace anywhere inside it is drawn, as an index into `workspaces` with the moving rows
    /// taken out. Such a header has no place in `workspaces` to be dropped before. The layout draws a pinned one before
    /// the unpinned rows and an unpinned one after the pinned rows. Against a dropper of the same tier: a workspace
    /// dropped at its place lands before it (it is drawn at the next group, or last); a group dropped there lands after
    /// it (the groups beside it keep their list order).
    private func emptyHeaderPosition(of group: UUID, dropper: Dropper) -> Double {
        let place = Double(reduced(emptySlot(of: group)))
        guard let isPinned = groupsById[group]?.isPinned else { return place }
        if isPinned != dropper.isPinned { return isPinned ? place - 0.5 : place }
        return dropper.isGroup ? place - 0.5 : place
    }

    /// Where a visible row sits in the list with the moving rows taken out, for the line of a boundary inside the run
    /// of `level`: the row's index; for the level's own header with no workspace, above all its rows; for a header with
    /// a run and no workspace, where its run starts; for a header with no workspace anywhere inside it, see
    /// `emptyHeaderPosition`, and one inside a child group of the level stands inside that child's block, so a boundary
    /// of the level is never between it and the child's header.
    func position(of target: SidebarWorkspaceReorderDropTarget, dropper: Dropper, inRunOf level: UUID) -> Double? {
        if let index = tabIndex[target.workspaceId] { return Double(reduced(index)) }
        guard target.isGroupHeader, let owner = target.groupId, tree.contains(owner) else { return nil }
        if let range = ranges[owner] {
            return Double(reduced(range.lowerBound)) - (owner == level ? 0.5 : 0)
        }
        guard let child = tree.chain(from: owner).first(where: { tree.parent(of: $0) == level }) else {
            return emptyHeaderPosition(of: owner, dropper: dropper)
        }
        if child == owner { return emptyHeaderPosition(of: owner, dropper: dropper) }
        guard let block = ranges[child] else { return emptyHeaderPosition(of: child, dropper: dropper) }
        let slot = Double(reduced(emptySlot(of: owner)))
        return min(max(slot, Double(reduced(block.lowerBound)) + 0.25), Double(reduced(block.upperBound)) - 0.25)
    }

    /// The line for a boundary (an index into `workspaces` with the moving rows taken out) inside a group's run, against
    /// the visible rows of that run: the top of the first row that stays at or after the boundary, else the bottom of the
    /// last row that stays. Moving rows are passed over, and the line is never put under the row before moving rows: the
    /// table paints a bottom-edge line as the top of the next row, and paints nothing on the dragged row.
    func indicator(atBoundary boundary: Int, inRunOf group: UUID, dropper: Dropper) -> SidebarDropIndicator? {
        var rows: [(id: UUID, position: Double, moving: Bool)] = []
        for target in sortedTargets where chain(of: target).contains(group) {
            if let position = position(of: target, dropper: dropper, inRunOf: group) {
                rows.append((target.workspaceId, position, isMoving(target)))
            }
        }
        // The first row that stays at or after the boundary: the line is the top of that row, which the table paints.
        // Moving rows that stand directly above it are leaving, and a bottom-edge line under the row before them would
        // be painted as the top of a moving row, which the table never paints when it is the dragged one.
        if let index = rows.firstIndex(where: { !$0.moving && $0.position >= Double(boundary) }) {
            return SidebarDropIndicator(tabId: rows[index].id, edge: .top)
        }
        let last = rows.last { !$0.moving } ?? rows.last
        return last.map { SidebarDropIndicator(tabId: $0.id, edge: .bottom) }
    }

    /// The bottom-most visible row inside a group's run.
    func lastVisibleRow(inRunOf group: UUID) -> UUID? {
        sortedTargets.last { chain(of: $0).contains(group) }?.workspaceId
    }

    // MARK: - A workspace at the pointer

    /// What the pointer position means for a dropped workspace, as the unchanged planner's `groupScopeCandidate`
    /// reads it for one level of group, generalised to the group chain at an edge.
    func decision(_ context: SidebarWorkspaceReorderHitContext) -> SidebarNestedDropDecision {
        func knownGroup(_ target: SidebarWorkspaceReorderDropTarget) -> UUID? {
            target.groupId.flatMap { tree.contains($0) ? $0 : nil }
        }
        func upperLevelCandidate(of group: UUID) -> SidebarNestedDropCandidate {
            tree.parent(of: group).map { .group($0, .tabs(blockStart(of: group))) } ?? .root
        }
        if let target = context.target {
            if let group = knownGroup(target) {
                switch context.edge {
                case .top:
                    if target.isGroupHeader {
                        // A header's top edge is the boundary before its group, in the level that holds it. A header
                        // with no workspace of its own is also an adopt zone: the right half joins it.
                        if groupsById[group]?.isEmpty == true {
                            return .split(right: .group(group, .afterHeader), left: upperLevelCandidate(of: group))
                        }
                        return .single(upperLevelCandidate(of: group))
                    }
                    guard let index = tabIndex[target.workspaceId] else { return .single(.root) }
                    return .single(.group(group, .tabs(index)))
                case .bottom:
                    // A header's lower half is the group's own adopt zone, folded or not.
                    if target.isGroupHeader { return .single(.group(group, .afterHeader)) }
                    let nextGroups = context.nextTarget.map { chain(of: $0) } ?? []
                    if nextGroups.contains(group), let index = tabIndex[target.workspaceId] {
                        return .single(.group(group, .tabs(index + 1)))
                    }
                    return edge(after: target, before: context.nextTarget)
                }
            }
            if context.edge == .top, let previous = context.previousTarget, knownGroup(previous) != nil {
                return edge(after: previous, before: target)
            }
            return .single(.root)
        }
        guard let previous = context.previousTarget, knownGroup(previous) != nil else { return .single(.root) }
        return edge(after: previous, before: nil)
    }

    /// The edge below `previous` and above `next` (nil: the end of the list). The groups that end here are the ones
    /// `previous` sits in that `next` does not. The right half is the innermost group at the pointer. The left half
    /// is the group outside the outermost group that ends here, or the top level when there is none.
    private func edge(
        after previous: SidebarWorkspaceReorderDropTarget,
        before next: SidebarWorkspaceReorderDropTarget?
    ) -> SidebarNestedDropDecision {
        let previousGroups = chain(of: previous)
        guard let innermost = previousGroups.first else { return .single(.root) }
        let nextGroups = next.map { chain(of: $0) } ?? []
        let ending = Array(previousGroups.prefix { !nextGroups.contains($0) })
        guard let outermostEnding = ending.last else {
            return .single(.group(innermost, .tabs(blockEnd(of: innermost))))
        }
        let right = SidebarNestedDropCandidate.group(
            innermost,
            previous.isGroupHeader ? .afterHeader : .tabs(blockEnd(of: innermost))
        )
        let left: SidebarNestedDropCandidate = tree.parent(of: outermostEnding).map {
            .group($0, .tabs(blockEnd(of: outermostEnding)))
        } ?? .root
        return .split(right: right, left: left)
    }

    // MARK: - A group's row at the pointer

    /// The boundary, among the rows of one level, that the pointer is nearest, for a dragged group row. A workspace
    /// row gives its top or bottom edge. A child group gives the start or the end of its whole run, by which half of
    /// its visible rows the pointer is in. Nil when the pointer is outside the level's run, or is on the level's own
    /// header above its lower half.
    func rowBoundary(level: UUID?, context: SidebarWorkspaceReorderHitContext) -> Int? {
        let target: SidebarWorkspaceReorderDropTarget
        let edge: SidebarDropEdge
        if let hit = context.target {
            target = hit
            edge = context.edge
        } else if let previous = context.previousTarget {
            target = previous
            edge = .bottom
        } else {
            return nil
        }
        let groups = chain(of: target)
        let row: SidebarNestedDropRow.Kind
        if let level {
            guard groups.contains(level) else { return nil }
            if groups.first == level {
                if target.isGroupHeader {
                    // The level's own header: only its lower half, which is the first place among its rows.
                    guard edge == .bottom else { return nil }
                    return boundaries(of: level)?.positions.first
                }
                row = .workspace(target.workspaceId)
            } else if let child = groups.first(where: { tree.parent(of: $0) == level }) {
                row = .group(child)
            } else {
                return nil
            }
        } else if let outer = groups.last {
            row = .group(outer)
        } else {
            row = .workspace(target.workspaceId)
        }
        switch row {
        case .workspace(let id):
            guard let index = tabIndex[id] else { return nil }
            return edge == .top ? index : index + 1
        case .group(let group):
            let frames = sortedTargets.filter { chain(of: $0).contains(group) }.map(\.frame)
            guard let first = frames.first else { return nil }
            let block = frames.dropFirst().reduce(first) { $0.union($1) }
            return request.point.y < block.midY ? blockStart(of: group) : blockEnd(of: group)
        }
    }

    /// Whether the pointer is on a row inside the group.
    func pointerIsInside(group: UUID, context: SidebarWorkspaceReorderHitContext) -> Bool {
        context.target.map { chain(of: $0).contains(group) } ?? false
    }

    // MARK: - The request with every group read as its outermost group

    /// The same request with each nested group folded into the top-level group that holds it, so the unchanged
    /// planner plans the top level exactly as it does for a window with no nested group.
    func flattenedRequest() -> SidebarWorkspaceReorderDropRequest {
#if DEBUG
        SidebarNestedFlattenProbe.counter?.builds += 1
#endif
        func outer(_ id: UUID?) -> UUID? {
            id.flatMap { tree.contains($0) ? tree.outermost(of: $0) : $0 }
        }
        return SidebarWorkspaceReorderDropRequest(
            point: request.point,
            draggedWorkspaceId: request.draggedWorkspaceId,
            foreignDraggedIsPinned: request.foreignDraggedIsPinned,
            workspaces: request.workspaces.map {
                SidebarWorkspaceReorderWorkspaceSnapshot(id: $0.id, isPinned: $0.isPinned, groupId: outer($0.groupId))
            },
            // A group is empty here when no workspace is inside it at any level: a header placed by the list of groups.
            groups: request.groups.filter { tree.parent(of: $0.id) == nil }.map {
                SidebarWorkspaceReorderGroupSnapshot(
                    id: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId, isPinned: $0.isPinned, isEmpty: ranges[$0.id] == nil
                )
            },
            targets: request.targets.map {
                SidebarWorkspaceReorderDropTarget(
                    workspaceId: $0.workspaceId,
                    groupId: outer($0.groupId),
                    isGroupHeader: $0.isGroupHeader && ($0.groupId.map { tree.parent(of: $0) == nil } ?? false),
                    frame: $0.frame
                )
            },
            draggedBlockWorkspaceIds: request.draggedBlockWorkspaceIds
        )
    }
}

extension SidebarWorkspaceReorderDropResolver {
    /// The plan for a window that holds a nested group (#cm-106). `plan(for:)` hands over here when some group in
    /// the request names a parent.
    func planNested(
        request: SidebarWorkspaceReorderDropRequest,
        sortedTargets: [SidebarWorkspaceReorderDropTarget]
    ) -> SidebarWorkspaceReorderDropPlan? {
        var rules = SidebarNestedGroupDropContext(request: request, sortedTargets: sortedTargets)
        let context = hitContext(point: request.point, sortedTargets: sortedTargets)
        let dragged = request.draggedWorkspaceId
        let block = request.draggedBlockWorkspaceIds.count > 1 && request.draggedBlockWorkspaceIds.contains(dragged)
            ? request.draggedBlockWorkspaceIds : [dragged]

        if rules.tabIndex[dragged] != nil {
            if let group = request.groups.first(where: { $0.anchorWorkspaceId == dragged && rules.ownWorkspaceId(of: $0.id) == dragged }) {
                guard rules.draggedHeadersShareParent(of: group.id) else { return nil }
                if rules.tree.parent(of: group.id) == nil { return plan(for: rules.flattenedRequest()) }
                rules.setMoving(
                    workspaces: [],
                    groups: Set(request.groups.filter { block.contains($0.anchorWorkspaceId) }.map(\.id))
                )
                return rules.nestedHeaderPlan(group: group.id, context: context)
            }
            rules.setMoving(workspaces: block, groups: [])
            return rules.workspacePlan(resolver: self, context: context)
        }
        if let group = rules.groupsById[dragged] {
            // A header with no workspace of its own drags as its group's id.
            return group.isEmpty ? rules.emptyHeaderPlan(resolver: self, group: group.id, context: context) : nil
        }
        return plan(for: rules.flattenedRequest())
    }
}

extension SidebarWorkspaceReorderDropResolver {
    /// The top-level rows the planner reads from a request, in order: a loose workspace, or a top-level group's
    /// header, and a top-level group with no workspace inside it placed by the list of groups. In a window with a
    /// nested group every group is read as its outermost group. The model and the list of rows draw the same order.
    func topLevelRowIds(of request: SidebarWorkspaceReorderDropRequest) -> [UUID] {
        topLevelRowIds(fromFlattened: request.groups.contains { $0.parentGroupId != nil }
            ? SidebarNestedGroupDropContext(request: request, sortedTargets: []).flattenedRequest()
            : request)
    }

    /// The same rows from a request already read with every group as its outermost group.
    func topLevelRowIds(fromFlattened source: SidebarWorkspaceReorderDropRequest) -> [UUID] {
        let workspacesById = Dictionary(uniqueKeysWithValues: source.workspaces.map { ($0.id, $0) })
        let groupsById = Dictionary(uniqueKeysWithValues: source.groups.map { ($0.id, $0) })
        let groupByAnchorId = Dictionary(uniqueKeysWithValues: source.groups.map { ($0.anchorWorkspaceId, $0) })
        let base = topLevelWorkspaceIds(
            workspaces: source.workspaces, workspacesById: workspacesById, groupsById: groupsById,
            groupByAnchorId: groupByAnchorId, promotingWorkspaceId: nil
        )
        return topLevelWorkspaceIdsIncludingEmptyGroups(baseIds: base, request: source, workspacesById: workspacesById)
    }
}

extension SidebarNestedGroupDropContext {
    private var midpoint: CGFloat {
        let bounds = request.targets.reduce(CGRect.null) { $0.union($1.frame) }
        guard !bounds.isNull, bounds.width > 0 else { return 0 }
        return bounds.minX + bounds.width / 2
    }

    /// Several selected headers move together only when they sit in the same parent as the one dragged.
    func draggedHeadersShareParent(of group: UUID) -> Bool {
        let blockIds = request.draggedBlockWorkspaceIds
        guard blockIds.count > 1 else { return true }
        let parent = tree.parent(of: group)
        for snapshot in request.groups where blockIds.contains(snapshot.anchorWorkspaceId) {
            if tree.parent(of: snapshot.id) != parent { return false }
        }
        return true
    }

    // MARK: - A workspace

    func workspacePlan(
        resolver: SidebarWorkspaceReorderDropResolver,
        context: SidebarWorkspaceReorderHitContext
    ) -> SidebarWorkspaceReorderDropPlan? {
        let candidate: SidebarNestedDropCandidate
        switch decision(context) {
        case .single(let only):
            candidate = only
        case .split(let right, let left):
            candidate = request.point.x >= midpoint ? right : left
        }
        switch candidate {
        case .root:
            return rootWorkspacePlan(resolver: resolver)
        case .group(let group, let place):
            return groupPlan(workspace: request.draggedWorkspaceId, group: group, place: place)
        }
    }

    /// A workspace dropped at a top-level place of a window that holds a nested group. The place is the unchanged
    /// planner's, over the request with every group read as its outermost group; what is rebuilt here is how the plan is
    /// said, so that the line and the landing agree: always an index among the top-level rows (the order without the
    /// moving rows is the one the commit reads), held to the dragged row's pin tier among them, with the line drawn from
    /// that index. The unchanged planner says a place among loose rows as an index into `workspaces`, which ignores a
    /// pinned group, and draws the line of a grouped workspace against a row that is not a top-level row.
    private func rootWorkspacePlan(resolver: SidebarWorkspaceReorderDropResolver) -> SidebarWorkspaceReorderDropPlan? {
        let flatRequest = flattenedRequest()
        guard let flat = resolver.plan(for: flatRequest) else { return nil }
        guard case .reorder(let index, let usesTopLevelRows, nil) = flat.action else { return flat }
        let dragged = request.draggedWorkspaceId
        let moving = Set(movingTabs.map { request.workspaces[$0].id })
        let rowIds = resolver.topLevelRowIds(fromFlattened: flatRequest)
        let groupByAnchor = Dictionary(flatRequest.groups.map { ($0.anchorWorkspaceId, $0) }, uniquingKeysWith: { first, _ in first })
        let workspacePinned = Dictionary(request.workspaces.map { ($0.id, $0.isPinned) }, uniquingKeysWith: { first, _ in first })
        func isPinned(_ id: UUID) -> Bool { groupByAnchor[id]?.isPinned ?? workspacePinned[id] ?? false }
        // The order without the dragged row, as the unchanged planner's index reads it; then without every moving row.
        let withoutDragged = rowIds.filter { $0 != dragged }
        let staying = rowIds.filter { !moving.contains($0) }

        // The row the movers go directly before.
        var reference: UUID?
        if usesTopLevelRows {
            reference = index < withoutDragged.count ? withoutDragged[index...].first { !moving.contains($0) } : nil
        } else {
            // An index into `workspaces` without the dragged row: the first tab at or after it that does not move
            // stands for the top-level row it starts; a place inside a stretch is no top-level place.
            let tabs = request.workspaces.filter { $0.id != dragged }
            let tab = index < tabs.count ? tabs[index...].first { !moving.contains($0.id) } : nil
            if let tab {
                if let group = tab.groupId, tree.contains(group) {
                    let outermost = tree.outermost(of: group)
                    guard let range = ranges[outermost], request.workspaces[range.lowerBound].id == tab.id,
                          let anchor = groupsById[outermost]?.anchorWorkspaceId else { return nil }
                    reference = anchor
                } else {
                    reference = tab.id
                }
            }
        }
        var place = reference.flatMap { staying.firstIndex(of: $0) } ?? staying.count
        // Held to the dragged row's pin tier among the top-level rows.
        let pinnedCount = staying.prefix { isPinned($0) }.count
        let draggedPinned = workspacePinned[dragged] ?? false
        place = draggedPinned ? min(place, pinnedCount) : max(place, pinnedCount)
        // A header with no workspace anywhere inside it is drawn at the next group (or last) of its tier, so a workspace
        // dropped before that group, or at the end, lands before the headers of its own tier directly above the place.
        let referenceIsGroupOrEnd = place >= staying.count || groupByAnchor[staying[place]] != nil
        let atPinnedEnd = place == pinnedCount
        while place > 0, let above = groupByAnchor[staying[place - 1]], ranges[above.id] == nil, above.isPinned == draggedPinned,
              above.isPinned ? (atPinnedEnd || referenceIsGroupOrEnd) : referenceIsGroupOrEnd {
            place -= 1
        }
        // Where it already stands is no drop, as for the unchanged planner (a grouped workspace always leaves its group).
        if moving.count == 1, request.workspaces.first(where: { $0.id == dragged })?.groupId == nil,
           let current = rowIds.firstIndex(of: dragged), current == place {
            return nil
        }
        let line: SidebarDropIndicator = place < staying.count
            ? SidebarDropIndicator(tabId: staying[place], edge: .top)
            : SidebarDropIndicator(tabId: nil, edge: .bottom)   // the end of the list, which the table always draws
        // The commit reads the first row at or after the index that does not move: the index of that row, or the end.
        let target = place < staying.count ? (withoutDragged.firstIndex(of: staying[place]) ?? withoutDragged.count) : withoutDragged.count
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: dragged,
            indicator: line,
            indicatorScope: .topLevel,
            action: .reorder(targetIndex: target, usesTopLevelRows: true, explicitGroupId: nil)
        )
    }

    /// A workspace into a group: an index into `workspaces` and the group to join.
    private func groupPlan(workspace: UUID, group: UUID, place: SidebarNestedDropPlace) -> SidebarWorkspaceReorderDropPlan? {
        guard let snapshot = groupsById[group], let from = tabIndex[workspace] else { return nil }
        let moved = request.workspaces[from]
        let scope = SidebarWorkspaceReorderDropIndicatorScope.group(group)
        // A group with no workspace of its own takes the dropped one as its own: it stands behind the name, so the
        // place inside the group does not matter. The line is the header's lower edge.
        if snapshot.isEmpty || ownWorkspaceId(of: group) == nil {
            let slot = reduced(blockStart(of: group))
            return SidebarWorkspaceReorderDropPlan(
                draggedWorkspaceId: workspace,
                indicator: SidebarDropIndicator(tabId: snapshot.anchorWorkspaceId, edge: .bottom),
                indicatorScope: scope,
                action: .reorder(targetIndex: slot, usesTopLevelRows: false, explicitGroupId: group)
            )
        }
        let requested: Int
        switch place {
        case .tabs(let index):
            requested = index
        case .afterHeader:
            guard let first = boundaries(of: group)?.positions.first else { return nil }
            requested = first
        }
        guard let boundary = legalBoundary(level: group, isPinned: moved.isPinned, requested: requested) else { return nil }
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: workspace,
            indicator: indicator(atBoundary: boundary, inRunOf: group, dropper: Dropper(isPinned: moved.isPinned, isGroup: false))
                ?? SidebarDropIndicator(tabId: snapshot.anchorWorkspaceId, edge: .bottom),
            indicatorScope: scope,
            action: .reorder(
                targetIndex: boundary,
                usesTopLevelRows: false,
                explicitGroupId: group
            )
        )
    }

    // MARK: - A nested header that has a workspace

    /// Among its parent's rows of the same pin tier, and nowhere else.
    func nestedHeaderPlan(group: UUID, context: SidebarWorkspaceReorderHitContext) -> SidebarWorkspaceReorderDropPlan? {
        guard let parent = tree.parent(of: group),
              let snapshot = groupsById[group],
              let stretch = ranges[group],
              let requested = rowBoundary(level: parent, context: context),
              !pointerIsInside(group: group, context: context),
              let boundary = legalBoundary(level: parent, isPinned: snapshot.isPinned, requested: requested) else {
            return nil
        }
        // Where it already sits is no drop, as for a header at the top level.
        if request.draggedBlockWorkspaceIds.count <= 1, boundary == reduced(stretch.lowerBound) {
            return nil
        }
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: snapshot.anchorWorkspaceId,
            indicator: indicator(atBoundary: boundary, inRunOf: parent, dropper: Dropper(isPinned: snapshot.isPinned, isGroup: true)),
            indicatorScope: .group(parent),
            action: .reorder(
                targetIndex: boundary,
                usesTopLevelRows: false,
                explicitGroupId: parent
            )
        )
    }

    // MARK: - A header with no workspace of its own

    /// An index among the groups beside it, and nowhere else. A top-level header with no workspace anywhere inside it
    /// takes the unchanged planner's index (it splits by the half of the row it is over, as in v0.31.0); a header that
    /// holds groups, and a nested one, split by the half of the whole block of the group it is over.
    func emptyHeaderPlan(
        resolver: SidebarWorkspaceReorderDropResolver,
        group: UUID,
        context: SidebarWorkspaceReorderHitContext
    ) -> SidebarWorkspaceReorderDropPlan? {
        guard let snapshot = groupsById[group] else { return nil }
        let parent = tree.parent(of: group)
        let siblings = tree.children(of: parent)
        guard let current = siblings.firstIndex(of: group) else { return nil }
        let scope: SidebarWorkspaceReorderDropIndicatorScope = parent.map { .group($0) } ?? .topLevel
        let listIndex: (Int) -> Int = { sibling in
            request.groups.firstIndex { $0.id == siblings[sibling] } ?? 0
        }
        func selfPlan() -> SidebarWorkspaceReorderDropPlan {
            SidebarWorkspaceReorderDropPlan(
                draggedWorkspaceId: group,
                indicator: SidebarDropIndicator(tabId: snapshot.anchorWorkspaceId, edge: context.edge),
                indicatorScope: scope,
                action: .reorderGroup(targetIndex: listIndex(current))
            )
        }
        if pointerIsInside(group: group, context: context) { return selfPlan() }

        let others = siblings.filter { $0 != group }
        let final: Int
        if parent == nil, ranges[group] == nil {
            // The unchanged planner's index among the top-level groups (the flattened request lists only those).
            guard let flat = resolver.plan(for: flattenedRequest()), case .reorderGroup(let index) = flat.action else { return nil }
            final = max(0, min(index, others.count))
        } else {
            guard let requested = rowBoundary(level: parent, context: context) else { return nil }
            var insertion = others.count
            for (index, sibling) in others.enumerated() {
                if let range = ranges[sibling], range.lowerBound >= requested {
                    insertion = index
                    break
                }
            }
            // Held inside the stretch of groups of its own pin tier.
            let sameTier = siblings.indices.filter { groupsById[siblings[$0]]?.isPinned == snapshot.isPinned }
            final = max(sameTier.first ?? current, min(insertion, sameTier.last ?? current))
        }

        let indicator: SidebarDropIndicator?
        if ranges[group] != nil {
            // A group with workspaces takes the place of the group now at that position among the groups that have some:
            // the groups swap their stretches and the rows between stay. So the line is at the top of the stretch it moves
            // up to, below the stretch it moves down to, or at its own top when it stays.
            let live = siblings.filter { ranges[$0] != nil }
            let currentLive = live.firstIndex(of: group) ?? 0
            let newLive = min(others.prefix(final).filter { ranges[$0] != nil }.count, live.count - 1)
            let target = live[newLive]
            let anchor: (UUID) -> UUID? = { groupsById[$0]?.anchorWorkspaceId }
            if newLive == currentLive, final > current, final - 1 < others.count, ranges[others[final - 1]] == nil,
               let passed = anchor(others[final - 1]) {
                // It passes headers with no workspace in the list of groups, which are then drawn above it.
                indicator = SidebarDropIndicator(tabId: passed, edge: .bottom)
            } else if newLive == currentLive, final < current, final < others.count, ranges[others[final]] == nil,
                      let passed = anchor(others[final]) {
                indicator = SidebarDropIndicator(tabId: passed, edge: .top)
            } else if newLive <= currentLive {
                indicator = SidebarDropIndicator(tabId: anchor(newLive == currentLive ? group : target), edge: .top)
            } else {
                let row = parent == nil ? anchor(target) : lastVisibleRow(inRunOf: target)
                indicator = SidebarDropIndicator(tabId: parent == nil && isLastTopLevelRow(target) ? nil : row, edge: .bottom)
            }
        } else {
            // A header with no workspace is drawn directly above the next group of its own pin tier that is listed after
            // it (a group with workspaces or not), else at the end of its pin tier of the level: below the level's
            // trailing workspaces, not directly below the last group beside it. The line is where it will be drawn.
            if let next = others.dropFirst(final).first(where: { groupsById[$0]?.isPinned == snapshot.isPinned }),
               let header = groupsById[next]?.anchorWorkspaceId {
                indicator = SidebarDropIndicator(tabId: header, edge: .top)
            } else {
                indicator = tierEndLine(level: parent, isPinned: snapshot.isPinned)
            }
        }
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: group,
            indicator: indicator,
            indicatorScope: scope,
            action: .reorderGroup(targetIndex: listIndex(final))
        )
    }

    /// The line at the end of a pin tier of a level: above the first unpinned row for the pinned tier, else below the
    /// last row of the level. At the top level the rows are the top-level ones.
    private func tierEndLine(level: UUID?, isPinned: Bool) -> SidebarDropIndicator? {
        func headerId(_ row: SidebarNestedDropRow) -> UUID? {
            switch row.kind {
            case .workspace(let id): return id
            case .group(let id): return groupsById[id]?.anchorWorkspaceId
            }
        }
        if isPinned, let firstUnpinned = rows(of: level).first(where: { !$0.isPinned }), let id = headerId(firstUnpinned) {
            return SidebarDropIndicator(tabId: id, edge: .top)
        }
        if let level {
            return lastVisibleRow(inRunOf: level).map { SidebarDropIndicator(tabId: $0, edge: .bottom) }
        }
        let lastTopLevel = sortedTargets.last { target in
            chain(of: target).isEmpty || (target.isGroupHeader && (target.groupId.map { tree.parent(of: $0) == nil } ?? false))
        }
        return lastTopLevel == nil ? nil : SidebarDropIndicator(tabId: nil, edge: .bottom)
    }

    /// Whether a top-level group is the last top-level row drawn (its line then goes at the end of the list, which the
    /// table draws whatever the rows under that group are).
    private func isLastTopLevelRow(_ group: UUID) -> Bool {
        let lastTopLevel = sortedTargets.last { target in
            chain(of: target).isEmpty || (target.isGroupHeader && (target.groupId.map { tree.parent(of: $0) == nil } ?? false))
        }
        return lastTopLevel?.groupId == group
    }
}
