import Foundation
import Testing
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): the four entrances of Grill Me Q40 and the router's refusal.
@MainActor
struct WorkspaceGroupNestedEntranceTests {
    /// `u1 | A[a: x, B[b: y, z]] | u2`, with optional pins.
    private func world(
        _ lab: inout Labels,
        pinned: Set<String> = [],
        groupsPinned: Set<String> = []
    ) -> NestedWorld {
        let tabs = [
            lab.ws("u1", pinned: pinned.contains("u1")),
            lab.ws("a", in: "A"),
            lab.ws("x", in: "A", pinned: pinned.contains("x")),
            lab.ws("b", in: "B"),
            lab.ws("y", in: "B", pinned: pinned.contains("y")),
            lab.ws("z", in: "B", pinned: pinned.contains("z")),
            lab.ws("u2", pinned: pinned.contains("u2"))
        ]
        let groups = [
            lab.group("A", pinned: groupsPinned.contains("A"), own: "a"),
            lab.group("B", parent: "A", pinned: groupsPinned.contains("B"), own: "b")
        ]
        var window = NestWindow(tabs: tabs, groups: groups)
        window.bareRepair()
        return NestedWorld(window)
    }

    // MARK: - Move to Top

    @Test
    func moveToTopTakesEachRowOnTheWayUpToTheTopOfItsTier() {
        var lab = Labels()
        let w = world(&lab)
        #expect(w.compact(lab) == "u1 | A[a: x, B[b: y, z]] | u2")
        w.reorder.moveTabsToTop([lab.id("z")])
        #expect(w.compact(lab) == "A[a: B[b: z, y], x] | u1 | u2")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func moveToTopOnAGroupsOwnWorkspaceTakesItsGroupToTheTopOfItsLevelsAllTheWayUp() {
        var lab = Labels()
        let w = world(&lab)
        w.reorder.moveTabsToTop([lab.id("b")])
        #expect(w.compact(lab) == "A[a: B[b: y, z], x] | u1 | u2")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func moveToTopStopsAtThePinnedTiersOfEveryLevel() {
        var lab = Labels()
        let w = world(&lab, pinned: ["x", "u1"])
        #expect(w.compact(lab) == "u1* | A[a: x*, B[b: y, z]] | u2")
        w.reorder.moveTabsToTop([lab.id("u2")])
        #expect(w.compact(lab) == "u1* | u2 | A[a: x*, B[b: y, z]]")
        w.reorder.moveTabsToTop([lab.id("z")])
        // B goes to the top of the unpinned rows of A, behind the pinned x; A to the top of the unpinned rows.
        #expect(w.compact(lab) == "u1* | A[a: x*, B[b: z, y]] | u2")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func moveToTopOnAnUngroupedWorkspaceAndOnSeveralKeepsTheirOrder() {
        var lab = Labels()
        let w = world(&lab)
        w.reorder.moveTabsToTop([lab.id("u2")])
        #expect(w.compact(lab) == "u2 | u1 | A[a: x, B[b: y, z]]")
        w.reorder.moveTabsToTop([lab.id("u1"), lab.id("y")])
        // Both go to the top, in the order they stand in the window: u1 before y's group A.
        #expect(w.compact(lab) == "u1 | A[a: B[b: y, z], x] | u2")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - The notification move

    @Test
    func theNotificationMoveWalksFromTheTopLevelInwardToTheFirstUnpinnedPlaces() {
        var lab = Labels()
        let w = world(&lab, pinned: ["u1"])
        w.reorder.moveTabToTopForNotification(lab.id("z"))
        #expect(w.compact(lab) == "u1* | A[a: B[b: z, y], x] | u2")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func theNotificationMoveMovesNothingAtOrInsideAPinnedGroup() {
        var lab = Labels()
        let pinnedOuter = world(&lab, groupsPinned: ["A"])
        let before = pinnedOuter.compact(lab)
        pinnedOuter.reorder.moveTabToTopForNotification(lab.id("z"))
        #expect(pinnedOuter.compact(lab) == before)

        // A pinned inner group: the outer group moves, the walk stops at the pinned one.
        var lab2 = Labels()
        let pinnedInner = world(&lab2, groupsPinned: ["B"])
        #expect(pinnedInner.compact(lab2) == "u1 | A[a: B*[b: y, z], x] | u2")
        pinnedInner.reorder.moveTabToTopForNotification(lab2.id("z"))
        #expect(pinnedInner.compact(lab2) == "A[a: B*[b: y, z], x] | u1 | u2")
        #expect(pinnedInner.violations(lab2).isEmpty)
    }

    @Test
    func aPinnedMemberOfUnpinnedGroupsStillMovesAndAnUngroupedPinnedWorkspaceDoesNot() {
        var lab = Labels()
        let w = world(&lab, pinned: ["y", "z", "u1", "u2"])
        #expect(w.compact(lab) == "u1* | u2* | A[a: x, B[b: y*, z*]]")
        w.reorder.moveTabToTopForNotification(lab.id("z"))
        #expect(w.compact(lab) == "u1* | u2* | A[a: B[b: z*, y*], x]")
        w.reorder.moveTabToTopForNotification(lab.id("u2"))
        #expect(w.compact(lab) == "u1* | u2* | A[a: B[b: z*, y*], x]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - Move Up and Move Down

    private func step(_ w: NestedWorld, _ id: UUID, by offset: Int) -> Bool {
        let index = w.model.tabs.firstIndex { $0.id == id }!
        return w.reorder.reorderWorkspace(tabId: id, toIndex: index + offset)
    }

    @Test
    func oneStepIsOneRowAmongTheRowsOfTheWorkspacesLevelAChildGroupCountingAsOneRow() {
        var lab = Labels()
        let w = world(&lab)
        #expect(step(w, lab.id("x"), by: 1))
        #expect(w.compact(lab) == "u1 | A[a: B[b: y, z], x] | u2")
        #expect(step(w, lab.id("x"), by: -1))
        #expect(w.compact(lab) == "u1 | A[a: x, B[b: y, z]] | u2")
        #expect(step(w, lab.id("y"), by: 1))
        #expect(w.compact(lab) == "u1 | A[a: x, B[b: z, y]] | u2")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aGroupsOwnWorkspaceMovesItsGroupsRow() {
        var lab = Labels()
        let w = world(&lab)
        #expect(step(w, lab.id("b"), by: -1))
        #expect(w.compact(lab) == "u1 | A[a: B[b: y, z], x] | u2")
        #expect(step(w, lab.id("a"), by: 1))
        #expect(w.compact(lab) == "u1 | u2 | A[a: B[b: y, z], x]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aStepAtTheEdgeOfALevelOrAcrossThePinnedTierChangesNothing() {
        var lab = Labels()
        let w = world(&lab, pinned: ["u1"])
        let before = w.compact(lab)
        #expect(step(w, lab.id("z"), by: 1))
        #expect(w.compact(lab) == before)
        #expect(step(w, lab.id("u2"), by: -1))
        // u2 is unpinned: up one row it would cross A, which is an unpinned row, so it moves above A.
        #expect(w.compact(lab) == "u1* | u2 | A[a: x, B[b: y, z]]")
        #expect(step(w, lab.id("u2"), by: -1))
        #expect(w.compact(lab) == "u1* | u2 | A[a: x, B[b: y, z]]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func anIndexFromTheSocketIsBroughtToTheNearestPlaceInTheWorkspacesOwnLevel() {
        var lab = Labels()
        let w = world(&lab)
        // z asks for the top of the window: the nearest place inside its group B is first.
        #expect(w.reorder.reorderWorkspace(tabId: lab.id("z"), toIndex: 0))
        #expect(w.compact(lab) == "u1 | A[a: x, B[b: z, y]] | u2")
        // x asks for the last tab: the nearest place among A's rows is after B.
        #expect(w.reorder.reorderWorkspace(tabId: lab.id("x"), toIndex: 99))
        #expect(w.compact(lab) == "u1 | A[a: B[b: z, y], x] | u2")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - The router

    @Test
    func theRouterMovesANestedGroupsHeaderInsideItsParentAndNowhereElse() {
        var lab = Labels()
        let w = world(&lab)
        let before = w.compact(lab)
        // A top-level plan, or a plan that names no parent, is not a place for a nested header.
        #expect(!w.reorder.reorderSidebarWorkspace(tabId: lab.id("b"), toIndex: 0, isDragOperation: true, usesTopLevelRows: true))
        #expect(!w.reorder.reorderSidebarWorkspace(tabId: lab.id("b"), toIndex: 0, isDragOperation: true))
        // A group that does not hold it, or a place that is not a boundary between two of its rows.
        #expect(!w.reorder.reorderSidebarWorkspace(tabId: lab.id("b"), toIndex: 0, isDragOperation: true, explicitGroupId: lab.id("B")))
        #expect(!w.reorder.reorderSidebarWorkspace(tabId: lab.id("b"), toIndex: 4, isDragOperation: true, explicitGroupId: lab.id("A")))
        #expect(w.compact(lab) == before)
        // Inside A: above x (index 2 once B's stretch is out). Tabs: u1 0, a 1, x 2, b 3, y 4, z 5, u2 6.
        #expect(w.reorder.reorderSidebarWorkspace(tabId: lab.id("b"), toIndex: 2, isDragOperation: true, explicitGroupId: lab.id("A")))
        #expect(w.compact(lab) == "u1 | A[a: B[b: y, z], x] | u2")
        #expect(w.host.orderChanges.last == [lab.id("b"), lab.id("y"), lab.id("z")])
        // The same place again moves nothing, and is not a refusal.
        let count = w.host.orderChanges.count
        #expect(w.reorder.reorderSidebarWorkspace(tabId: lab.id("b"), toIndex: 2, isDragOperation: true, explicitGroupId: lab.id("A")))
        #expect(w.host.orderChanges.count == count)
        #expect(w.violations(lab).isEmpty)
        // A top-level header is not refused.
        #expect(w.reorder.reorderSidebarWorkspace(tabId: lab.id("a"), toIndex: 2, isDragOperation: true, usesTopLevelRows: true))
        #expect(w.compact(lab) == "u1 | u2 | A[a: B[b: y, z], x]")
    }

    @Test
    func aBlockOfHeadersMovesOnlyWhenEveryHeaderSitsInTheSameParent() {
        var lab = Labels()
        let tabs = [
            lab.ws("p", in: "P"), lab.ws("pa", in: "P"), lab.ws("q", in: "Q"), lab.ws("qa", in: "Q"),
            lab.ws("r", in: "R"), lab.ws("ra", in: "R"), lab.ws("pb", in: "P"), lab.ws("u")
        ]
        let groups = [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q"), lab.group("R", parent: "P", own: "r")]
        var window = NestWindow(tabs: tabs, groups: groups)
        window.bareRepair()
        let w = NestedWorld(window)
        #expect(w.compact(lab) == "P[p: pa, Q[q: qa], R[r: ra], pb] | u")
        // Q and R together, below pb: tabs without both stretches: p 0, pa 1, pb 2, u 3; place 3.
        #expect(w.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("q"), lab.id("r")], draggedTabId: lab.id("q"), toIndex: 3, isDragOperation: true, explicitGroupId: lab.id("P")
        ))
        #expect(w.compact(lab) == "P[p: pa, pb, Q[q: qa], R[r: ra]] | u")
        #expect(w.host.orderChanges.last == [lab.id("q"), lab.id("qa"), lab.id("r"), lab.id("ra")])
        #expect(w.violations(lab).isEmpty)
        // A top-level header taken with a nested one: refused, nothing moves.
        let before = w.compact(lab)
        #expect(!w.reorder.reorderSidebarWorkspaces(
            tabIds: [lab.id("p"), lab.id("q")], draggedTabId: lab.id("q"), toIndex: 0, isDragOperation: true, explicitGroupId: lab.id("P")
        ))
        #expect(w.compact(lab) == before)
    }

