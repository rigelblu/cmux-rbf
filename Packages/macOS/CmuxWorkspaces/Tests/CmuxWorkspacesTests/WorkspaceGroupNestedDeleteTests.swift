import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): Delete Group and the reorder among the groups beside, nested.
@MainActor
struct WorkspaceGroupNestedDeleteTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup]) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups))
    }

    private func areaWindow(_ lab: inout Labels) -> (tabs: [NestWorkspace], groups: [NestGroup]) {
        (
            [lab.ws("p", in: "P"), lab.ws("x", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("d", in: "D"), lab.ws("u")],
            [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("D", parent: "C", own: "d")]
        )
    }

    // MARK: - The confirmation

    @Test
    func theConfirmationCountsEveryWorkspaceThatClosesAndEveryGroupInside() {
        var lab = Labels()
        let (tabs, groups) = areaWindow(&lab)
        let w = world(&lab, tabs: tabs, groups: groups)
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(confirmation.memberWorkspaceIds.map { lab.name($0) } == ["p", "x", "c", "y", "d"])
        #expect(confirmation.containedGroupIds == [lab.id("C"), lab.id("D")])
        #expect(confirmation.memberCount == 5)
        #expect(confirmation.containedWorkspaceCount == 4)
        #expect(confirmation.containedGroupCount == 2)
        let leaf = try! #require(w.groups.deletionConfirmation(groupId: lab.id("D")))
        #expect(leaf.containedGroupCount == 0 && leaf.memberCount == 1)
    }

    // MARK: - Delete

    @Test
    func deletingAParentClosesEveryWorkspaceInsideInnermostFirstAndRemovesTheGroupsInside() {
        var lab = Labels()
        let (tabs, groups) = areaWindow(&lab)
        let w = world(&lab, tabs: tabs, groups: groups)
        let closed = w.groups.deleteWorkspaceGroup(groupId: lab.id("P"))
        #expect(closed == 5)
        // Innermost group first; in each group its own workspace after its others; the deleted group's own last.
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["d", "y", "c", "x", "p"])
        #expect(w.window.groups.isEmpty)
        #expect(w.window.tabs.map { lab.name($0.id) } == ["u"])
    }

    @Test
    func aWorkspaceThatJoinedWhileTheQuestionWasOpenIsNotClosedAndGoesUpToTheGroupThatHeldTheDeletedOne() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O"), lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("n"), lab.ws("u")],
            groups: [lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(confirmation.memberWorkspaceIds.map { lab.name($0) } == ["p", "c"])
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("n"), groupId: lab.id("C"))
        let closed = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(closed == 2)
        #expect(w.compact(lab) == "O[o: n] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aWorkspaceMovedOutWhileTheQuestionWasOpenIsLeftAlone() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("z", in: "Z"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("Z", own: "z")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("y"), groupId: lab.id("Z"))
        let closed = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(closed == 2)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["c", "p"])
        #expect(w.compact(lab) == "Z[z: y] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func ifTheGroupIsGoneWhenDeleteIsPressedNothingCloses() {
        var lab = Labels()
        let (tabs, groups) = areaWindow(&lab)
        let w = world(&lab, tabs: tabs, groups: groups)
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("P"))
        let before = w.compact(lab)
        let orderChanges = w.host.orderChanges.count
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 0)
        #expect(w.host.closedWorkspaceIds.isEmpty)
        #expect(w.host.orderChanges.count == orderChanges)
        #expect(w.compact(lab) == before)
    }

    @Test
    func deletingEveryWorkspaceOfAWindowMakesAReplacementFirst() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        let closed = w.groups.deleteWorkspaceGroup(groupId: lab.id("P"))
        #expect(closed == 2)
        #expect(w.window.groups.isEmpty)
        #expect(w.window.tabs.count == 1)
        #expect(!w.window.tabs.contains { $0.id == lab.id("p") || $0.id == lab.id("c") })
    }

    @Test
    func deletingAParentAlsoRemovesAnEmptyPinnedHeaderInsideIt() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("E", parent: "P", pinned: true)]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(confirmation.containedGroupCount == 1 && confirmation.memberCount == 1)
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 1)
        #expect(w.window.groups.isEmpty)
    }

    // MARK: - Reorder among the groups beside

    private func siblingsWorld(_ lab: inout Labels) -> NestedWorld {
        world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c1", in: "C1"), lab.ws("c2", in: "C2"), lab.ws("c3", in: "C3"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C1", parent: "P", own: "c1"), lab.group("C2", parent: "P", own: "c2"), lab.group("C3", parent: "P", own: "c3")]
        )
    }

    @Test
    func aGroupIsMovedAmongTheGroupsBesideItByTheListIndexOfItsTarget() {
        var lab = Labels()
        let w = siblingsWorld(&lab)
        w.groups.moveWorkspaceGroup(groupId: lab.id("C3"), toIndex: 1)
        #expect(w.compact(lab) == "P[p: C3[c3], C1[c1], C2[c2]] | u")
        w.groups.moveWorkspaceGroup(groupId: lab.id("C3"), toIndex: 99)
        #expect(w.compact(lab) == "P[p: C1[c1], C2[c2], C3[c3]] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aTargetInAnotherParentChangesNothing() {
        var lab = Labels()
        let w = siblingsWorld(&lab)
        let before = w.compact(lab)
        w.groups.moveWorkspaceGroup(groupId: lab.id("C3"), toIndex: 0)
        #expect(w.compact(lab) == before)
    }

    @Test
    func aTopLevelGroupMovesAmongTheTopLevelGroupsInANestedWindow() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("c", in: "C"), lab.ws("b", in: "B")],
            groups: [lab.group("A", own: "a"), lab.group("C", parent: "A", own: "c"), lab.group("B", own: "b")]
        )
        w.groups.moveWorkspaceGroup(groupId: lab.id("B"), toIndex: 0)
        #expect(w.compact(lab) == "B[b] | A[a: C[c]]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - More cases

    @Test
    func aGroupThatJoinedAfterTheConfirmationIsNotDeletedAndGoesToTheGroupThatHeldTheDeletedOne() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("c", in: "C"), lab.ws("l", in: "L"), lab.ws("m", in: "L"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("L", own: "l")]
        )
        #expect(w.compact(lab) == "P[p: a, C[c]] | L[l: m] | u")
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        // L is moved into P while the question is open.
        w.model.workspaceGroups[2].parentGroupId = lab.id("P")
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(w.compact(lab) == "P[p: a, C[c], L[l: m]] | u")
        let closed = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(closed == 3)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["c", "a", "p"])
        #expect(w.compact(lab) == "L[l: m] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aGroupThatJoinedInsideAConfirmedChildGoesUpToTheGroupThatHeldTheDeletedOne() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O"), lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("l", in: "L"), lab.ws("u")],
            groups: [lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("L", own: "l")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.model.workspaceGroups[3].parentGroupId = lab.id("C")
        w.model.normalizeWorkspaceGroupContiguity()
        _ = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(w.compact(lab) == "O[o: L[l]] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aGroupIndexPastEitherEndIsTheNearestSlotAmongTheGroupsBesideItNotARefusal() {
        var lab = Labels()
        let top = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b"), lab.group("C", parent: "B", own: "c")]
        )
        top.groups.moveWorkspaceGroup(groupId: lab.id("A"), toIndex: 3)
        #expect(top.compact(lab) == "B[b: C[c]] | A[a]")
        top.groups.moveWorkspaceGroup(groupId: lab.id("A"), toIndex: -1)
        #expect(top.compact(lab) == "A[a] | B[b: C[c]]")
        top.groups.moveWorkspaceGroup(groupId: lab.id("A"), toIndex: 99)
        #expect(top.compact(lab) == "B[b: C[c]] | A[a]")

        var lab2 = Labels()
        let inner = world(
            &lab2,
            tabs: [lab2.ws("p", in: "P"), lab2.ws("x", in: "X"), lab2.ws("y", in: "Y")],
            groups: [lab2.group("P", own: "p"), lab2.group("X", parent: "P", own: "x"), lab2.group("Y", parent: "P", own: "y")]
        )
        inner.groups.moveWorkspaceGroup(groupId: lab2.id("Y"), toIndex: -1)
        #expect(inner.compact(lab2) == "P[p: Y[y], X[x]]")
        #expect(inner.violations(lab2).isEmpty)
    }

    // MARK: - The notice names what changed place

    @Test
    func theNoticeNamesTheClosedWorkspacesAndEveryWorkspaceThatJoinedMeanwhileAndWentUp() {
        // `n` joins a group inside the deleted one while the question is open, at two depths; it goes up to `O`.
        for (name, joinedGroup, extra) in [("a child of the deleted group", "C", false), ("three levels down", "S", true)] {
            var lab = Labels()
            var tabs = [lab.ws("o", in: "O"), lab.ws("p", in: "P"), lab.ws("c", in: "C")]
            var groups = [lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p"), lab.group("C", parent: "P", own: "c")]
            if extra {
                tabs.append(lab.ws("s", in: "S"))
                groups.append(lab.group("S", parent: "C", own: "s"))
            }
            tabs += [lab.ws("n"), lab.ws("u")]
            let w = world(&lab, tabs: tabs, groups: groups)
            let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
            let notices = w.host.orderChanges.count
            w.groups.addWorkspaceToGroup(workspaceId: lab.id("n"), groupId: lab.id(joinedGroup))
            let afterJoin = w.host.orderChanges.count
            let closed = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
            #expect(closed == confirmation.memberWorkspaceIds.count, "\(name)")
            #expect(w.compact(lab) == "O[o: n] | u", "\(name): \(w.compact(lab))")
            #expect(w.host.orderChanges.count == afterJoin + 1, "\(name): one notice for the delete (\(notices))")
            let expected = Set(confirmation.memberWorkspaceIds.map { lab.name($0) } + ["n"])
            #expect(Set((w.host.orderChanges.last ?? []).map { lab.name($0) }) == expected, "\(name): names \((w.host.orderChanges.last ?? []).map { lab.name($0) })")
        }
    }

    @Test
    func theNoticeNamesNothingExtraWhenNothingJoinedMeanwhile() {
        var lab = Labels()
        let (tabs, groups) = areaWindow(&lab)
        let w = world(&lab, tabs: tabs, groups: groups)
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        let before = w.host.orderChanges.count
        _ = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(w.host.orderChanges.count == before + 1)
        #expect(w.host.orderChanges.last == confirmation.memberWorkspaceIds)
    }

    @Test
    func theNoticeNamesTheWorkspacesWhosePlaceChangedWhenAGroupJoinedMeanwhileAndWentUp() {
        // From a window at rest, `L*[l: m] | O[o: ox, P[p: C[c]]] | u`: a pinned group `L` is moved into `P` with
        // `Move Group to` while the question is open. When `P` goes, `L` takes the pinned place in `O`, in front of
        // `ox`, which did not move by itself but changed place.
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("l", in: "L"), lab.ws("m", in: "L"), lab.ws("o", in: "O"), lab.ws("ox", in: "O"), lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("u")],
            groups: [lab.group("L", pinned: true, own: "l"), lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        #expect(w.violations(lab).isEmpty, "the window is at rest")
        #expect(w.compact(lab) == "L*[l: m] | O[o: ox, P[p: C[c]]] | u")
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("L"), intoParent: lab.id("P")) == .moved)
        let before = w.host.orderChanges.count
        _ = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(w.compact(lab) == "O[o: L*[l: m], ox] | u")
        #expect(w.host.orderChanges.count == before + 1)
        #expect(Set((w.host.orderChanges.last ?? []).map { lab.name($0) }) == ["p", "c", "l", "m", "ox"])
        #expect(w.violations(lab).isEmpty)
    }
}
