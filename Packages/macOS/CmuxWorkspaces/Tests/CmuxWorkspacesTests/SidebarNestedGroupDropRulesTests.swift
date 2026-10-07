import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

// The drop rule for a group inside a group (#cm-106): what a drop plans at the edges of nested groups, in both
// halves of the sidebar, for a workspace, a nested header that has a workspace, and a header with none.

/// The whole plan, as one comparable line: the dragged id, the line, its scope and the action, by name.
func describePlan(_ plan: SidebarWorkspaceReorderDropPlan?, in window: NestedDropWindow) -> String {
    guard let plan else { return "no plan" }
    func name(_ id: UUID?) -> String {
        guard let id else { return "end" }
        return window.ids.first { $0.value == id }?.key.replacingOccurrences(of: "g:", with: "group ") ?? "?"
    }
    let line = plan.indicator.map { "\(name($0.tabId)).\($0.edge == .top ? "top" : "bottom")" } ?? "none"
    let scope: String
    switch plan.indicatorScope {
    case .raw: scope = "raw"
    case .topLevel: scope = "topLevel"
    case .group(let id): scope = "in \(name(id))"
    }
    let action: String
    switch plan.action {
    case .reorder(let index, let topLevel, let group):
        action = "reorder \(index) \(topLevel ? "top-level rows" : "workspaces") group \(group.map { name($0) } ?? "none")"
    case .reorderGroup(let index):
        action = "reorderGroup \(index)"
    case .crossWindow(let index, let proposed):
        action = "crossWindow \(index) \(proposed)"
    case .colorSection:
        action = "colorSection"
    }
    return "\(name(plan.draggedWorkspaceId)) line \(line) \(scope): \(action)"
}

@Suite struct SidebarNestedGroupDropRulesTests {
    /// `L1 | P[pa | Q[qa | S[sa sb] | qb] | pb] | L2`, every group with a workspace behind its name (p0, q0, s0).
    /// Storage order: L1 0, p0 1, pa 2, q0 3, qa 4, s0 5, sa 6, sb 7, qb 8, pb 9, L2 10.
    private func threeLevels(pName: String? = "p0") -> NestedDropWindow {
        NestedDropWindow([
            .ws("L1"),
            .grp("P", own: pName, [
                .ws("pa"),
                .grp("Q", own: "q0", [.ws("qa"), .grp("S", own: "s0", [.ws("sa"), .ws("sb")]), .ws("qb")]),
                .ws("pb"),
            ]),
            .ws("L2"),
        ])
    }

    // MARK: A workspace at the edge below a group's last row

