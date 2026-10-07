import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): Ungroup, Delete Group, fold, add, remove and new workspace in a
// window that holds a nested group.
@MainActor
struct WorkspaceGroupNestedOperationsTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup], selected: String? = nil) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups), selected: selected.map { lab.id($0) })
    }

    // MARK: - Ungroup

    @Test
    func ungroupingANestedGroupMovesItsRowsUpToTheParentInOrder() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("e", in: "E")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("E", parent: "C", own: "e")]
        )
        #expect(w.compact(lab) == "P[p: C[c: y, E[e]]]")
        let result = w.groups.ungroupWorkspaceGroup(groupId: lab.id("C"))
        #expect(result == .dissolved(keptWorkspaceCount: 2))
        // c and y become P's rows where C stood; E, which sat inside C, now sits inside P.
        #expect(w.compact(lab) == "P[p: c, y, E[e]]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func ungroupingATopLevelGroupFreesItsRowsAndLeavesItsChildGroupsAtTheTopLevel() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("x", in: "G"), lab.ws("d", in: "D"), lab.ws("u")],
            groups: [lab.group("G", own: "g"), lab.group("D", parent: "G", own: "d")]
        )
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("G"))
        #expect(w.compact(lab) == "g | x | D[d] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func ungroupingAPinnedGroupPutsItsRowsBehindThePinnedRowsOfTheLevelAbove() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("g", in: "G"), lab.ws("x", in: "G"), lab.ws("h", in: "H"), lab.ws("u", in: "P")],
            groups: [lab.group("P", own: "p"), lab.group("G", parent: "P", pinned: true, own: "g"), lab.group("H", parent: "P", pinned: true, own: "h")]
        )
        #expect(w.compact(lab) == "P[p: G*[g: x], H*[h], u]")
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("G"))
        #expect(w.compact(lab) == "P[p: H*[h], g, x, u]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func anEmptyPinnedGroupCannotBeUngroupedButAPinnedParentHoldingGroupsCan() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("c", in: "C"), lab.ws("u")],
            groups: [lab.group("P", pinned: true), lab.group("C", parent: "P", own: "c"), lab.group("Z", pinned: true)]
        )
        #expect(w.groups.ungroupWorkspaceGroup(groupId: lab.id("Z")) == .emptyPinnedCannotUngroup)
        #expect(w.groups.ungroupWorkspaceGroup(groupId: lab.id("P")) == .dissolved(keptWorkspaceCount: 0))
        #expect(w.window.groups.map { lab.name($0.id) }.contains("P") == false)
        #expect(w.window.groups.first { $0.id == lab.id("C") }?.parentId == nil)
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func removingTheGeneratedWorkspaceOfAGroupThatHoldsGroupsIsRefusedAndClosesNothing() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        w.model.workspaceGroups[0].anchorWorkspaceProvenance = .generated
        let before = w.compact(lab)
        let result = w.groups.ungroupWorkspaceGroup(groupId: lab.id("P"), removeGeneratedAnchor: true)
        #expect(result == .generatedAnchorRequiresAnchorOnly(memberWorkspaceCount: 0))
        #expect(w.host.closedWorkspaceIds.isEmpty)
        #expect(w.compact(lab) == before)
    }

    // A parent with no workspace of its own that receives workspaces takes the first as the one behind its name.
    private func pinnedHeaderOnlyParent(_ lab: inout Labels) -> NestedWorld {
        world(
            &lab,
            tabs: [lab.ws("w2", in: "C"), lab.ws("w4")],
            groups: [lab.group("P", pinned: true), lab.group("C", parent: "P", own: "w2")]
        )
    }

    @Test
    func ungroupingTheOnlyChildOfAHeaderOnlyParentGivesTheParentItsFirstWorkspaceAsItsName() {
        var lab = Labels()
        let w = pinnedHeaderOnlyParent(&lab)
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("C"))
        #expect(w.compact(lab) == "P*[w2] | w4")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func deletingTheOnlyChildOfAHeaderOnlyParentWhileAWorkspaceJoinedGivesTheParentThatWorkspaceAsItsName() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("w2", in: "C"), lab.ws("n"), lab.ws("w4")],
            groups: [lab.group("P", pinned: true), lab.group("C", parent: "P", own: "w2")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("C")))
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("n"), groupId: lab.id("C"))
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 1)
        #expect(w.compact(lab) == "P*[n] | w4")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aDissolvedChildGroupsWorkspacesGiveAHeaderOnlyParentItsFirstWorkspaceAsItsName() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("w2", in: "C"), lab.ws("y", in: "C"), lab.ws("w4")],
            groups: [lab.group("P", pinned: true), lab.group("C", parent: "P", own: "w2")]
        )
        w.model.tabs.removeAll { $0.id == lab.id("w2") }
        w.model.dissolveGroupsAnchoredBy(closedWorkspaceId: lab.id("w2"))
        #expect(w.compact(lab) == "P*[y] | w4")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - Fold

    @Test
    func foldingAParentHidesEverythingInsideAndMovesTheSelectionToItsOwnWorkspace() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")],
            selected: "y"
        )
        w.host.sidebarSelectedWorkspaceIds = [lab.id("y"), lab.id("u")]
        w.groups.toggleWorkspaceGroupCollapsed(groupId: lab.id("P"))
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("P") }?.isCollapsed == true)
        #expect(w.model.selectedTabId == lab.id("p"))
        #expect(w.host.subtractedSidebarSelections.last?.hidden == [lab.id("c"), lab.id("y")])
        #expect(w.host.sidebarSelectedWorkspaceIds == [lab.id("u")])
    }

    @Test
    func foldingAParentWithNoWorkspaceOfItsOwnStillDropsHiddenRowsFromTheMultiSelectionAndKeepsTheSelection() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("u")],
            groups: [lab.group("P"), lab.group("C", parent: "P", own: "c")],
            selected: "y"
        )
        w.host.sidebarSelectedWorkspaceIds = [lab.id("y"), lab.id("u")]
        w.groups.toggleWorkspaceGroupCollapsed(groupId: lab.id("P"))
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("P") }?.isCollapsed == true)
        #expect(w.model.selectedTabId == lab.id("y"))
        #expect(w.host.selectedWorkspaceIds.isEmpty)
        #expect(w.host.sidebarSelectedWorkspaceIds == [lab.id("u")])
    }

    // MARK: - Add, remove, new

    private func landingWindow(_ lab: inout Labels) -> [NestWorkspace] {
        [lab.ws("m", pinned: true), lab.ws("p", in: "P"), lab.ws("b", in: "P", pinned: true), lab.ws("a", in: "P"), lab.ws("c", in: "C"), lab.ws("n")]
    }

    @Test
    func aWorkspaceAddedToAGroupLandsAfterTheGroupsLastOwnWorkspaceOfItsTier() {
        var lab = Labels()
        let tabs = landingWindow(&lab)
        let w = world(&lab, tabs: tabs, groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")])
        #expect(w.compact(lab) == "m* | P[p: b*, a, C[c]] | n")
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("n"), groupId: lab.id("P"))
        #expect(w.compact(lab) == "m* | P[p: b*, a, n, C[c]]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aPinnedWorkspaceAddedFromBelowLandsAfterTheGroupsLastPinnedWorkspaceAndBeforeItsPinnedGroups() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("b", in: "P", pinned: true), lab.ws("c", in: "C"), lab.ws("a", in: "P"), lab.ws("m", pinned: true)],
            groups: [lab.group("P", pinned: true, own: "p"), lab.group("C", parent: "P", pinned: true, own: "c")]
        )
        #expect(w.compact(lab) == "P*[p: b*, C*[c], a] | m*")
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("m"), groupId: lab.id("P"))
        #expect(w.compact(lab) == "P*[p: b*, m*, C*[c], a]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func withNoPlaceNamedAWorkspaceLandsFirstFromAboveTheGroupAndLastFromBelow() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("x"), lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("b", in: "G"), lab.ws("y"), lab.ws("p", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("G", own: "g"), lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        #expect(w.compact(lab) == "x | G[g: a, b] | y | P[p: C[c]]")
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("x"), groupId: lab.id("G"))
        #expect(w.compact(lab) == "G[g: x, a, b] | y | P[p: C[c]]")
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("y"), groupId: lab.id("G"))
        #expect(w.compact(lab) == "G[g: x, a, b, y] | P[p: C[c]]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aWorkspaceAddedToAHeaderWithNoWorkspaceBecomesTheOneBehindItsNameAndAnAnchorIsNotAdded() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("c", in: "C"), lab.ws("n"), lab.ws("q", in: "Q")],
            groups: [lab.group("P"), lab.group("C", parent: "P", own: "c"), lab.group("Q", own: "q")]
        )
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("n"), groupId: lab.id("P"))
        #expect(w.window.groups.first { $0.id == lab.id("P") }?.anchorWorkspaceId == lab.id("n"))
        #expect(w.compact(lab) == "P[n: C[c]] | Q[q]")
        // q stands behind Q's name: it cannot be added to another group.
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("q"), groupId: lab.id("P"))
        #expect(w.compact(lab) == "P[n: C[c]] | Q[q]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func anExplicitPlacementPutsTheWorkspaceFirstLastOrBelowTheReference() {
        func landing(_ placement: WorkspaceGroupNewPlacement, reference: String? = nil) -> String {
            var lab = Labels()
            let w = world(
                &lab,
                tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("b", in: "P"), lab.ws("c", in: "C"), lab.ws("n")],
                groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
            )
            w.groups.addWorkspaceToGroup(
                workspaceId: lab.id("n"),
                groupId: lab.id("P"),
                placement: placement,
                referenceWorkspaceId: reference.map { lab.id($0) }
            )
            return w.compact(lab)
        }
        #expect(landing(.top) == "P[p: n, a, b, C[c]]")
        #expect(landing(.end) == "P[p: a, b, n, C[c]]")
        #expect(landing(.afterCurrent, reference: "a") == "P[p: a, n, b, C[c]]")
    }

    @Test
    func aWorkspaceRemovedFromANestedGroupComesOutDirectlyBelowThatGroup() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("z", in: "C"), lab.ws("t", in: "P")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        #expect(w.compact(lab) == "P[p: C[c: y, z], t]")
        w.groups.removeWorkspaceFromGroup(workspaceId: lab.id("y"))
        #expect(w.compact(lab) == "P[p: C[c: z], y, t]")
        // The workspace behind a name leaving means the group is ungrouped.
        w.groups.removeWorkspaceFromGroup(workspaceId: lab.id("c"))
        #expect(w.compact(lab) == "P[p: c, z, y, t]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func anUnpinnedWorkspaceRemovedFromAPinnedNestedGroupLandsFirstOfTheUnpinnedRows() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("t", in: "P")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", pinned: true, own: "c")]
        )
        #expect(w.compact(lab) == "P[p: C*[c: y], t]")
        w.groups.removeWorkspaceFromGroup(workspaceId: lab.id("y"))
        #expect(w.compact(lab) == "P[p: C*[c], y, t]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aNewWorkspaceInANestedGroupLandsByItsPlacementAndOpensTheGroupsAboveItWhenSelected() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("c", in: "C")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        for index in w.model.workspaceGroups.indices { w.model.workspaceGroups[index].isCollapsed = true }
        let created = w.groups.createWorkspaceInGroup(groupId: lab.id("C"), placement: .top, select: true)
        let id = try! #require(created).id
        lab.name(id, as: "new")
        #expect(w.compact(lab) == "P[p: a, C[c: new]]")
        #expect(w.model.workspaceGroups.map(\.isCollapsed) == [false, false])
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - A flat window gets what upstream gives

    @Test
    func theNestedOperationsOnAFlatWindowDoWhatUpstreamsDo() {
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
        func settled(_ world: NestedWorld) -> NestWindow {
            world.model.normalizeWorkspaceGroupContiguity()
            return world.window
        }
        // After an edit the layout lists the groups with no workspace inside by rule 4 (WorkspaceGroupLayout.swift, "The six rules"; the rows), where
        // upstream's functions leave the list as it was; the rows and the groups' facts must agree.
        func ignoringGroupListOrder(_ window: NestWindow) -> NestWindow {
            var copy = window
            copy.groups.sort { $0.id.uuidString < $1.id.uuidString }
            return copy
        }
        for index in 0..<200 {
            let seed = UInt64(95_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            let window = upstreamNormalized(randomFlatWindow(&rng))
            guard window.tabs.count >= 2, let group = window.groups.randomElement(using: &rng) else { continue }
            for tab in window.tabs { lab.name(tab.id, as: "w\(lab.nameById.count)") }
            for g in window.groups { lab.name(g.id, as: "G\(lab.nameById.count)") }
            let selected = window.tabs.randomElement(using: &rng)?.id
            let sidebar = Set(window.tabs.filter { _ in Bool.random(using: &rng) }.map(\.id))
            func make() -> NestedWorld {
                let w = NestedWorld(window, selected: selected)
                w.host.sidebarSelectedWorkspaceIds = sidebar
                return w
            }
            let detail = "seed \(seed): \(stored(window, lab))"

            // Ungroup
            do {
                let a = make(), b = make()
                let ra = a.groups.ungroupWorkspaceGroup(groupId: group.id)
                let rb = b.groups.nestedUngroupWorkspaceGroup(group: b.model.workspaceGroups.first { $0.id == group.id }!)
                let sa = settled(a), sb = settled(b)
                note("ungroup", changed: ra != .groupNotFound && sa != window, same: ra == rb && sa == sb, "\(detail) group \(lab.name(group.id)) -> \(ra) \(stored(sa, lab)) vs \(rb) \(stored(sb, lab))")
            }
            // Remove from group
            if let member = window.tabs.filter({ tab in tab.groupId != nil && !window.isAnchor(tab.id) }).randomElement(using: &rng) {
                let a = make(), b = make()
                a.groups.removeWorkspaceFromGroup(workspaceId: member.id)
                b.groups.nestedRemoveWorkspaceFromGroup(workspaceId: member.id, groupId: member.groupId!)
                let sa = settled(a), sb = settled(b)
                note("remove", changed: sa != window, same: ignoringGroupListOrder(sa) == ignoringGroupListOrder(sb), "\(detail) member \(lab.name(member.id)) -> \(stored(sa, lab)) vs \(stored(sb, lab))")
            }
            // Fold
            do {
                let a = make(), b = make()
                a.groups.toggleWorkspaceGroupCollapsed(groupId: group.id)
                b.groups.nestedToggleWorkspaceGroupCollapsed(groupId: group.id)
                let same = a.model.workspaceGroups.map(\.isCollapsed) == b.model.workspaceGroups.map(\.isCollapsed)
                    && a.model.selectedTabId == b.model.selectedTabId
                    && a.host.sidebarSelectedWorkspaceIds == b.host.sidebarSelectedWorkspaceIds
                    && a.host.subtractedSidebarSelections.map(\.hidden) == b.host.subtractedSidebarSelections.map(\.hidden)
                note("fold", changed: a.model.selectedTabId != selected || a.host.sidebarSelectedWorkspaceIds != sidebar, same: same, "\(detail) group \(lab.name(group.id))")
            }
            // Move a group by index
            do {
                let a = make(), b = make()
                let target = Int.random(in: -1...(window.groups.count + 1), using: &rng)
                a.groups.moveWorkspaceGroup(groupId: group.id, toIndex: target)
                b.groups.nestedMoveWorkspaceGroup(groupId: group.id, toIndex: target)
                note("move group", changed: a.window != window, same: a.window == b.window, "\(detail) group \(lab.name(group.id)) to \(target) -> \(stored(a.window, lab)) vs \(stored(b.window, lab))")
            }
            // The confirmation and the delete
            do {
                let a = make(), b = make()
                let ca = a.groups.deletionConfirmation(groupId: group.id)!
                let cb = b.groups.nestedDeletionConfirmation(group: b.model.workspaceGroups.first { $0.id == group.id }!)
                note("confirmation", changed: ca.memberCount > 0, same: ca.showsTheSameQuestion(as: cb) && cb.containedGroupIds.isEmpty, "\(detail)")
                let closedA = a.groups.deleteWorkspaceGroup(confirmed: ca)
                let closedB = b.groups.nestedDeleteWorkspaceGroup(confirmed: cb, recordHistory: true)
                let originalIds = Set(window.tabs.map(\.id))
                func remaining(_ w: NestedWorld) -> NestWindow {
                    var s = settled(w)
                    s.tabs = s.tabs.filter { originalIds.contains($0.id) }
                    return s
                }
                let ra = remaining(a), rb = remaining(b)
                note("delete", changed: closedA > 0, same: closedA == closedB && ra == rb && Set(a.host.closedWorkspaceIds) == Set(b.host.closedWorkspaceIds), "\(detail) group \(lab.name(group.id)) closed \(closedA)/\(closedB) -> \(stored(ra, lab)) vs \(stored(rb, lab))")
            }
            // Add with an explicit placement, and a new workspace in a group
            if let loose = window.tabs.filter({ $0.groupId == nil && !window.isAnchor($0.id) }).randomElement(using: &rng) {
                // nil too: no place named, where upstream lands the workspace by where it came from.
                let placement: WorkspaceGroupNewPlacement? = [nil, .top, .end, .afterCurrent].randomElement(using: &rng)!
                let reference = window.tabs.filter { $0.groupId == group.id }.randomElement(using: &rng)?.id
                let a = make(), b = make()
                a.groups.addWorkspaceToGroup(workspaceId: loose.id, groupId: group.id, placement: placement, referenceWorkspaceId: reference)
                b.groups.nestedAddWorkspaceToGroup(workspaceId: loose.id, groupId: group.id, placement: placement, referenceWorkspaceId: reference)
                let sa = settled(a), sb = settled(b)
                note("add", changed: sa != window, same: ignoringGroupListOrder(sa) == ignoringGroupListOrder(sb), "\(detail) \(lab.name(loose.id)) into \(lab.name(group.id)) \(placement) after \(reference.map { lab.name($0) } ?? "-") -> \(stored(sa, lab)) vs \(stored(sb, lab))")
            }
            do {
                let placement: WorkspaceGroupNewPlacement? = [nil, .top, .end, .afterCurrent].randomElement(using: &rng)!
                let reference = window.tabs.filter { $0.groupId == group.id }.randomElement(using: &rng)?.id
                let a = make(), b = make()
                let na = a.groups.createWorkspaceInGroup(groupId: group.id, placement: placement, referenceWorkspaceId: reference)
                // The same creation, handed over by hand: the host makes the workspace, the nested version places it.
                let created = b.host.createWorkspaceForGroup(title: nil, workingDirectory: nil, initialSurface: .terminal, initialBrowserURL: nil, initialBrowserOmnibarVisible: false, initialBrowserTransparentBackground: false, inheritWorkingDirectory: true, select: true, applyCreationTitleAsCustomTitle: true)!
                b.groups.nestedPlaceNewWorkspace(created, groupId: group.id, placement: placement ?? b.host.defaultNewWorkspacePlacementInGroup, referenceWorkspaceId: reference)
                func named(_ w: NestedWorld, _ id: UUID?) -> NestWindow {
                    var s = settled(w)
                    s.tabs = s.tabs.map { tab in
                        var t = tab
                        if tab.id == id { t.id = UUID(uuid: UUID_NULL_FOR_TESTS) }
                        return t
                    }
                    for index in s.groups.indices where s.groups[index].anchorWorkspaceId == id {
                        s.groups[index].anchorWorkspaceId = UUID(uuid: UUID_NULL_FOR_TESTS)
                    }
                    return ignoringGroupListOrder(s)
                }
                note("new in group", changed: na != nil, same: named(a, na?.id) == named(b, created.id), "\(detail) \(placement) after \(reference.map { lab.name($0) } ?? "-") -> \(stored(named(a, na?.id), lab)) vs \(stored(named(b, created.id), lab))")
            }
        }
        for name in comparisons.keys.sorted() {
            print("theNestedOperationsOnAFlatWindow: \(name): \(comparisons[name] ?? 0) comparisons, \(changes[name] ?? 0) in which the window changed")
            #expect((comparisons[name] ?? 0) > 0, "no comparison for \(name)")
            #expect((changes[name] ?? 0) > 0, "nothing ever changed for \(name)")
        }
        #expect(comparisons.count == 8, "operations compared: \(comparisons.keys.sorted())")
        #expect(differences == 0)
    }
}

private let UUID_NULL_FOR_TESTS: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)

extension WorkspaceGroupDeletionConfirmation {
    /// Whether two confirmations show the same question: every field the dialog reads. The flags that record the window
    /// a confirmation was taken in are not part of the question, so they are left out here and not in `==`.
    func showsTheSameQuestion(as other: WorkspaceGroupDeletionConfirmation) -> Bool {
        groupId == other.groupId
            && groupName == other.groupName
            && anchorWorkspaceId == other.anchorWorkspaceId
            && includesAnchorWorkspace == other.includesAnchorWorkspace
            && memberWorkspaceIds == other.memberWorkspaceIds
            && containedGroupIds == other.containedGroupIds
    }
}
