import Foundation
import Testing
@testable import CmuxWorkspaces

// Move Workspace Up / Down on the workspace behind a pinned group's name, in a window where every row is pinned or
// inside a pinned group. The planned index used to land one past the end of the list after the row was taken out.
@MainActor
struct WorkspaceGroupPinnedHeaderMoveTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup]) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups))
    }

    /// Moves `mover` to each of `targets` in a fresh window and checks what must hold after every call: the same
    /// workspaces, the six group rules, and, for a group with nothing but its own workspace, that group's row at the
    /// target, brought into the pinned tier (every row is pinned here, so the tier is the whole list).
    ///
    /// cmux-rbf: changed on purpose (#cm-142.1): this used to expect that group as the last row. That was a side effect
    /// of the fork's crash fix (#cm-113, 4744a759dc), which only capped the index and whose commit leaves "the mismatch
    /// between the two pin tests" as it was, so Move Up could send the header down. Upstream fixed the same crash at its
    /// cause (c895b03af7, #13688 for #13417): a pinned group's anchor is tiered by its group's pin, so the move lands
    /// where asked, and the iOS move policy predicts the same. The no-crash, same-workspaces and rule checks stay.
    private func check(
        mover: String,
        moverGroup: String,
        targets: [Int],
        landsAtTarget: Bool = true, // cmux-rbf (#cm-142.1): was `endsLast`
        build: (inout Labels) -> NestedWorld
    ) {
        for target in targets {
            var lab = Labels()
            let w = build(&lab)
            let before = Set(w.model.tabs.map(\.id))
            #expect(w.reorder.reorderWorkspace(tabId: lab.id(mover), toIndex: target), "\(mover) to \(target)")
            #expect(Set(w.model.tabs.map(\.id)) == before, "\(mover) to \(target): same workspaces")
            #expect(w.model.tabs.count == before.count, "\(mover) to \(target): none lost or doubled")
            #expect(w.violations(lab).isEmpty, "\(mover) to \(target): \(w.violations(lab))")
            if landsAtTarget, before.count > 1 { // cmux-rbf: changed on purpose (#cm-142.1): lands at the target within the pinned tier
                let rows = w.model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
                let expected = max(0, min(target, rows.count - 1))
                #expect(rows.firstIndex(of: lab.id(mover)) == expected, "\(mover) to \(target): \(w.compact(lab))")
            }
        }
    }

    @Test
    func aPinnedGroupWithOnlyItsOwnWorkspaceBesideAPinnedWorkspaceMovesWithoutCrashing() {
        check(mover: "a", moverGroup: "G", targets: [0, 1, 2, 99]) { lab in
            world(&lab, tabs: [lab.ws("a", in: "G"), lab.ws("p", pinned: true)], groups: [lab.group("G", pinned: true, own: "a")])
        }
        check(mover: "a", moverGroup: "G", targets: [0, 1, 2, 99]) { lab in
            world(&lab, tabs: [lab.ws("p", pinned: true), lab.ws("a", in: "G")], groups: [lab.group("G", pinned: true, own: "a")])
        }
    }

    // A control: a window with one row returns before the clamp, so this passes without the guard too.
    @Test
    func theOnlyWorkspaceOfTheWindowStaysWhereItIs() {
        check(mover: "a", moverGroup: "G", targets: [0, 1, 99]) { lab in
            world(&lab, tabs: [lab.ws("a", in: "G")], groups: [lab.group("G", pinned: true, own: "a")])
        }
    }

    @Test
    func twoPinnedGroupsAndAPinnedWorkspaceMoveEachGroupsOwnWorkspaceWithoutCrashing() {
        func build(_ lab: inout Labels) -> NestedWorld {
            world(
                &lab,
                tabs: [lab.ws("a1", in: "G1"), lab.ws("a2", in: "G2"), lab.ws("p", pinned: true)],
                groups: [lab.group("G1", pinned: true, own: "a1"), lab.group("G2", pinned: true, own: "a2")]
            )
        }
        check(mover: "a1", moverGroup: "G1", targets: [0, 1, 2, 3, 99], build: build)
        check(mover: "a2", moverGroup: "G2", targets: [0, 1, 2, 3, 99], build: build)
    }

    @Test
    func pinnedGroupsThatHoldOtherWorkspacesMoveWithoutCrashing() {
        func build(_ lab: inout Labels) -> NestedWorld {
            world(
                &lab,
                tabs: [lab.ws("a1", in: "G1"), lab.ws("m1", in: "G1"), lab.ws("a2", in: "G2"), lab.ws("m2", in: "G2"), lab.ws("p", pinned: true)],
                groups: [lab.group("G1", pinned: true, own: "a1"), lab.group("G2", pinned: true, own: "a2")]
            )
        }
        check(mover: "a1", moverGroup: "G1", targets: [0, 1, 2, 3, 4, 99], landsAtTarget: false, build: build)
        check(mover: "a2", moverGroup: "G2", targets: [0, 1, 2, 3, 4, 99], landsAtTarget: false, build: build)
    }

    // A control: with a nested group these moves step by level and never reach the clamp, so this passes without the guard too.
    @Test
    func aWindowThatAlsoHoldsANestedGroupMovesWithoutCrashing() {
        func build(_ lab: inout Labels) -> NestedWorld {
            world(
                &lab,
                tabs: [lab.ws("a", in: "G"), lab.ws("h", in: "H"), lab.ws("x", in: "G"), lab.ws("p", pinned: true)],
                groups: [lab.group("G", pinned: true, own: "a"), lab.group("H", parent: "G", own: "h")]
            )
        }
        for target in [0, 1, 2, 3, 99] {
            var lab = Labels()
            let w = build(&lab)
            #expect(w.model.hasNestedWorkspaceGroup)
            let before = Set(w.model.tabs.map(\.id))
            #expect(w.reorder.reorderWorkspace(tabId: lab.id("a"), toIndex: target), "a to \(target)")
            #expect(Set(w.model.tabs.map(\.id)) == before, "a to \(target): same workspaces")
            #expect(w.violations(lab).isEmpty, "a to \(target): \(w.violations(lab))")
        }
    }
}
