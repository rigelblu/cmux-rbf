import CoreGraphics
import Foundation
import Testing
import CmuxFoundation
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): the drop rule, over random nested windows. A drop is planned by the real planner from the rows the
// sidebar draws, at a random row, zone and half of the sidebar, and committed through the real coordinator the way
// the sidebar commits it. After every step: the six rules hold, a refused drop changed nothing, the order-change
// notice is never empty and is exactly the one the rule gives, and the row landed where the plan said.
@MainActor
struct WorkspaceGroupNestedDropRuleTests {
    private static let seeds = 400
    private static let stepsPerSeed = 40
    static let rowHeight: CGFloat = 28
    static let rowStride: CGFloat = 30
    static let width: CGFloat = 240

    /// The planner's request for the sidebar as drawn now: one 28 pt row per header and per shown workspace.
    static func request(
        _ w: NestedWorld,
        point: CGPoint,
        dragged: UUID,
        block: Set<UUID>
    ) -> SidebarWorkspaceReorderDropRequest {
        let groups = w.model.workspaceGroups
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let items = w.model.tabs.map { WorkspaceGroupWorkspaceItem($0) }
        var targets: [SidebarWorkspaceReorderDropTarget] = []
        for (index, row) in WorkspaceGroupRowWalk.rows(groups: groups, workspaces: items).enumerated() {
            let frame = CGRect(x: 0, y: CGFloat(index) * rowStride, width: width, height: rowHeight)
            switch row.kind {
            case .header(let groupId):
                guard let group = groupsById[groupId] else { continue }
                targets.append(SidebarWorkspaceReorderDropTarget(
                    workspaceId: group.anchorWorkspaceId, groupId: group.id, isGroupHeader: true, frame: frame
                ))
            case .workspace(let id):
                let groupId = w.model.tabs.first { $0.id == id }?.groupId.flatMap { groupsById[$0] != nil ? $0 : nil }
                targets.append(SidebarWorkspaceReorderDropTarget(workspaceId: id, groupId: groupId, isGroupHeader: false, frame: frame))
            }
        }
        return SidebarWorkspaceReorderDropRequest(
            point: point,
            draggedWorkspaceId: dragged,
            workspaces: w.model.tabs.map {
                SidebarWorkspaceReorderWorkspaceSnapshot(id: $0.id, isPinned: $0.isPinned, groupId: $0.groupId)
            },
            groups: groups.map {
                SidebarWorkspaceReorderGroupSnapshot(
                    id: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId, isPinned: $0.isPinned,
                    isEmpty: $0.isEmpty, parentGroupId: $0.parentGroupId
                )
            },
            targets: targets,
            draggedBlockWorkspaceIds: block
        )
    }


