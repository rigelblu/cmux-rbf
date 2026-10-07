import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): `Move Group to`, the group coordinator's new function and the menu it offers.
@MainActor
struct WorkspaceGroupNestedMoveIntoTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup], selected: String? = nil) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups), selected: selected.map { lab.id($0) })
    }

    @Test
    func aGroupMovedIntoAnotherIsTheLastRowOfItsPinTierThere() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("x", in: "A"), lab.ws("p", in: "A", pinned: true), lab.ws("b", in: "B"), lab.ws("u")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b")]
        )
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), intoParent: lab.id("A")) == .moved)
        // B is unpinned: after A's pinned row and its unpinned workspace.
        #expect(w.compact(lab) == "A[a: p*, x, B[b]] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aPinnedGroupMovedIntoAnotherJoinsThePinnedRows() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("p", in: "A", pinned: true), lab.ws("x", in: "A"), lab.ws("b", in: "B")],
            groups: [lab.group("A", own: "a"), lab.group("B", pinned: true, own: "b")]
        )
        // B is pinned and sits first at the top level; into A it is the last of the pinned rows.
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), intoParent: lab.id("A")) == .moved)
        #expect(w.compact(lab) == "A[a: p*, B*[b], x]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aGroupMovedToTheTopLevelSitsDirectlyBelowTheRowItCameOutOf() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O"), lab.ws("g", in: "G"), lab.ws("c", in: "G"), lab.ws("u"), lab.ws("v")],
            groups: [lab.group("O", own: "o"), lab.group("G", parent: "O", own: "g")]
        )
        #expect(w.compact(lab) == "O[o: G[g: c]] | u | v")
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("G"), intoParent: nil) == .moved)
        #expect(w.compact(lab) == "O[o] | G[g: c] | u | v")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func anUnpinnedGroupLeavingAPinnedRowIsTheFirstOfTheUnpinnedRows() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O", pinned: true), lab.ws("g", in: "G"), lab.ws("u"), lab.ws("v")],
            groups: [lab.group("O", pinned: true, own: "o"), lab.group("G", parent: "O", own: "g")]
        )
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("G"), intoParent: nil) == .moved)
        #expect(w.compact(lab) == "O*[o] | G[g] | u | v")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aPinnedGroupMovedToTheTopLevelIsTheLastOfThePinnedRows() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("q", in: "Q", pinned: true), lab.ws("o", in: "O"), lab.ws("g", in: "G", pinned: true), lab.ws("u")],
            groups: [lab.group("Q", pinned: true, own: "q"), lab.group("O", own: "o"), lab.group("G", parent: "O", pinned: true, own: "g")]
        )
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("G"), intoParent: nil) == .moved)
        #expect(w.compact(lab) == "Q*[q] | G*[g] | O[o] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func theFirstMoveIntoAnotherGroupMakesTheWindowNestedFromAFlatOne() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("u")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b")]
        )
        #expect(!w.model.hasNestedWorkspaceGroup)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A"), intoParent: lab.id("B")) == .moved)
        #expect(w.model.hasNestedWorkspaceGroup)
        #expect(w.window.groups.first { $0.id == lab.id("A") }?.parentId == lab.id("B"))
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aMoveThatIsRefusedOrChangesNothingChangesNothingAndSendsNoNotice() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("c", in: "C"), lab.ws("d", in: "D"), lab.ws("u")],
            groups: [lab.group("A", own: "a"), lab.group("C", parent: "A", own: "c"), lab.group("D", parent: "C", own: "d")]
        )
        let before = w.window
        let notices = w.host.orderChanges.count
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A"), intoParent: lab.id("A")) == .destinationIsSelfOrInside)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A"), intoParent: lab.id("D")) == .destinationIsSelfOrInside)
        #expect(w.groups.moveWorkspaceGroup(groupId: UUID(), intoParent: nil) == .groupNotFound)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("C"), intoParent: UUID()) == .destinationNotFound)
        // Already there: C sits in A, A sits at the top level.
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("C"), intoParent: lab.id("A")) == .unchanged)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A"), intoParent: nil) == .unchanged)
        #expect(w.window == before)
        #expect(w.host.orderChanges.count == notices)
    }

    @Test
    func aMoveSendsTheOrderChangeNoticeWithEveryWorkspaceInsideTheMovedGroup() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C"), lab.ws("u")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b"), lab.group("C", parent: "B", own: "c")]
        )
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), intoParent: lab.id("A")) == .moved)
        #expect(Set(w.host.orderChanges.last ?? []) == [lab.id("b"), lab.id("c")])
    }

    @Test
    func theDestinationOpensOnlyWhenTheMovedGroupHoldsTheSelectedWorkspace() {
        var lab = Labels()
        let holds = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("x", in: "B"), lab.ws("u")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b")],
            selected: "x"
        )
        holds.model.workspaceGroups[0].isCollapsed = true
        #expect(holds.groups.moveWorkspaceGroup(groupId: lab.id("B"), intoParent: lab.id("A")) == .moved)
        #expect(holds.model.workspaceGroups[0].isCollapsed == false)

        var lab2 = Labels()
        let elsewhere = world(
            &lab2,
            tabs: [lab2.ws("a", in: "A"), lab2.ws("b", in: "B"), lab2.ws("u")],
            groups: [lab2.group("A", own: "a"), lab2.group("B", own: "b")],
            selected: "u"
        )
        elsewhere.model.workspaceGroups[0].isCollapsed = true
        #expect(elsewhere.groups.moveWorkspaceGroup(groupId: lab2.id("B"), intoParent: lab2.id("A")) == .moved)
        #expect(elsewhere.model.workspaceGroups[0].isCollapsed == true)
    }

    @Test
    func aMoveDoesNotReopenAFoldedHeaderOnlyParentThatHoldsTheSelectionWhenTheMovedGroupDoesNot() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("c", in: "C"), lab.ws("b", in: "B"), lab.ws("u")],
            // A has no workspace of its own and holds C, where the selection is; it is folded and stays folded.
            groups: [lab.group("A", pinned: true), lab.group("C", parent: "A", own: "c"), lab.group("B", own: "b")],
            selected: "c"
        )
        w.model.workspaceGroups[0].isCollapsed = true
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), intoParent: lab.id("A")) == .moved)
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("A") }?.isCollapsed == true)
    }

    @Test
    func aGroupThatHoldsNothingCanBeMovedIntoAnotherAndStaysListedThere() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("x", in: "A"), lab.ws("u")],
            groups: [lab.group("A", own: "a"), lab.group("E", pinned: true)]
        )
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("E"), intoParent: lab.id("A")) == .moved)
        #expect(w.window.groups.first { $0.id == lab.id("E") }?.parentId == lab.id("A"))
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func theMenuOffersTopLevelAndEveryGroupExceptTheGroupAndTheOnesInsideItWithTheirDepth() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C"), lab.ws("d", in: "D"), lab.ws("e", in: "E")],
            groups: [lab.group("A", own: "a"), lab.group("B", parent: "A", own: "b"), lab.group("C", parent: "B", own: "c"), lab.group("D", parent: "B", own: "d"), lab.group("E", own: "e")]
        )
        let menu = try! #require(w.groups.moveMenu(for: lab.id("B")))
        #expect(!menu.topLevelIsCurrent)
        // B, C and D are left out; A is B's current place.
        #expect(menu.destinations.map { lab.name($0.id) } == ["A", "E"])
        #expect(menu.destinations.map(\.depth) == [0, 0])
        #expect(menu.destinations.map(\.isCurrent) == [true, false])
        let deeper = try! #require(w.groups.moveMenu(for: lab.id("E")))
        #expect(deeper.topLevelIsCurrent)
        #expect(deeper.destinations.map { lab.name($0.id) } == ["A", "B", "C", "D"])
        #expect(deeper.destinations.map(\.depth) == [0, 1, 2, 2])
        #expect(deeper.destinations.allSatisfy { !$0.isCurrent })
        #expect(w.groups.moveMenu(for: UUID()) == nil)
    }

    @Test
    func withNoOtherGroupTheOnlyPlaceOfferedIsTheTopLevel() {
        var lab = Labels()
        let w = world(&lab, tabs: [lab.ws("a", in: "A"), lab.ws("u")], groups: [lab.group("A", own: "a")])
        let menu = try! #require(w.groups.moveMenu(for: lab.id("A")))
        #expect(menu.topLevelIsCurrent)
        #expect(menu.destinations.isEmpty)
    }
}