    @Test func edgeBelowTheInnermostGroupsLastRowSplitsByHalf() {
        let w = threeLevels()
        // sb ends S; qb follows inside Q. Right half: S. Left half: Q, directly below S's rows.
        #expect(describePlan(w.plan("L2", "sb", .bottomEdge, .right), in: w)
                == "L2 line sb.bottom in group S: reorder 8 workspaces group group S")
        #expect(describePlan(w.plan("L2", "sb", .bottomEdge, .left), in: w)
                == "L2 line qb.top in group Q: reorder 8 workspaces group group Q")
    }

    @Test func edgeWhereTwoGroupsEndLeavesOneLevelOnTheLeft() {
        let w = threeLevels()
        // qb ends Q; pb follows inside P. Right: Q. Left: P, directly below Q's rows.
        #expect(describePlan(w.plan("L2", "qb", .bottomEdge, .right), in: w)
                == "L2 line qb.bottom in group Q: reorder 9 workspaces group group Q")
        #expect(describePlan(w.plan("L2", "qb", .bottomEdge, .left), in: w)
                == "L2 line pb.top in group P: reorder 9 workspaces group group P")
    }

    @Test func edgeWhereEveryGroupEndsLeavesToTheTopLevelOnTheLeft() {
        let w = threeLevels()
        // pb ends P and the next row is loose. A workspace from inside S: right half P, left half the top level.
        #expect(describePlan(w.plan("sa", "pb", .bottomEdge, .right), in: w)
                == "sa line pb.bottom in group P: reorder 9 workspaces group group P")
        #expect(describePlan(w.plan("sa", "pb", .bottomEdge, .left), in: w)
                == "sa line L2.top topLevel: reorder 2 top-level rows group none")
    }

    @Test func lastRowOfAllThreeLevelsHasThreeLevelsAtItsEdge() {
        // `L1 | P[pa | Q[qa | S[sa sb]]] | L2`: sb ends S, Q and P at once.
        let w = NestedDropWindow([
            .ws("L1"),
            .grp("P", own: "p0", [.ws("pa"), .grp("Q", own: "q0", [.ws("qa"), .grp("S", own: "s0", [.ws("sa"), .ws("sb")])])]),
            .ws("L2"),
        ])
        // Right half: S, the innermost. Left half: the top level, past the outermost group that ends here.
        #expect(describePlan(w.plan("L2", "sb", .bottomEdge, .right), in: w)
                == "L2 line sb.bottom in group S: reorder 8 workspaces group group S")
        #expect(describePlan(w.plan("sa", "sb", .bottomEdge, .left), in: w)
                == "sa line L2.top topLevel: reorder 2 top-level rows group none")
    }

    @Test func belowEveryRowIsTheLastRowsBottomEdge() {
        // `L1 | P[pa | Q[qa | S[sa sb]]]`: nothing below.
        let w = NestedDropWindow([
            .ws("L1"),
            .grp("P", own: "p0", [.ws("pa"), .grp("Q", own: "q0", [.ws("qa"), .grp("S", own: "s0", [.ws("sa"), .ws("sb")])])]),
        ])
        let right = SidebarWorkspaceReorderDropResolver().plan(for: w.request(dragged: w.id("L1"), at: w.belowAll(.right)))
        #expect(describePlan(right, in: w) == "L1 line sb.bottom in group S: reorder 7 workspaces group group S")
        let left = SidebarWorkspaceReorderDropResolver().plan(for: w.request(dragged: w.id("L1"), at: w.belowAll(.left)))
        // The top level's end, as the unchanged planner draws it below a flat group.
        #expect(describePlan(left, in: w) == "L1 line end.bottom topLevel: reorder 1 top-level rows group none")
    }

    // MARK: A workspace on a header, and between rows

    @Test func headersLowerHalfJoinsThatGroupAsItsFirstRowAtAnyLevel() {
        let w = threeLevels()
        #expect(describePlan(w.plan("L2", "q0", .lower, .left), in: w)
                == "L2 line qa.top in group Q: reorder 4 workspaces group group Q")
        #expect(describePlan(w.plan("L2", "s0", .lower, .right), in: w)
                == "L2 line sa.top in group S: reorder 6 workspaces group group S")
    }

    @Test func headersUpperHalfIsTheBoundaryBeforeItsGroupInTheLevelThatHoldsIt() {
        let w = threeLevels()
        // A nested header's top edge is a place among its parent's rows, in either half.
        #expect(describePlan(w.plan("L2", "s0", .upper, .left), in: w)
                == "L2 line s0.top in group Q: reorder 5 workspaces group group Q")
        #expect(describePlan(w.plan("L2", "s0", .upper, .right), in: w)
                == "L2 line s0.top in group Q: reorder 5 workspaces group group Q")
        // A top-level header's top edge is a top-level row, as before.
        #expect(describePlan(w.plan("L2", "p0", .upper, .right), in: w)
                == "L2 line p0.top topLevel: reorder 1 top-level rows group none")
    }

    @Test func betweenTwoRowsOfAParentIsThatParentWithAChildGroupCountedAsOneRow() {
        let w = threeLevels()
        // qa's lower half is the boundary above S's header, a row of Q.
        #expect(describePlan(w.plan("L2", "qa", .lower, .left), in: w)
                == "L2 line s0.top in group Q: reorder 5 workspaces group group Q")
        // pa's lower half is the boundary above Q's header, a row of P.
        #expect(describePlan(w.plan("L2", "pa", .bottomEdge, .right), in: w)
                == "L2 line q0.top in group P: reorder 3 workspaces group group P")
    }

    // MARK: Pin tiers

    @Test func unpinnedWorkspaceLandsFirstOfTheUnpinnedRowsWhenDroppedAmongPinnedOnes() {
        // `P[pa(pinned) | S(pinned)[sa sb] | pb]`: pinned rows first. An unpinned workspace dropped at the edge
        // below S (left half: P) goes below the pinned rows, which here is directly below S.
        let w = NestedDropWindow([
            .grp("P", own: "p0", [.ws("pa", pinned: true), .grp("S", own: "s0", pinned: true, [.ws("sa"), .ws("sb")]), .ws("pb")]),
            .ws("L2"),
        ])
        #expect(describePlan(w.plan("L2", "sb", .bottomEdge, .left), in: w)
                == "L2 line pb.top in group P: reorder 5 workspaces group group P")
        // Dropped above the pinned rows' end, in P's pinned stretch, it is held below them.
        #expect(describePlan(w.plan("L2", "pa", .upper, .right), in: w)
                == "L2 line pb.top in group P: reorder 5 workspaces group group P")
    }

    // MARK: A folded group

    @Test func foldedGroupHeaderJoinsOnItsLowerHalfAndSplitsBelowIt() {
        // `P[pa | Q(folded)[qa qb] | pb]`: Q shows its header only.
        let w = NestedDropWindow([
            .ws("L1"),
            .grp("P", own: "p0", [.ws("pa"), .grp("Q", own: "q0", folded: true, [.ws("qa"), .ws("qb")]), .ws("pb")]),
        ])
        #expect(describePlan(w.plan("L1", "q0", .lower, .left), in: w)
                == "L1 line q0.bottom in group Q: reorder 3 workspaces group group Q")
        // The edge below a folded header is its lower half: the same plan (it joins Q).
        #expect(describePlan(w.plan("L1", "q0", .bottomEdge, .right), in: w)
                == "L1 line q0.bottom in group Q: reorder 3 workspaces group group Q")
    }

    // MARK: A header with no workspace of its own

    @Test func workspaceDroppedIntoAHeaderWithNoWorkspaceBecomesItsOwn() {
        // `P(no workspace)[ pa | Q[qa] ]`
        let w = NestedDropWindow([
            .grp("P", own: nil, [.ws("pa"), .grp("Q", own: "q0", [.ws("qa")])]),
            .ws("L2"),
        ])
        #expect(describePlan(w.plan("L2", "hdr:P", .lower, .right), in: w)
                == "L2 line hdr:P.bottom in group P: reorder 0 workspaces group group P")
        // The upper half: the right half joins it, the left half is the level that holds it.
        #expect(describePlan(w.plan("L2", "hdr:P", .upper, .right), in: w)
                == "L2 line hdr:P.bottom in group P: reorder 0 workspaces group group P")
        #expect(describePlan(w.plan("L2", "hdr:P", .upper, .left), in: w)
                == "L2 line hdr:P.top topLevel: reorder 0 top-level rows group none")
    }
}