    /// The rows the sidebar draws and which of them move: a moved workspace's row, and a moved header's row with every
    /// row under it.
    static func drawnRows(
        _ w: NestedWorld,
        movedWorkspaces: Set<UUID>,
        movedGroupIds: Set<UUID>
    ) -> (ids: [UUID], moving: Set<Int>, pinned: [Int: Bool], depth: [Int]) {
        let groupsNow = Dictionary(uniqueKeysWithValues: w.model.workspaceGroups.map { ($0.id, $0) })
        let rows = WorkspaceGroupRowWalk.rows(groups: w.model.workspaceGroups, workspaces: w.model.tabs.map { WorkspaceGroupWorkspaceItem($0) })
        let ids: [UUID] = rows.map { row in
            switch row.kind {
            case .header(let groupId): return groupsNow[groupId]?.anchorWorkspaceId ?? groupId
            case .workspace(let id): return id
            }
        }
        var moving = Set<Int>()
        var pinned: [Int: Bool] = [:]
        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .workspace(let id) where movedWorkspaces.contains(id):
                moving.insert(index)
                pinned[index] = w.model.tabs.first { $0.id == id }?.isPinned ?? false
            case .header(let groupId) where movedGroupIds.contains(groupId):
                moving.insert(index)
                let isPinned = groupsNow[groupId]?.isPinned ?? false
                pinned[index] = isPinned
                var next = index + 1
                while next < rows.count, rows[next].depth > row.depth { moving.insert(next); pinned[next] = isPinned; next += 1 }
            default:
                break
            }
        }
        return (ids, moving, pinned, rows.map(\.depth))
    }

    /// Where a line stands among the rows that do not move: the number of such rows above it. A line against a
    /// top-level row in the top-level scope stands below that row's whole stretch, as the table draws it.
    static func gap(
        of indicator: SidebarDropIndicator,
        scope: SidebarWorkspaceReorderDropIndicatorScope,
        in drawn: (ids: [UUID], moving: Set<Int>, pinned: [Int: Bool], depth: [Int])
    ) -> Int? {
        let staying = drawn.ids.indices.filter { !drawn.moving.contains($0) }
        guard let id = indicator.tabId else { return staying.count }
        guard let at = drawn.ids.firstIndex(of: id) else { return nil }
        if indicator.edge == .top { return staying.filter { $0 < at }.count }
        var end = at
        if scope == .topLevel {
            while end + 1 < drawn.ids.count, drawn.depth[end + 1] > drawn.depth[at] { end += 1 }
        }
        return staying.filter { $0 <= end }.count
    }

    /// The rows the table's painter reads for a plan's scope (the same rows `sidebarDropIndicatorRowIds` builds), in display order.
    static func scopeRowIds(
        _ plan: SidebarWorkspaceReorderDropPlan,
        _ w: NestedWorld,
        dragged: UUID,
        visible: [UUID]
    ) -> [UUID] {
        let groups = w.model.workspaceGroups
        switch plan.indicatorScope {
        case .raw:
            return w.model.tabs.map(\.id)
        case .topLevel:
            let set = Set(w.model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(promotingWorkspaceId: dragged))
                .union(groups.filter(\.isEmpty).map(\.anchorWorkspaceId))
            return visible.filter { set.contains($0) }
        case .group(let groupId):
            let tree = WorkspaceGroupTree(groups: groups)
            let groupByAnchor = Dictionary(groups.map { ($0.anchorWorkspaceId, $0.id) }, uniquingKeysWith: { first, _ in first })
            let groupOfTab = Dictionary(w.model.tabs.compactMap { tab in tab.groupId.map { (tab.id, $0) } }, uniquingKeysWith: { first, _ in first })
            return visible.filter { id in
                guard let row = groupByAnchor[id] ?? groupOfTab[id], tree.contains(row) else { return false }
                return row == groupId || tree.isInside(row, groupId)
            }
        }
    }

    /// What the AppKit table paints for a plan, by the rules of its painter: a line at the bottom of a row is the top of the
    /// next row in the scope's rows, nothing is painted on the dragged row, and a line below the scope's last row is the
    /// scope's own end line. Returns the number of rows that stay above the painted line, or nil when nothing is painted.
    static func paintedGap(
        _ plan: SidebarWorkspaceReorderDropPlan,
        _ w: NestedWorld,
        dragged: UUID,
        drawn: (ids: [UUID], moving: Set<Int>, pinned: [Int: Bool], depth: [Int])
    ) -> Int? {
        guard let indicator = plan.indicator else { return nil }
        let visible = drawn.ids
        let ids = scopeRowIds(plan, w, dragged: dragged, visible: visible)
        let predicate = SidebarTabDropIndicatorPredicate()
        let staying = visible.indices.filter { !drawn.moving.contains($0) }
        for id in ids where id != dragged {
            if predicate.topVisible(forTabId: id, draggedTabId: dragged, dropIndicator: indicator, tabIds: ids),
               let at = visible.firstIndex(of: id) {
                return staying.filter { $0 < at }.count
            }
        }
        if let last = ids.last, last != dragged,
           predicate.bottomVisible(forTabId: last, draggedTabId: dragged, dropIndicator: indicator, tabIds: ids, indicatorScope: plan.indicatorScope),
           let at = visible.lastIndex(of: last) {
            return staying.filter { $0 <= at }.count
        }
        if !plan.indicatorScope.isGroup,
           predicate.emptyAreaTopVisible(draggedTabId: dragged, dropIndicator: indicator, lastTabId: ids.last, indicatorScope: plan.indicatorScope) {
            return staying.count
        }
        return nil
    }

    /// A line that no painter can draw: it is on the dragged row, or it is the bottom of a row, the next row of the scope is the dragged one, and no row
    /// that stays comes after it in the scope, so the line is under the last row that stays and above rows that all leave
    /// (a block gathered at the grabbed row at the end of a group). The table never paints on the dragged row; v0.31.0
    /// draws nothing there either. A line with a row that stays after it is not this.
    static func isBehindTheDraggedRowAtTheEndOfItsScope(
        _ plan: SidebarWorkspaceReorderDropPlan,
        _ w: NestedWorld,
        dragged: UUID,
        drawn: (ids: [UUID], moving: Set<Int>, pinned: [Int: Bool], depth: [Int])
    ) -> Bool {
        guard let indicator = plan.indicator, let rowId = indicator.tabId else { return false }
        // On the grabbed row itself: a block gathered where the grabbed row stands, as v0.31.0 draws it.
        if rowId == dragged { return true }
        guard indicator.edge == .bottom else { return false }
        let ids = scopeRowIds(plan, w, dragged: dragged, visible: drawn.ids)
        guard let at = ids.firstIndex(of: rowId), at + 1 < ids.count, ids[at + 1] == dragged else { return false }
        return ids[(at + 1)...].allSatisfy { id in
            drawn.ids.firstIndex(of: id).map { drawn.moving.contains($0) } ?? false
        }
    }

    /// The pointer positions of a drawn sidebar: each row's upper half, lower half and bottom edge on both halves,
    /// and below every row.
    static func pointerPositions(_ request: SidebarWorkspaceReorderDropRequest) -> [CGPoint] {
        var points: [CGPoint] = []
        for target in request.targets {
            for y in [target.frame.minY + 7, target.frame.minY + 21, target.frame.maxY - 1] {
                for x in [CGFloat(60), 180] { points.append(CGPoint(x: x, y: y)) }
            }
        }
        let below = (request.targets.map(\.frame.maxY).max() ?? 0) + 40
        points.append(CGPoint(x: 60, y: below))
        points.append(CGPoint(x: 180, y: below))
        return points
    }

    /// Commits a plan the way `ContentView.performWorkspaceReorderPlan` does.
    static func commit(_ plan: SidebarWorkspaceReorderDropPlan, _ w: NestedWorld, selected: Set<UUID>) -> Bool {
        switch plan.action {
        case .reorderGroup(let index):
            guard w.model.workspaceGroups.contains(where: { $0.id == plan.draggedWorkspaceId }) else { return false }
            w.groups.moveWorkspaceGroup(groupId: plan.draggedWorkspaceId, toIndex: index)
            return true
        case .reorder(let index, let topLevel, let group):
            let moving = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
                orderedWorkspaceIds: w.model.tabs.map(\.id),
                selectedIds: selected,
                draggedId: plan.draggedWorkspaceId,
                anchorIds: Set(w.model.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
            )
            if moving.count > 1 {
                return w.reorder.reorderSidebarWorkspaces(
                    tabIds: moving, draggedTabId: plan.draggedWorkspaceId, toIndex: index,
                    isDragOperation: true, usesTopLevelRows: topLevel, explicitGroupId: group
                )
            }
            return w.reorder.reorderSidebarWorkspace(
                tabId: plan.draggedWorkspaceId, toIndex: index,
                isDragOperation: true, usesTopLevelRows: topLevel, explicitGroupId: group
            )
        case .crossWindow, .colorSection:
            return false
        }
    }

    @Test
    func aPlannedDropCommitsLegallyAndNamesTheRightWorkspaces() {
        var tried = [String: Int](), planned = [String: Int](), committed = [String: Int](), changed = [String: Int](), landed = [String: Int](), standInChecked = [String: Int](), paintedLine = [String: Int](), unpainted = [String: Int]()
        var failures: [String] = []
        var windows = 0
        for index in 0..<Self.seeds {
            let seed = UInt64(6_000_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            var start = randomNestedWindow(&rng, &lab)
            start.bareRepair()
            let w = NestedWorld(start)
            // A few folded groups, so rows are hidden.
            for groupIndex in w.model.workspaceGroups.indices where Int.random(in: 0..<6, using: &rng) == 0 {
                w.model.workspaceGroups[groupIndex].isCollapsed = true
            }
            guard w.model.hasNestedWorkspaceGroup else { continue }
            windows += 1
            for step in 0..<Self.stepsPerSeed {
                guard w.model.tabs.count >= 2 else { break }
                let groups = w.model.workspaceGroups
                let anchors = Set(groups.compactMap(\.liveAnchorWorkspaceId))
                // What is dragged: a workspace, a header that has a workspace (nested or top-level), a header with none.
                let kind: String
                let dragged: UUID
                var selected: Set<UUID> = []
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<4:
                    guard let tab = w.model.tabs.filter({ !anchors.contains($0.id) }).randomElement(using: &rng) else { continue }
                    kind = tab.groupId == nil ? "loose workspace" : "grouped workspace"
                    dragged = tab.id
                case 4..<5:
                    guard let tab = w.model.tabs.filter({ !anchors.contains($0.id) }).randomElement(using: &rng) else { continue }
                    kind = "several workspaces"
                    dragged = tab.id
                    selected = Set(w.model.tabs.filter { !anchors.contains($0.id) && Bool.random(using: &rng) }.map(\.id)).union([tab.id])
                case 5..<7:
                    guard let group = groups.filter({ $0.parentGroupId != nil && $0.liveAnchorWorkspaceId != nil }).randomElement(using: &rng),
                          let anchor = group.liveAnchorWorkspaceId else { continue }
                    kind = "nested header with a workspace"
                    dragged = anchor
                case 7..<8:
                    guard let group = groups.filter({ $0.parentGroupId == nil && $0.liveAnchorWorkspaceId != nil }).randomElement(using: &rng),
                          let anchor = group.liveAnchorWorkspaceId else { continue }
                    kind = "top-level header with a workspace"
                    dragged = anchor
                case 8..<9:
                    guard let group = groups.filter({ $0.liveAnchorWorkspaceId == nil }).randomElement(using: &rng) else { continue }
                    kind = group.parentGroupId == nil ? "top-level header with none" : "nested header with none"
                    dragged = group.id
                default:
                    guard let group = groups.filter({ $0.liveAnchorWorkspaceId != nil }).randomElement(using: &rng),
                          let anchor = group.liveAnchorWorkspaceId else { continue }
                    kind = "several headers"
                    dragged = anchor
                    // The headers beside it, or at random.
                    let others = groups.filter { Bool.random(using: &rng) && $0.liveAnchorWorkspaceId != nil }.compactMap(\.liveAnchorWorkspaceId)
                    selected = Set(others).union([anchor])
                }
                if kind != "several workspaces", kind != "several headers" { selected = [] }
                let block = Set(SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
                    orderedWorkspaceIds: w.model.tabs.map(\.id), selectedIds: selected, draggedId: dragged, anchorIds: anchors
                ))
                let blockForPlanner: Set<UUID> = block.count > 1 ? block : []

                // A random pointer position over the drawn sidebar.
                let probe = Self.request(w, point: .zero, dragged: dragged, block: blockForPlanner)
                guard let point = Self.pointerPositions(probe).randomElement(using: &rng) else { continue }
                let request = Self.request(w, point: point, dragged: dragged, block: blockForPlanner)
                // A row inside a folded group is not drawn, so no user can start a drag on it.
                let draggedRow = w.model.workspaceGroups.first { $0.id == dragged }.map { $0.anchorWorkspaceId ?? $0.id } ?? dragged
                guard Self.drawnRows(w, movedWorkspaces: [], movedGroupIds: []).ids.contains(draggedRow) else { continue }
                tried[kind, default: 0] += 1
                guard let plan = SidebarWorkspaceReorderDropResolver().plan(for: request) else { continue }
                planned[kind, default: 0] += 1

                let movedWorkspaces: Set<UUID>
                let movedGroups: Set<UUID>
                switch plan.action {
                case .reorderGroup:
                    movedWorkspaces = []
                    movedGroups = [plan.draggedWorkspaceId]
                default:
                    movedGroups = anchors.contains(dragged)
                        ? Set(w.model.workspaceGroups.filter { (block.count > 1 ? block : [dragged]).contains($0.liveAnchorWorkspaceId ?? UUID()) }.map(\.id))
                        : []
                    movedWorkspaces = movedGroups.isEmpty ? (block.count > 1 ? block : [dragged]) : []
                }
                // A drop into a group with no workspace of its own makes the first moved workspace the one behind its name.
                let adoptedGroup: UUID? = {
                    guard case .reorder(_, false, let group?) = plan.action, !anchors.contains(dragged) else { return nil }
                    return w.model.workspaceGroups.first { $0.id == group && $0.liveAnchorWorkspaceId == nil }?.id
                }()
                let drawnBefore = Self.drawnRows(w, movedWorkspaces: movedWorkspaces, movedGroupIds: movedGroups)
                let lineGap = plan.indicator.flatMap { Self.gap(of: $0, scope: plan.indicatorScope, in: drawnBefore) }
                let painted = Self.paintedGap(plan, w, dragged: dragged, drawn: drawnBefore)
                let windowBefore = w.window
                let orderBefore = w.model.tabs.map(\.id)
                let noticesBefore = w.host.orderChanges.count
                let ok = Self.commit(plan, w, selected: selected)
                let orderAfter = w.model.tabs.map(\.id)
                let notices = Array(w.host.orderChanges.dropFirst(noticesBefore))
                let here = "seed \(seed) step \(step) \(kind) dragged \(lab.name(dragged)) block \(block.map { lab.name($0) }.sorted()) | line \(plan.indicator.map { "\($0.tabId.map { lab.name($0) } ?? "END").\($0.edge == .top ? "top" : "bottom")" } ?? "none") \(plan.indicatorScope) | plan \(plan.action) | before \(cmuxCompact(windowBefore, lab)) | after \(w.compact(lab)) | notices \(notices.map { $0.map { lab.name($0) } })"

                let broken = w.violations(lab)
                if !broken.isEmpty { failures.append("rules broken \(broken): \(here)") }
                if !ok {
                    // A drop that was planned and is refused shows a line that lies: a failure, and it changed nothing.
                    failures.append("a planned drop was refused: \(here)")
                    if w.window != windowBefore { failures.append("a refused drop changed the window: \(here)") }
                    continue
                }
                committed[kind, default: 0] += 1
                if w.window != windowBefore {
                    changed[kind, default: 0] += 1
                    // The table must paint a line for a drop that changes the window, at the gap the plan means.
                    if let painted {
                        if let lineGap, painted != lineGap { failures.append("the table paints the line at gap \(painted), the plan means gap \(lineGap): \(here)") }
                        paintedLine[kind, default: 0] += 1
                    } else if Self.isBehindTheDraggedRowAtTheEndOfItsScope(plan, w, dragged: dragged, drawn: drawnBefore) {
                        unpainted[kind, default: 0] += 1   // counted, not failed: no painter can draw it
                    } else {
                        failures.append("a drop that changes the window has no painted line: \(here)")
                    }
                }

                // The notice rule.
                if orderAfter != orderBefore {
                    let expected: [UUID]
                    switch plan.action {
                    case .reorderGroup:
                        expected = w.model.workspaceIdsInside(plan.draggedWorkspaceId)
                    case .reorder:
                        if anchors.contains(dragged), block.count <= 1 {
                            let group = w.model.workspaceGroups.first { $0.liveAnchorWorkspaceId == dragged }
                            expected = group.map { w.model.workspaceIdsInside($0.id) } ?? []
                        } else if anchors.contains(dragged) {
                            let moved = Set(w.model.workspaceGroups.filter { block.contains($0.liveAnchorWorkspaceId ?? UUID()) }.flatMap { w.model.workspaceIdsInside($0.id) })
                            expected = w.model.tabs.map(\.id).filter(moved.contains)
                        } else if block.count > 1 {
                            expected = orderBefore.filter(block.contains)
                        } else {
                            expected = [dragged]
                        }
                    default:
                        expected = []
                    }
                    if notices.isEmpty {
                        failures.append("no notice: \(here)")
                    } else if notices != [expected] {
                        failures.append("notice \(notices.map { $0.map { lab.name($0) } }) is not \(expected.map { lab.name($0) }): \(here)")
                    }
                }

                // The line the plan drew is where the rows landed: the same number of rows that stay stand above the line
                // before the drop and above the moved rows after it. Every kind of plan, a block, a root plan and a plan
                // among the groups beside a header included.
                if let adoptedGroup {
                    let anchor = w.model.workspaceGroups.first { $0.id == adoptedGroup }?.liveAnchorWorkspaceId
                    if anchor == nil || !(movedWorkspaces.contains(anchor!)) { failures.append("the adopting group has no moved workspace behind its name: \(here)") }
                    // The group's name was a header with nothing behind it; it is the same row after the drop, now with the first
                    // moved workspace behind it. The line stood on that row, below it, and the rest land inside the group.
                    let drawnAfter = Self.drawnRows(w, movedWorkspaces: movedWorkspaces.subtracting([anchor ?? UUID()]), movedGroupIds: [])
                    if let anchor, let header = drawnAfter.ids.firstIndex(of: anchor), let lineGap, lineGap == header + 1 {
                        landed[kind, default: 0] += 1
                    } else {
                        failures.append("an adopting drop: the line is not below the group's header (rows above the line \(String(describing: lineGap))): \(here)")
                    }
                } else if let lineGap {
                    let drawnAfter = Self.drawnRows(w, movedWorkspaces: movedWorkspaces, movedGroupIds: movedGroups)
                    // A selection of both pin tiers lands in two places: the rows of the grabbed row's tier stand at the line.
                    let grabbedPinned = w.model.workspaceGroups.first { $0.liveAnchorWorkspaceId == dragged || $0.id == dragged }?.isPinned
                        ?? (w.model.tabs.first { $0.id == dragged }?.isPinned ?? false)
                    let atLine = drawnAfter.moving.filter { drawnAfter.pinned[$0] == grabbedPinned }
                    if let first = atLine.min(), let last = atLine.max() {
                        let contiguous = atLine.count == last - first + 1
                        let above = (0..<first).filter { !drawnAfter.moving.contains($0) }.count
                        if above != lineGap || !contiguous {
                            failures.append("the line is not where the rows landed (\(lineGap) rows above the line, \(above) above the moved rows, contiguous \(contiguous)): \(here)")
                        } else {
                            landed[kind, default: 0] += 1
                        }
                    } else {
                        // The moved rows stand inside a folded group: the line must be on that group's header, the one row that
                        // stands for them. The outermost folded group above the landing place is the one drawn.
                        var cursor: UUID? = movedGroups.first.flatMap { id in w.model.workspaceGroups.first { $0.id == id }?.parentGroupId }
                            ?? movedWorkspaces.first.flatMap { id in w.model.tabs.first { $0.id == id }?.groupId }
                        var outermostFolded: WorkspaceGroup?
                        while let c = cursor, let g = w.model.workspaceGroups.first(where: { $0.id == c }) {
                            if g.isCollapsed { outermostFolded = g }
                            cursor = g.parentGroupId
                        }
                        if let outermostFolded, plan.indicator?.tabId == (outermostFolded.anchorWorkspaceId ?? outermostFolded.id) {
                            standInChecked[kind, default: 0] += 1
                        } else {
                            failures.append("the moved rows are hidden under a fold and the line is not on the folded group's header: \(here)")
                        }
                    }
                } else {
                    // No gap: the plan has no line, or its row is not drawn. Either way the user sees no line for a drop.
                    failures.append("a planned drop shows no line (\(plan.indicator == nil ? "none" : "its row is not drawn")): \(here)")
                }

                // Where it landed.
                if case .reorder(let toIndex, false, let group?) = plan.action, block.count <= 1 {
                    let tab = w.model.tabs.first { $0.id == dragged }
                    let nowAnchor = w.model.workspaceGroups.first { $0.id == group }?.liveAnchorWorkspaceId
                    if anchors.contains(dragged) {
                        let moved = w.model.workspaceGroups.first { $0.liveAnchorWorkspaceId == dragged }
                        if moved?.parentGroupId != group { failures.append("header left its parent: \(here)") }
                        if orderAfter.firstIndex(of: dragged) != toIndex, !(orderBefore == orderAfter) {
                            failures.append("header's stretch does not start at \(toIndex): \(here)")
                        }
                    } else if tab?.groupId != group {
                        failures.append("workspace is not in the group the plan named: \(here)")
                    } else if nowAnchor != dragged, orderAfter.firstIndex(of: dragged) != toIndex {
                        failures.append("workspace is not at \(toIndex): \(here)")
                    }
                }
            }
        }
        let kinds = Array(Set(tried.keys).union(planned.keys)).sorted()
        let table = kinds.map { "\($0): tried \(tried[$0] ?? 0), planned \(planned[$0] ?? 0), committed \(committed[$0] ?? 0), landed at the line \(landed[$0] ?? 0), line on the folded group that holds the hidden rows \(standInChecked[$0] ?? 0), changed the window \(changed[$0] ?? 0), painted \(paintedLine[$0] ?? 0), unpaintable (on the dragged row, or under the last row above it) \(unpainted[$0] ?? 0)" }
        print("aPlannedDropCommitsLegally: \(windows) nested windows, \(Self.seeds * Self.stepsPerSeed) steps\n  " + table.joined(separator: "\n  "))
        for failure in failures.prefix(60) { print("DROPFAIL \(failure)") }
        #expect(failures.isEmpty, "\(failures.count) drops broke the rule; first: \(failures.prefix(3))")
        // Every planned drop is accounted for: none is left out of the line check.
        for kind in kinds {
            #expect(planned[kind, default: 0] == committed[kind, default: 0], "\(kind): planned \(planned[kind, default: 0]) committed \(committed[kind, default: 0])")
            #expect(committed[kind, default: 0] == landed[kind, default: 0] + standInChecked[kind, default: 0], "\(kind): \(committed[kind, default: 0]) committed, \(landed[kind, default: 0]) landed at the line, \(standInChecked[kind, default: 0]) on the folded group's header")
        }
        for kind in [
            "loose workspace", "grouped workspace", "several workspaces", "nested header with a workspace",
            "top-level header with a workspace", "top-level header with none", "nested header with none", "several headers"
        ] {
            #expect((changed[kind] ?? 0) >= 5, "too few drops changed the window for \(kind): \(changed[kind] ?? 0) of \(planned[kind] ?? 0) planned, \(tried[kind] ?? 0) tried")
        }
    }
}
