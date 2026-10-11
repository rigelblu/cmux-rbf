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
    /// workspaces, the six group rules, and, for a group with nothing but its own workspace, that group as the last
    /// row (the end of the pinned tier, where the same call puts it when an unpinned row stands below).
    private func check(
        mover: String,
        moverGroup: String,
        targets: [Int],
        endsLast: Bool = true,
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
            if endsLast, before.count > 1 {
                #expect(w.model.tabs.last?.groupId == lab.id(moverGroup), "\(mover) to \(target): \(w.compact(lab))")
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
        check(mover: "a1", moverGroup: "G1", targets: [0, 1, 2, 3, 4, 99], endsLast: false, build: build)
        check(mover: "a2", moverGroup: "G2", targets: [0, 1, 2, 3, 4, 99], endsLast: false, build: build)
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