// MARK: - A nested header that has a workspace

@Suite struct SidebarNestedHeaderDropTests {
    /// `L1 | P[pa | Q[qa] | R[ra] | pb] | L2`. Storage: L1 0, p0 1, pa 2, q0 3, qa 4, r0 5, ra 6, pb 7, L2 8.
    private func window() -> NestedDropWindow {
        NestedDropWindow([
            .ws("L1"),
            .grp("P", own: "p0", [
                .ws("pa"),
                .grp("Q", own: "q0", [.ws("qa")]),
                .grp("R", own: "r0", [.ws("ra")]),
                .ws("pb"),
            ]),
            .ws("L2"),
        ])
    }

    @Test func headerMovesAmongItsParentsRows() {
        let w = window()
        // Above pa; below R's whole run (the lower half of ra); below pb.
        #expect(describePlan(w.plan("q0", "pa", .upper, .right), in: w)
                == "q0 line pa.top in group P: reorder 2 workspaces group group P")
        #expect(describePlan(w.plan("q0", "ra", .lower, .left), in: w)
                == "q0 line pb.top in group P: reorder 5 workspaces group group P")
        #expect(describePlan(w.plan("q0", "pb", .lower, .right), in: w)
                == "q0 line pb.bottom in group P: reorder 6 workspaces group group P")
        // Into the first place from the parent's own header.
        #expect(describePlan(w.plan("q0", "p0", .lower, .right), in: w)
                == "q0 line pa.top in group P: reorder 2 workspaces group group P")
    }

    @Test func headerWhereItAlreadySitsIsNoDrop() {
        let w = window()
        #expect(describePlan(w.plan("q0", "pa", .lower, .left), in: w) == "no plan")
        #expect(describePlan(w.plan("q0", "r0", .upper, .left), in: w) == "no plan")
        #expect(describePlan(w.plan("q0", "qa", .upper, .left), in: w) == "no plan")
        #expect(describePlan(w.plan("q0", "q0", .lower, .left), in: w) == "no plan")
    }

    @Test func headerAnywhereOutsideItsParentIsNoDrop() {
        let w = window()
        for half in [DropHalf.left, .right] {
            for zone in [DropZone.upper, .lower, .bottomEdge] {
                #expect(w.plan("q0", "L1", zone, half) == nil)
                #expect(w.plan("q0", "L2", zone, half) == nil)
            }
            #expect(w.plan("q0", "p0", .upper, half) == nil)
        }
        let below = SidebarWorkspaceReorderDropResolver().plan(for: w.request(dragged: w.id("q0"), at: w.belowAll(.left)))
        #expect(below == nil)
    }

    @Test func pinnedHeaderIsHeldAmongThePinnedRows() {
        // `P[pa(pinned) | Q(pinned)[qa] | R[ra] | pb]`: Q is pinned, so dropping it low stays in the pinned stretch.
        let w = NestedDropWindow([
            .grp("P", own: "p0", [
                .ws("pa", pinned: true),
                .grp("Q", own: "q0", pinned: true, [.ws("qa")]),
                .grp("R", own: "r0", [.ws("ra")]),
                .ws("pb"),
            ]),
        ])
        // Below pb is past the pinned rows: Q goes to the end of the pinned stretch, where it already sits.
        #expect(describePlan(w.plan("q0", "pb", .lower, .left), in: w) == "no plan")
        // Above pa is inside the pinned stretch: allowed.
        #expect(describePlan(w.plan("q0", "pa", .upper, .left), in: w)
                == "q0 line pa.top in group P: reorder 1 workspaces group group P")
    }

    @Test func severalHeadersMoveOnlyWhenTheySitInTheSameParent() {
        let w = NestedDropWindow([
            .grp("P", own: "p0", [.ws("pa"), .grp("Q", own: "q0", [.ws("qa")]), .grp("R", own: "r0", [.ws("ra")])]),
            .grp("T", own: "t0", [.ws("ta")]),
            .ws("L2"),
        ])
        let sameParent: Set<UUID> = [w.id("q0"), w.id("r0")]
        #expect(w.plan("q0", "pa", .upper, .left, block: sameParent) != nil)
        let mixed: Set<UUID> = [w.id("q0"), w.id("t0")]
        #expect(w.plan("q0", "pa", .upper, .left, block: mixed) == nil)
        // The same for a top-level header grabbed with a nested one.
        #expect(w.plan("t0", "L2", .lower, .left, block: mixed) == nil)
    }
}

