import Foundation
import Testing
@testable import CmuxFoundation
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): where a header with no workspace of its own sits among the top-level rows exists three
// times: in the model, in the drop planner's copy, and in the list of rows the sidebar draws. All three read the
// nested meaning: only a top-level group with no workspace inside it, at any level, is placed by the list of groups;
// a group that holds groups stands where its rows stand. One test feeds the three the same cases.
@MainActor
struct WorkspaceGroupNestedEmptyHeaderRuleTests {
    /// The top-level rows, in order, as each of the three copies gives them.
    private func topLevelRows(_ w: NestedWorld) -> (model: [UUID], planner: [UUID], rows: [UUID]) {
        let groups = w.model.workspaceGroups
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let items = w.model.tabs.map { WorkspaceGroupWorkspaceItem($0) }
        let rows = WorkspaceGroupRowWalk.rows(groups: groups, workspaces: items).compactMap { row -> UUID? in
            guard row.depth == 0 else { return nil }
            switch row.kind {
            case .header(let groupId): return groupsById[groupId]?.anchorWorkspaceId
            case .workspace(let id): return id
            }
        }
        let request = WorkspaceGroupNestedDropRuleTests.request(w, point: .zero, dragged: UUID(), block: [])
        return (
            w.model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(),
            SidebarWorkspaceReorderDropResolver().topLevelRowIds(of: request),
            rows
        )
    }

    private func world(
        _ lab: inout Labels,
        tabs: [NestWorkspace],
        groups: [NestGroup]
    ) -> NestedWorld {
        var window = NestWindow(tabs: tabs, groups: groups)
        window.bareRepair()
        return NestedWorld(window)
    }

