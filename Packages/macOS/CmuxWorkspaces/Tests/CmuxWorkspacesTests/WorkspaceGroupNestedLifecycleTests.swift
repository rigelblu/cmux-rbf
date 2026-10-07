import Foundation
import Testing
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): close, window move and pin in a window that holds a nested group.
@MainActor
struct WorkspaceGroupNestedLifecycleTests {
    private func close(_ world: NestedWorld, _ id: UUID) {
        world.model.tabs.removeAll { $0.id == id }
        world.model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: id)
    }

    private func moveToAnotherWindow(_ world: NestedWorld, _ id: UUID) {
        world.model.tabs.removeAll { $0.id == id }
        world.model.dissolveGroupsAnchoredBy(closedWorkspaceId: id)
    }

    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup]) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups))
    }

    // MARK: - Close

    @Test
    func closingTheWorkspaceBehindANamePassesTheNameOnAndKeepsTheChildGroups() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("x", in: "P"), lab.ws("z", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("d", in: "D")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("D", parent: "C", own: "d")]
        )
        #expect(w.compact(lab) == "P[p: x, z, C[c: y, D[d]]]")
        close(w, lab.id("p"))
        // The earliest remaining workspace of P itself takes the name; the child groups stay.
        #expect(w.compact(lab) == "P[x: z, C[c: y, D[d]]]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func closingTheLastOwnWorkspaceOfAGroupThatHoldsGroupsLeavesItsHeader() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        close(w, lab.id("p"))
        #expect(w.compact(lab) == "P[-: C[c]]")
        #expect(w.window.groups.first { $0.id == lab.id("P") }?.anchorWorkspaceId == nil)
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func closingTheLastWorkspaceOfAnUnpinnedLeafGroupRemovesOnlyThatGroup() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        close(w, lab.id("c"))
        #expect(w.compact(lab) == "P[p]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func closingTheLastWorkspaceOfAPinnedLeafGroupKeepsItAsAnEmptyHeaderInsideItsParent() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", pinned: true, own: "c")]
        )
        close(w, lab.id("c"))
        #expect(w.compact(lab) == "P[p: C*[-]]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aCloseInAFlatGroupBesideANestedOneIsStillToday() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "A"), lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        close(w, lab.id("a"))
        #expect(w.compact(lab) == "A[b] | P[p: C[c]]")
        close(w, lab.id("b"))
        #expect(w.compact(lab) == "P[p: C[c]]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - Move to another window

    @Test
    func aDissolvedGroupsWorkspacesTakeItsParentNotNil() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        moveToAnotherWindow(w, lab.id("c"))
        #expect(w.compact(lab) == "P[p: y]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aGroupThatHoldsGroupsKeepsItsHeaderWhenItsWorkspaceMovesToAnotherWindow() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        moveToAnotherWindow(w, lab.id("p"))
        #expect(w.compact(lab) == "P[-: C[c]]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aGroupThatHoldsGroupsPassesItsNameOnWhenItsWorkspaceMovesToAnotherWindow() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("x", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        moveToAnotherWindow(w, lab.id("p"))
        #expect(w.compact(lab) == "P[x: C[c]]")
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("P") }?.anchorWorkspaceProvenance == .user)
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aTopLevelGroupDissolvedByAWindowMoveStillFreesItsWorkspacesToTheTopLevel() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "A"), lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        moveToAnotherWindow(w, lab.id("a"))
        #expect(w.compact(lab) == "b | P[p: C[c]]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - Pin

    @Test
    func pinningAndUnpinningAGroupInsideAParentLandsLastOfThePinnedRowsAndFirstOfTheUnpinnedOnes() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c1", in: "C1"), lab.ws("c2", in: "C2"), lab.ws("c3", in: "C3")],
            groups: [lab.group("P", own: "p"), lab.group("C1", parent: "P", own: "c1"), lab.group("C2", parent: "P", own: "c2"), lab.group("C3", parent: "P", own: "c3")]
        )
        #expect(w.compact(lab) == "P[p: C1[c1], C2[c2], C3[c3]]")
        w.groups.setWorkspaceGroupPinned(groupId: lab.id("C2"), isPinned: true)
        #expect(w.compact(lab) == "P[p: C2*[c2], C1[c1], C3[c3]]")
        w.groups.setWorkspaceGroupPinned(groupId: lab.id("C3"), isPinned: true)
        #expect(w.compact(lab) == "P[p: C2*[c2], C3*[c3], C1[c1]]")
        w.groups.setWorkspaceGroupPinned(groupId: lab.id("C2"), isPinned: false)
        #expect(w.compact(lab) == "P[p: C3*[c3], C2[c2], C1[c1]]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func pinningAParentPinsItsWholeRunAtTheTopLevel() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("w"), lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        w.groups.setWorkspaceGroupPinned(groupId: lab.id("P"), isPinned: true)
        #expect(w.compact(lab) == "P*[p: C[c]] | w")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func pinningWorkspacesInANestedWindowKeepsEveryTierLegal() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("w1", in: "A"), lab.ws("w2", in: "A"), lab.ws("c", in: "C"), lab.ws("u1"), lab.ws("u2")],
            groups: [lab.group("A", own: "a"), lab.group("C", parent: "A", own: "c")]
        )
        w.reorder.togglePin(tabId: lab.id("w2"))
        #expect(w.compact(lab) == "A[a: w2*, w1, C[c]] | u1 | u2")
        w.reorder.togglePin(tabId: lab.id("u2"))
        #expect(w.compact(lab) == "u2* | A[a: w2*, w1, C[c]] | u1")
        #expect(w.violations(lab).isEmpty)
    }
}