// MARK: - A header with no workspace of its own

@Suite struct SidebarNestedEmptyHeaderDropTests {
    /// `L1 | P[pa | E1[ea] | E2[fa] | pb] | L2`, E1 and E2 with no workspace of their own.
    /// Storage: L1 0, p0 1, pa 2, ea 3, fa 4, pb 5, L2 6. Groups: P 0, E1 1, E2 2.
    private func window() -> NestedDropWindow {
        NestedDropWindow([
            .ws("L1"),
            .grp("P", own: "p0", [
                .ws("pa"),
                .grp("E1", own: nil, [.ws("ea")]),
                .grp("E2", own: nil, [.ws("fa")]),
                .ws("pb"),
            ]),
            .ws("L2"),
        ])
    }

    private func plan(_ w: NestedDropWindow, _ row: String, _ zone: DropZone, _ half: DropHalf) -> String {
        describePlan(SidebarWorkspaceReorderDropResolver().plan(
            for: w.request(dragged: w.group("E1"), at: w.point(row, zone, half))
        ), in: w)
    }

    @Test func movesAmongTheGroupsBesideItAsAnIndexOfTheListOfGroups() {
        let w = window()
        // Below E2: the slot of E2 in the list of groups.
        #expect(plan(w, "fa", .lower, .right) == "group E1 line fa.bottom in group P: reorderGroup 2")
        // Above pa: still before E2, which is where it is.
        #expect(plan(w, "pa", .upper, .left) == "group E1 line hdr:E1.top in group P: reorderGroup 1")
    }

    @Test func onItsOwnRowsIsAHandledNoMove() {
        let w = window()
        #expect(plan(w, "ea", .lower, .left).hasPrefix("group E1 line "))
        #expect(plan(w, "ea", .lower, .left).hasSuffix("reorderGroup 1"))
    }

    @Test func outsideItsParentIsNoDrop() {
        let w = window()
        #expect(plan(w, "L1", .upper, .left) == "no plan")
        #expect(plan(w, "L2", .lower, .right) == "no plan")
        #expect(plan(w, "p0", .upper, .left) == "no plan")
    }

    @Test func topLevelHeaderWithNoWorkspaceStaysAmongTheTopLevelGroups() {
        // `L1 | E1[ea] | E2[fa] | P[pa | Q[qa]] | L2`: P holds a group, so the window is nested.
        let w = NestedDropWindow([
            .ws("L1"),
            .grp("E1", own: nil, [.ws("ea")]),
            .grp("E2", own: nil, [.ws("fa")]),
            .grp("P", own: "p0", [.ws("pa"), .grp("Q", own: "q0", [.ws("qa")])]),
            .ws("L2"),
        ])
        // Below P's run (its nested rows count as P's): the slot of P in the list of groups, where P is the third.
        let belowP = SidebarWorkspaceReorderDropResolver().plan(
            for: w.request(dragged: w.group("E1"), at: w.point("qa", .lower, .left))
        )
        #expect(describePlan(belowP, in: w) == "group E1 line p0.bottom topLevel: reorderGroup 2")
    }
}
