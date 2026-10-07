import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): the five gaps the reviewer's random driver found, the two guards nothing reached, and the
// proof that upstream's assignment and placement, which run after the in-place placement, change nothing.
@MainActor
struct WorkspaceGroupNestedGapTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup], selected: String? = nil) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups), selected: selected.map { lab.id($0) })
    }

    // MARK: - A new group made in place

    @Test
    func theChosenWorkspacesKeepSidebarOrderInsideTheNewGroupWhateverOrderTheyAreGiven() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("b", in: "G"), lab.ws("c", in: "G"), lab.ws("d", in: "G")],
            groups: [lab.group("G", own: "g")]
        )
        let id = w.groups.createWorkspaceGroup(name: "N", childWorkspaceIds: [lab.id("d"), lab.id("b"), lab.id("c")], collapseSidebarSelection: false)
        lab.name(id!, as: "N")
        // The new group's own workspace stands behind its name; b, c and d follow in sidebar order.
        let rows = w.window.tabs.filter { $0.groupId == id }.map { lab.name($0.id) }
        #expect(rows.suffix(3) == ["b", "c", "d"])
        #expect(w.compact(lab).contains("b, c, d"))
    }

    @Test
    func aPinnedAndAnUnpinnedChosenWorkspaceKeepTheirTiersInTheNewGroup() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("p", in: "G", pinned: true), lab.ws("b", in: "G")],
            groups: [lab.group("G", own: "g")]
        )
        let id = w.groups.createWorkspaceGroup(name: "N", childWorkspaceIds: [lab.id("b"), lab.id("p")], collapseSidebarSelection: false)
        lab.name(id!, as: "N")
        let rows = w.window.tabs.filter { $0.groupId == id }.map { lab.name($0.id) }
        #expect(rows.suffix(2) == ["p", "b"])
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aNewGroupMadeInPlaceDoesNotReopenAFoldedGroupWhenItsOwnWorkspaceIsNotSelected() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("b", in: "G"), lab.ws("u")],
            groups: [lab.group("G", own: "g")],
            selected: "u"
        )
        w.model.workspaceGroups[0].isCollapsed = true
        _ = w.groups.createWorkspaceGroup(name: "N", childWorkspaceIds: [lab.id("a")], selectAnchor: false, collapseSidebarSelection: false)
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("G") }?.isCollapsed == true)
    }

    @Test
    func aNewGroupMadeInPlaceElsewhereDoesNotReopenAFoldedHeaderOnlyParentThatHoldsTheSelection() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("x", in: "X"), lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("b", in: "G")],
            // F has no workspace of its own and holds X, where the selection is; it is folded and stays folded.
            groups: [lab.group("F", pinned: true), lab.group("X", parent: "F", own: "x"), lab.group("G", own: "g")],
            selected: "x"
        )
        w.model.workspaceGroups[0].isCollapsed = true
        _ = w.groups.createWorkspaceGroup(name: "N", childWorkspaceIds: [lab.id("a")], selectAnchor: false, collapseSidebarSelection: false)
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("F") }?.isCollapsed == true)
    }

    @Test
    func aStaleGroupIdOnTheFirstChosenWorkspaceMeansNoGroupAndTheInPlaceVersionStandsDown() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("s"), lab.ws("u")],
            groups: [lab.group("A", own: "a"), lab.group("N", own: nil)]
        )
        // s names a group that does not exist.
        w.model.tabs.first { $0.id == lab.id("s") }!.groupId = UUID()
        let before = w.window
        #expect(!w.groups.nestedPlaceNewWorkspaceGroup(groupId: lab.id("N"), anchorId: lab.id("u"), eligibleChildren: [lab.id("s")]))
        #expect(w.window == before)
    }

    // MARK: - Move Group to

    @Test
    func aGroupMovedToTheTopLevelFromTwoLevelsDownLandsDirectlyBelowTheTopLevelRowItCameOutOf() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O"), lab.ws("p", in: "P"), lab.ws("g", in: "G"), lab.ws("u"), lab.ws("v")],
            groups: [lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p"), lab.group("G", parent: "P", own: "g")]
        )
        #expect(w.compact(lab) == "O[o: P[p: G[g]]] | u | v")
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("G"), intoParent: nil) == .moved)
        #expect(w.compact(lab) == "O[o: P[p]] | G[g] | u | v")
    }

    @Test
    func theDestinationOpensWhenTheSelectionIsInAGroupInsideTheMovedGroup() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("q", in: "Q"), lab.ws("x", in: "Q"), lab.ws("u")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b"), lab.group("Q", parent: "B", own: "q")],
            selected: "x"
        )
        w.model.workspaceGroups[0].isCollapsed = true
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), intoParent: lab.id("A")) == .moved)
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("A") }?.isCollapsed == false)
    }

    // MARK: - The walk

    @Test
    func aWorkspaceThatNamesAGroupThatIsGoneIsListedForNoGroup() {
        var lab = Labels()
        let gone = UUID()
        let items = [
            WorkspaceGroupWorkspaceItem(id: lab.id("a"), groupId: lab.id("G"), isPinned: false),
            WorkspaceGroupWorkspaceItem(id: lab.id("s"), groupId: gone, isPinned: false)
        ]
        let group = WorkspaceGroup(id: lab.id("G"), name: "G", isCollapsed: false, isPinned: false, anchor: .workspace(lab.id("a")), customColor: nil, iconSymbol: nil)
        let inside = WorkspaceGroupRowWalk.workspaceIdsInside(groups: [group], workspaces: items)
        #expect(inside[gone] == nil)
        #expect(inside[lab.id("G")] == [lab.id("a")])
    }

    // MARK: - Upstream's assignment and placement change nothing after the in-place placement

    @Test
    func aGroupMadeInPlaceChangesNothingBesideTheMoveOfItsWorkspaces() {
        var inPlace = 0
        var checked = 0
        for index in 0..<300 {
            let seed = UInt64(77_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            var start = randomNestedWindow(&rng, &lab)
            start.bareRepair()
            let candidates = start.tabs.filter { !start.isAnchor($0.id) }
            guard !candidates.isEmpty else { continue }
            let chosen = candidates.filter { _ in Bool.random(using: &rng) }
            guard !chosen.isEmpty, let first = start.tabs.first(where: { t in chosen.contains { $0.id == t.id } }) else { continue }
            let chosenIds = Set(chosen.map(\.id))
            let w = NestedWorld(start, selected: start.tabs.randomElement(using: &rng)?.id)
            let created = w.groups.createWorkspaceGroup(name: "Made", childWorkspaceIds: chosen.map(\.id), collapseSidebarSelection: false)
            guard let created else { continue }
            checked += 1
            let after = w.window
            #expect(nestViolations(after, lab).isEmpty, "seed \(seed)")
            // Every chosen workspace is inside the new group.
            #expect(after.tabs.filter { chosenIds.contains($0.id) }.allSatisfy { $0.groupId == created }, "seed \(seed)")
            guard first.groupId != nil, start.groups.contains(where: { $0.id == first.groupId }) else { continue }
            inPlace += 1
            #expect(after.groups.first { $0.id == created }?.parentId == first.groupId, "seed \(seed): lands in the first one's group")
            // Take the new group, its own workspace and the chosen workspaces out of both: the order of the rest of the
            // workspaces, where each sits, and every other group's parent and pin are what they were.
            let dropped = chosenIds.union(after.groups.first { $0.id == created }?.anchorWorkspaceId.map { [$0] } ?? [])
            func tabsLeft(_ window: NestWindow, _ dropped: Set<UUID>) -> [String] {
                window.tabs.filter { !dropped.contains($0.id) }.map { "\($0.id) in \($0.groupId?.uuidString ?? "top")" }
            }
            func groupsLeft(_ window: NestWindow, except new: UUID?) -> Set<String> {
                Set(window.groups.filter { $0.id != new }.map { "\($0.id) in \($0.parentId?.uuidString ?? "top") pinned \($0.isPinned)" })
            }
            #expect(tabsLeft(start, chosenIds) == tabsLeft(after, dropped), "seed \(seed): the rest of the workspaces")
            #expect(groupsLeft(start, except: nil) == groupsLeft(after, except: created), "seed \(seed): the other groups")
        }
        print("aGroupMadeInPlaceChangesNothingBesideTheMove: \(checked) windows, \(inPlace) made in place")
        #expect(inPlace >= 100, "windows where the first chosen workspace sat in a group: \(inPlace)")
    }
}