    // MARK: - A flat window gets what upstream gives

    @Test
    func theNestedEntrancesOnAFlatWindowDoWhatUpstreamsDo() {
        var comparisons = [String: Int]()
        var changes = [String: Int]()
        var differences = 0
        func note(_ name: String, changed: Bool, same: Bool, _ detail: @autoclosure () -> String) {
            comparisons[name, default: 0] += 1
            if changed { changes[name, default: 0] += 1 }
            if !same {
                differences += 1
                Issue.record("\(name): \(detail())")
            }
        }
        // After an edit the layout lists the groups with no workspace inside by rule 4 (WorkspaceGroupLayout.swift, "The six rules"), where upstream's
        // step leaves the list as it was; the rows and the groups' facts must agree.
        func ignoringGroupListOrder(_ window: NestWindow) -> NestWindow {
            var copy = window
            copy.groups.sort { $0.id.uuidString < $1.id.uuidString }
            return copy
        }
        for index in 0..<250 {
            let seed = UInt64(96_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            let window = upstreamNormalized(randomFlatWindow(&rng))
            guard window.tabs.count >= 2 else { continue }
            for tab in window.tabs { lab.name(tab.id, as: "w\(lab.nameById.count)") }
            for g in window.groups { lab.name(g.id, as: "G\(lab.nameById.count)") }
            let detail = "seed \(seed): \(stored(window, lab))"

            // Move to Top, one or several
            do {
                let chosen = window.tabs.filter { _ in Bool.random(using: &rng) }.map(\.id)
                if !chosen.isEmpty {
                    let a = NestedWorld(window), b = NestedWorld(window)
                    a.reorder.moveTabsToTop(Set(chosen))
                    b.model.nestedMoveTabsToTop(b.model.tabs.filter { chosen.contains($0.id) })
                    note("move to top", changed: a.window != window, same: a.window == b.window, "\(detail) \(chosen.map { lab.name($0) }) -> \(stored(a.window, lab)) vs \(stored(b.window, lab))")
                }
            }
            // The notification move
            do {
                let id = window.tabs.randomElement(using: &rng)!.id
                let a = NestedWorld(window), b = NestedWorld(window)
                a.reorder.moveTabToTopForNotification(id)
                b.model.nestedMoveTabToTopForNotification(b.model.tabs.first { $0.id == id }!)
                note("notification", changed: a.window != window, same: a.window == b.window, "\(detail) \(lab.name(id)) -> \(stored(a.window, lab)) vs \(stored(b.window, lab))")
            }
            // One step up or down, where upstream's step is one row: an ungrouped workspace past an ungrouped one,
            // or a member past a member of its own tier in its group. (At a group's edge upstream undoes the
            // step or jumps a whole group; the nested step is one row, by design.)
            do {
                let tabs = window.tabs
                let candidates = tabs.indices.filter { i in
                    [-1, 1].contains { offset in
                        let j = i + offset
                        guard tabs.indices.contains(j) else { return false }
                        let t = tabs[i], n = tabs[j]
                        if t.groupId == nil && n.groupId == nil && !window.isAnchor(n.id) { return t.isPinned == n.isPinned }
                        if let g = t.groupId, n.groupId == g, !window.isAnchor(t.id), !window.isAnchor(n.id) { return t.isPinned == n.isPinned }
                        return false
                    }
                }
                if let i = candidates.randomElement(using: &rng) {
                    let offsets = [-1, 1].filter { offset in
                        let j = i + offset
                        guard tabs.indices.contains(j) else { return false }
                        let t = tabs[i], n = tabs[j]
                        if t.groupId == nil && n.groupId == nil && !window.isAnchor(n.id) { return t.isPinned == n.isPinned }
                        if let g = t.groupId, n.groupId == g, !window.isAnchor(t.id), !window.isAnchor(n.id) { return t.isPinned == n.isPinned }
                        return false
                    }
                    let offset = offsets.randomElement(using: &rng)!
                    let a = NestedWorld(window), b = NestedWorld(window)
                    let ra = a.reorder.reorderWorkspace(tabId: tabs[i].id, toIndex: i + offset)
                    let rb = b.model.nestedReorderWorkspace(tabId: tabs[i].id, toIndex: i + offset)
                    note("step", changed: a.window != window, same: ra == rb && ignoringGroupListOrder(a.window) == ignoringGroupListOrder(b.window), "\(detail) \(lab.name(tabs[i].id)) by \(offset) -> \(stored(a.window, lab)) vs \(stored(b.window, lab))")
                }
            }
        }
        for name in comparisons.keys.sorted() {
            print("theNestedEntrancesOnAFlatWindow: \(name): \(comparisons[name] ?? 0) comparisons, \(changes[name] ?? 0) in which the window changed")
            #expect((comparisons[name] ?? 0) > 0, "no comparison for \(name)")
            #expect((changes[name] ?? 0) > 0, "nothing ever changed for \(name)")
        }
        #expect(comparisons.count == 3, "entrances compared: \(comparisons.keys.sorted())")
        #expect(differences == 0)
    }

    // MARK: - More cases

    @Test
    func aDragThatInfersMembershipEndsInTheRepairInANestedWindow() {
        var lab = Labels()
        let w = NestedWorld(NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("x")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        ))
        #expect(w.compact(lab) == "P[p: C[c]] | x")
        // x is dropped between p and c: its neighbours are in different groups, so it stays ungrouped.
        #expect(w.reorder.reorderSidebarWorkspace(tabId: lab.id("x"), toIndex: 1, isDragOperation: true))
        #expect(w.compact(lab) == "P[p: C[c]] | x")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func unpinningSeveralWorkspacesTogetherEndsInTheNestedRepair() {
        var lab = Labels()
        let w = NestedWorld(NestWindow(
            tabs: [lab.ws("w0", pinned: true), lab.ws("w1", pinned: true), lab.ws("w3", in: "G"), lab.ws("w2", in: "G"), lab.ws("q", in: "Q"), lab.ws("r", in: "R")],
            groups: [lab.group("G", pinned: true, own: "w3"), lab.group("Q", own: "q"), lab.group("R", parent: "Q", own: "r")]
        ))
        #expect(w.compact(lab) == "w0* | w1* | G*[w3: w2] | Q[q: R[r]]")
        w.reorder.setPinned(workspaceIds: [lab.id("w0"), lab.id("w1")], pinned: false)
        #expect(w.compact(lab) == "G*[w3: w2] | w1 | w0 | Q[q: R[r]]")
        #expect(w.violations(lab).isEmpty)
    }
}
