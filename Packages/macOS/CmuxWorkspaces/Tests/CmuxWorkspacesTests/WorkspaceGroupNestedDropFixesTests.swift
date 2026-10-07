import Foundation
import Testing
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): several selected rows, a selection of both pin tiers, a block at a top-level place, and
// the drops that must change nothing. The cases are the review's (CTRL-4 to CTRL-11).
@MainActor
struct WorkspaceGroupNestedDropFixesTests {
    private func world(_ tabs: [NestWorkspace], _ groups: [NestGroup]) -> NestedWorld {
        var window = NestWindow(tabs: tabs, groups: groups)
        window.bareRepair()
        return NestedWorld(window)
    }

    // MARK: Several selected rows (CTRL-5, CTRL-6)

    @Test func severalWorkspacesDroppedAtTheEndOfAGroupLandThereInAFlatWindowAndInANestedOne() {
        // Flat: X[x: w4] | w2 | w5, all of w2, w4 and w5 selected, w5 dropped at the end of X.
        var lab = Labels()
        let flat = world(
            [lab.ws("x", in: "X"), lab.ws("w4", in: "X"), lab.ws("w2"), lab.ws("w5")],
            [lab.group("X", own: "x")]
        )
        #expect(flat.compact(lab) == "X[x: w4] | w2 | w5")
        // Tabs without the three movers: x. The end of X is index 1.
        #expect(flat.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("w4"), lab.id("w2"), lab.id("w5")], draggedTabId: lab.id("w5"), toIndex: 1,
            isDragOperation: true, explicitGroupId: lab.id("X")
        ))
        #expect(flat.compact(lab) == "X[x: w4, w2, w5]")
        // Nested: G[g: X[x: w4], w2] | w5 lands the same way inside X.
        var lab2 = Labels()
        let nested = world(
            [lab2.ws("g", in: "G"), lab2.ws("x", in: "X"), lab2.ws("w4", in: "X"), lab2.ws("w2", in: "G"), lab2.ws("w5")],
            [lab2.group("G", own: "g"), lab2.group("X", parent: "G", own: "x")]
        )
        #expect(nested.compact(lab2) == "G[g: X[x: w4], w2] | w5")
        #expect(nested.reorder.reorderSidebarWorkspaces(
            tabIds: [lab2.id("w4"), lab2.id("w2"), lab2.id("w5")], draggedTabId: lab2.id("w5"), toIndex: 2,
            isDragOperation: true, explicitGroupId: lab2.id("X")
        ))
        #expect(nested.compact(lab2) == "G[g: X[x: w4, w2, w5]]")
        #expect(nested.violations(lab2).isEmpty)
        #expect(nested.host.orderChanges.last == [lab2.id("w4"), lab2.id("w2"), lab2.id("w5")])
    }

    @Test func severalNestedHeadersOfOneParentMoveWithTheOtherSelectedRowTakenOut() {
        var lab = Labels()
        let w = world(
            [lab.ws("p", in: "P"), lab.ws("q", in: "Q"), lab.ws("qa", in: "Q"), lab.ws("pa", in: "P"), lab.ws("r", in: "R"),
             lab.ws("ra", in: "R"), lab.ws("pb", in: "P")],
            [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q"), lab.group("R", parent: "P", own: "r")]
        )
        #expect(w.compact(lab) == "P[p: Q[q: qa], pa, R[r: ra], pb]")
        // Q and R, grabbed R, to the end of P: the tabs without both stretches are p, pa, pb; the end is 3.
        #expect(w.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("q"), lab.id("r")], draggedTabId: lab.id("r"), toIndex: 3, isDragOperation: true,
            explicitGroupId: lab.id("P")
        ))
        #expect(w.compact(lab) == "P[p: pa, pb, Q[q: qa], R[r: ra]]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: A selection of both pin tiers (CTRL-11)

    @Test func aSelectionOfBothPinTiersLandsEachRowInItsOwnTier() {
        var lab = Labels()
        let w = world(
            [lab.ws("a", in: "A"), lab.ws("a1", in: "A", pinned: true), lab.ws("L"), lab.ws("g", in: "G"), lab.ws("x", in: "X"),
             lab.ws("x1", in: "X"), lab.ws("m1", in: "G"), lab.ws("m2", in: "G")],
            [lab.group("A", own: "a"), lab.group("G", own: "g"), lab.group("X", parent: "G", own: "x")]
        )
        #expect(w.compact(lab) == "A[a: a1*] | L | G[g: X[x: x1], m1, m2]")
        // L is grabbed and dropped between m1 and m2. Without a1 and L the tabs are a, g, x, x1, m1, m2: the place is 5.
        #expect(w.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("a1"), lab.id("L")], draggedTabId: lab.id("L"), toIndex: 5, isDragOperation: true,
            explicitGroupId: lab.id("G")
        ))
        // The pinned row goes to G's pinned rows, the unpinned one stays at the place of the line.
        #expect(w.compact(lab) == "A[a] | G[g: a1*, X[x: x1], m1, L, m2]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: A block at a top-level place (CTRL-4, CTRL-8)

    @Test func severalWorkspacesDroppedAtATopLevelPlaceAllGoToTheTopLevel() {
        var lab = Labels()
        func fresh() -> NestedWorld {
            lab = Labels()
            return world(
                [lab.ws("w10"), lab.ws("g", in: "G"), lab.ws("x", in: "X"), lab.ws("w6", in: "X"), lab.ws("w2", in: "G"),
                 lab.ws("w9"), lab.ws("w8")],
                [lab.group("G", own: "g"), lab.group("X", parent: "G", own: "x")]
            )
        }
        let top = fresh()
        #expect(top.compact(lab) == "w10 | G[g: X[x: w6], w2] | w9 | w8")
        // w2, w6 and w8 selected, w8 grabbed, dropped before G: the top-level rows without w8 are w10, G, w9.
        #expect(top.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("w6"), lab.id("w2"), lab.id("w8")], draggedTabId: lab.id("w8"), toIndex: 1,
            isDragOperation: true, usesTopLevelRows: true
        ))
        #expect(top.compact(lab) == "w10 | w6 | w2 | w8 | G[g: X[x]] | w9")
        #expect(top.violations(lab).isEmpty)
        // The same place said as an index into the tabs (a plan among loose rows): w10, g, x, w6, w2, w9: index 1 is G.
        let raw = fresh()
        #expect(raw.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("w6"), lab.id("w2"), lab.id("w8")], draggedTabId: lab.id("w8"), toIndex: 1, isDragOperation: true
        ))
        #expect(raw.compact(lab) == "w10 | w6 | w2 | w8 | G[g: X[x]] | w9")
    }

    @Test func severalWorkspacesDroppedAtTheEndOfTheSidebarAllGoToTheTopLevelWhicheverRowSpaceTheIndexIsIn() {
        // The SwiftUI blank area under the list plans with the older planner: for a loose workspace an index into the tabs
        // (`usesTopLevelRows` false), else into the top-level rows. Both name the end of the sidebar.
        var lab = Labels()
        func fresh() -> NestedWorld {
            lab = Labels()
            return world(
                [lab.ws("w10"), lab.ws("g", in: "G"), lab.ws("x", in: "X"), lab.ws("w6", in: "X"), lab.ws("w2", in: "G"),
                 lab.ws("w9"), lab.ws("w8")],
                [lab.group("G", own: "g"), lab.group("X", parent: "G", own: "x")]
            )
        }
        let raw = fresh()
        #expect(raw.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("w6"), lab.id("w2"), lab.id("w8")], draggedTabId: lab.id("w8"), toIndex: raw.model.tabs.count - 1,
            isDragOperation: true
        ))
        #expect(raw.compact(lab) == "w10 | G[g: X[x]] | w9 | w6 | w2 | w8")
        let top = fresh()
        #expect(top.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("w6"), lab.id("w2"), lab.id("w8")], draggedTabId: lab.id("w8"), toIndex: 3,
            isDragOperation: true, usesTopLevelRows: true
        ))
        #expect(top.compact(lab) == "w10 | G[g: X[x]] | w9 | w6 | w2 | w8")
        #expect(raw.violations(lab).isEmpty && top.violations(lab).isEmpty)
    }

    @Test func aBlockDroppedAboveATopLevelGroupWithNoWorkspaceOfItsOwnLandsThereNotAtTheEnd() {
        var lab = Labels()
        let w = world(
            [lab.ws("w4"), lab.ws("w1", in: "G1"), lab.ws("w2", in: "G1"), lab.ws("w3")],
            [lab.group("G0"), lab.group("G1", parent: "G0", own: "w1")]
        )
        #expect(w.compact(lab) == "w4 | G0[-: G1[w1: w2]] | w3")
        // w2, w3, w4 selected, w2 grabbed. The top-level rows without w2 are w4, G0, w3: before G0 is index 1.
        #expect(w.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("w4"), lab.id("w2"), lab.id("w3")], draggedTabId: lab.id("w2"), toIndex: 1,
            isDragOperation: true, usesTopLevelRows: true
        ))
        #expect(w.compact(lab) == "w4 | w2 | w3 | G0[-: G1[w1]]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: Drops that change nothing, and drops the commit refuses

    @Test func aDropThatChangesNothingSendsNoNotice() {
        var lab = Labels()
        let w = world(
            [lab.ws("p", in: "P"), lab.ws("pa", in: "P"), lab.ws("q", in: "Q"), lab.ws("qa", in: "Q"), lab.ws("pb", in: "P")],
            [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q")]
        )
        let before = w.host.orderChanges.count
        let compact = w.compact(lab)
        // pa where it stands (the place before q is index 1 once pa is out: p, q, qa, pb).
        #expect(w.reorder.reorderSidebarWorkspace(tabId: lab.id("pa"), toIndex: 1, isDragOperation: true, explicitGroupId: lab.id("P")))
        // Q where it stands.
        #expect(w.reorder.reorderSidebarWorkspace(tabId: lab.id("q"), toIndex: 2, isDragOperation: true, explicitGroupId: lab.id("P")))
        #expect(w.compact(lab) == compact)
        #expect(w.host.orderChanges.count == before, "a drop that changed nothing sent \(w.host.orderChanges.dropFirst(before))")
    }

    @Test func severalWorkspacesDroppedWhereTheyAlreadyStandAtTheTopLevelSendNoNotice() {
        var lab = Labels()
        let w = world(
            [lab.ws("w1"), lab.ws("w2"), lab.ws("g", in: "G"), lab.ws("x", in: "X")],
            [lab.group("G", own: "g"), lab.group("X", parent: "G", own: "x")]
        )
        #expect(w.compact(lab) == "w1 | w2 | G[g: X[x]]")
        let before = w.host.orderChanges.count
        // w1 and w2 selected, w2 grabbed, dropped before G: the top-level rows without w2 are w1, G, so before G is index 1.
        #expect(w.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("w1"), lab.id("w2")], draggedTabId: lab.id("w2"), toIndex: 1,
            isDragOperation: true, usesTopLevelRows: true
        ))
        #expect(w.compact(lab) == "w1 | w2 | G[g: X[x]]")
        #expect(w.host.orderChanges.count == before, "a drop that changed nothing sent \(w.host.orderChanges.dropFirst(before))")
    }

    @Test func aHeaderIsNeverLetIntoAnotherParent() {
        var lab = Labels()
        let w = world(
            [lab.ws("p", in: "P"), lab.ws("q", in: "Q"), lab.ws("qa", in: "Q"), lab.ws("s", in: "S"), lab.ws("sa", in: "S"),
             lab.ws("t", in: "T")],
            [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q"), lab.group("S", own: "s"),
             lab.group("T", parent: "S", own: "t")]
        )
        let before = w.compact(lab)
        // Q is in P; S is not its parent. The place is a boundary of S's rows, but Q does not sit in S.
        #expect(!w.reorder.reorderSidebarWorkspace(tabId: lab.id("q"), toIndex: 3, isDragOperation: true, explicitGroupId: lab.id("S")))
        #expect(!w.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("q"), lab.id("t")], draggedTabId: lab.id("q"), toIndex: 3, isDragOperation: true,
            explicitGroupId: lab.id("P")
        ))
        #expect(w.compact(lab) == before)
    }

    @Test func aWorkspacePlacedInsideAChildGroupsStretchIsRefused() {
        var lab = Labels()
        let w = world(
            [lab.ws("p", in: "P"), lab.ws("pa", in: "P"), lab.ws("q", in: "Q"), lab.ws("qa", in: "Q"), lab.ws("qb", in: "Q"),
             lab.ws("pb", in: "P"), lab.ws("L")],
            [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q")]
        )
        let before = w.compact(lab)
        // Without L the tabs are p, pa, q, qa, qb, pb: index 4 is between qa and qb, inside Q's stretch.
        #expect(!w.reorder.reorderSidebarWorkspace(tabId: lab.id("L"), toIndex: 4, isDragOperation: true, explicitGroupId: lab.id("P")))
        #expect(!w.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("L"), lab.id("pa")], draggedTabId: lab.id("L"), toIndex: 3, isDragOperation: true,
            explicitGroupId: lab.id("P")
        ))
        #expect(w.compact(lab) == before)
    }
}