    @Test
    func theThreeCopiesAgreeOnTheHandWrittenCases() {
        var lab = Labels()
        // 1. An empty header between two groups, one holding a group; a trailing empty header; a pinned empty header.
        let one = world(
            &lab,
            tabs: [lab.ws("u1"), lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C"), lab.ws("u2")],
            groups: [
                lab.group("A", own: "a"), lab.group("E1"), lab.group("B", parent: "A", own: "b"),
                lab.group("C", own: "c"), lab.group("E2"), lab.group("E3", pinned: true)
            ]
        )
        // 2. A parent with no workspace of its own that holds groups, then an empty header and a pinned parent with none.
        var lab2 = Labels()
        let two = world(
            &lab2,
            tabs: [lab2.ws("u1"), lab2.ws("x", in: "X"), lab2.ws("y", in: "Y"), lab2.ws("u2")],
            groups: [
                lab2.group("P"), lab2.group("X", parent: "P", own: "x"), lab2.group("E"), lab2.group("Q", pinned: true),
                lab2.group("Y", parent: "Q", pinned: true, own: "y")
            ]
        )
        // 3. A nested empty header never shows at the top level; an empty header before a parent with none.
        var lab3 = Labels()
        let three = world(
            &lab3,
            tabs: [lab3.ws("u1"), lab3.ws("k", in: "K"), lab3.ws("z", in: "Z"), lab3.ws("u2")],
            groups: [
                lab3.group("E"), lab3.group("P"), lab3.group("K", parent: "P", own: "k"),
                lab3.group("N", parent: "K"), lab3.group("Z", own: "z")
            ]
        )
        for (name, w, lab) in [("one", one, lab), ("two", two, lab2), ("three", three, lab3)] {
            #expect(w.model.hasNestedWorkspaceGroup, "case \(name) is not nested")
            let rows = topLevelRows(w)
            print("theThreeCopies case \(name): \(w.compact(lab)) | rows \(rows.rows.map { lab.name($0) })")
            #expect(rows.model == rows.rows, "case \(name): the model and the list of rows differ")
            #expect(rows.planner == rows.rows, "case \(name): the planner and the list of rows differ")
        }
    }

    /// The planner's own per-level rule: where a header with no workspace anywhere inside it is drawn, as an index into
    /// `workspaces`. It must be the start of the next row at its own level (the list of rows draws a header with none
    /// directly above the next group of its tier, or last of the tier), or the end of the level when no row follows.
    private func plannerSlotsDifferFromTheListOfRows(_ w: NestedWorld, _ lab: Labels) -> [String] {
        let groups = w.model.workspaceGroups
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let tabs = w.model.tabs
        let tabIndex = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        let context = SidebarNestedGroupDropContext(
            request: WorkspaceGroupNestedDropRuleTests.request(w, point: .zero, dragged: UUID(), block: []),
            sortedTargets: []
        )
        let rows = WorkspaceGroupRowWalk.rows(groups: groups, workspaces: tabs.map { WorkspaceGroupWorkspaceItem($0) })
        func start(of row: WorkspaceGroupWalkRow) -> Int? {
            switch row.kind {
            case .workspace(let id): return tabIndex[id]
            case .header(let groupId): return context.ranges[groupId]?.lowerBound
            }
        }
        var problems: [String] = []
        for (index, row) in rows.enumerated() {
            guard case .header(let groupId) = row.kind, context.ranges[groupId] == nil else { continue }
            // The rows after it that are still inside its parent: its own level and the groups below it.
            let inParent = rows[(index + 1)...].prefix { $0.depth >= row.depth }
            let next = inParent.first { $0.depth == row.depth && start(of: $0) != nil }
            let expected: Int
            if let next, let at = start(of: next) {
                expected = at
            } else {
                // No row of its own level follows: the end of the level (pinned: the end of the pinned rows).
                let parent = groupsById[groupId]?.parentGroupId
                let end = parent.flatMap { context.ranges[$0]?.upperBound } ?? tabs.count
                if groupsById[groupId]?.isPinned == true, let firstUnpinned = inParent.first(where: { $0.depth == row.depth }), let at = start(of: firstUnpinned) {
                    expected = at
                } else {
                    expected = end
                }
            }
            if context.blockStart(of: groupId) != expected {
                problems.append("\(lab.name(groupId)) at depth \(row.depth): the planner says \(context.blockStart(of: groupId)), the list of rows \(expected)")
            }
        }
        return problems
    }

    @Test
    func thePlannersPerLevelSlotOfAHeaderWithNoWorkspaceIsWhereTheListOfRowsDrawsIt() {
        var checked = 0, nestedLevels = 0
        var failures: [String] = []
        for index in 0..<300 {
            var rng = SplitMix64(seed: UInt64(8_000_000 + index))
            var lab = Labels()
            var start = randomNestedWindow(&rng, &lab)
            start.bareRepair()
            let w = NestedWorld(start)
            guard w.model.hasNestedWorkspaceGroup else { continue }
            for group in w.model.workspaceGroups where !w.model.tabs.contains(where: { $0.groupId == group.id }) && !w.model.holdsWorkspaceGroups(group.id) {
                checked += 1
                if group.parentGroupId != nil { nestedLevels += 1 }
            }
            failures += plannerSlotsDifferFromTheListOfRows(w, lab).map { "seed \(index): \($0): \(w.compact(lab))" }
        }
        print("thePlannersPerLevelSlot: \(checked) headers with nothing inside, \(nestedLevels) of them below the top level")
        #expect(failures.isEmpty, "\(failures.count): \(failures.prefix(3))")
        #expect(checked >= 100)
        #expect(nestedLevels >= 30)
    }

    @Test
    func theThreeCopiesAgreeOnRandomNestedWindows() {
        var compared = 0, withHeaderOnly = 0, withEmptyOnTop = 0
        var failures: [String] = []
        for index in 0..<300 {
            var rng = SplitMix64(seed: UInt64(7_000_000 + index))
            var lab = Labels()
            var start = randomNestedWindow(&rng, &lab)
            start.bareRepair()
            // Empty some groups: drop the workspace of a group that has exactly its own, by moving them out.
            let w = NestedWorld(start)
            guard w.model.hasNestedWorkspaceGroup else { continue }
            // A few edits so the lists of groups and the rows drift apart as they do in use.
            for _ in 0..<5 {
                var window = w.window
                var counter = 0
                if let record = randomEdit(&window, &rng, &lab, counter: &counter) {
                    _ = record
                    let again = NestedWorld(window)
                    let rows = topLevelRows(again)
                    compared += 1
                    if again.model.workspaceGroups.contains(where: { $0.isEmpty && $0.parentGroupId == nil }) { withEmptyOnTop += 1 }
                    if again.model.workspaceGroups.contains(where: { $0.isEmpty && again.model.holdsWorkspaceGroups($0.id) }) { withHeaderOnly += 1 }
                    if rows.model != rows.rows { failures.append("model vs rows, seed \(index): \(again.compact(lab))") }
                    if rows.planner != rows.rows { failures.append("planner vs rows, seed \(index): \(again.compact(lab))") }
                }
            }
        }
        print("theThreeCopiesAgree: \(compared) windows compared, \(withEmptyOnTop) with a top-level header with none, \(withHeaderOnly) with a parent that has no workspace of its own")
        #expect(failures.isEmpty, "\(failures.count) windows: \(failures.prefix(3))")
        #expect(compared >= 600)
        #expect(withEmptyOnTop >= 50)
        #expect(withHeaderOnly >= 50)
    }
}
