import Foundation
import Testing
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): the nested versions of the model's order functions.
@MainActor
struct WorkspaceGroupNestedOrderTests {
    // MARK: - The bare repair and the order a caller hands over

    @Test
    func theModelsBareRepairOfANestedWindowMatchesTheLayoutsAndKeepsTheSixRules() {
        let seeds = Int(ProcessInfo.processInfo.environment["CM106_SEEDS"] ?? "") ?? 60
        var compared = 0
        var changed = 0
        for index in 0..<seeds {
            let seed = UInt64(90_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            let window = randomNestedWindow(&rng, &lab)
            let model = upstreamModel(window)
            model.normalizeWorkspaceGroupContiguity()
            var expected = window
            expected.bareRepair()
            let actual = snapshot(model)
            compared += 1
            if actual != window { changed += 1 }
            #expect(actual == expected, "Seed \(seed): \(stored(window, lab)) -> model \(stored(actual, lab)), layout \(stored(expected, lab))")
            #expect(nestViolations(actual, lab).isEmpty, "Seed \(seed)")
        }
        print("theModelsBareRepair: \(compared) windows compared, \(changed) changed by the repair")
        #expect(compared > 0)
        #expect(changed > 0)
    }

    @Test
    func anOrderHandedOverPlacesTheTopLevelRowsInThatOrder() {
        var compared = 0
        var reordered = 0
        for index in 0..<60 {
            let seed = UInt64(91_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            let model = upstreamModel(randomNestedWindow(&rng, &lab))
            model.normalizeWorkspaceGroupContiguity()
            let pinned = model.sidebarTopLevelPinnedWorkspaceIds()
            let current = model.sidebarTopLevelWorkspaceIds()
            let shuffled = current.shuffled(using: &rng)
            let desired = shuffled.filter { pinned.contains($0) } + shuffled.filter { !pinned.contains($0) }
            model.normalizeWorkspaceGroupContiguity(preservingTopLevelIds: desired)
            compared += 1
            if desired != current { reordered += 1 }
            #expect(model.sidebarTopLevelWorkspaceIds() == desired, "Seed \(seed)")
            #expect(nestViolations(snapshot(model), lab).isEmpty, "Seed \(seed): \(stored(snapshot(model), lab))")
        }
        print("anOrderHandedOver: \(compared) windows compared, \(reordered) with a different order handed over")
        #expect(compared > 0)
        #expect(reordered > 0)
    }

    // MARK: - A flat window gets what upstream gives

    @Test
    func theNestedOrderFunctionsOnAFlatWindowReturnWhatUpstreamsReturn() {
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
        for index in 0..<150 {
            let seed = UInt64(92_000 + index)
            var rng = SplitMix64(seed: seed)
            let window = upstreamNormalized(randomFlatWindow(&rng))
            var lab = Labels()
            for tab in window.tabs { lab.name(tab.id, as: "w\(lab.nameById.count)") }
            for group in window.groups { lab.name(group.id, as: "G\(lab.nameById.count)") }
            guard !window.tabs.isEmpty else { continue }
            let original = upstreamModel(window)
            let topLevel = original.sidebarTopLevelWorkspaceIds()
            // Callers hand over a tiered order: pinned top-level rows, then unpinned.
            let pinnedRows = original.sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups()
            func tiered(_ ids: [UUID]) -> [UUID] { ids.filter { pinnedRows.contains($0) } + ids.filter { !pinnedRows.contains($0) } }
            let desired = tiered((topLevel + window.groups.map(\.id)).shuffled(using: &rng))
            let ids = window.tabs.map(\.id)
            let subset = ids.filter { _ in Bool.random(using: &rng) }

            // normalizeWorkspaceGroupRunsPreservingOrder
            do {
                let a = upstreamModel(window), b = upstreamModel(window)
                a.normalizeWorkspaceGroupRunsPreservingOrder(desired)
                b.nestedNormalizeWorkspaceGroupRunsPreservingOrder(desired)
                note("runs", changed: snapshot(a) != window, same: snapshot(a) == snapshot(b), "seed \(seed)")
            }
            // syncWorkspaceGroupsOrderToAnchorOrder, both ways
            do {
                // Tabs in a legal order, the list of groups not: the shape the bare repair is handed.
                var raw = window
                raw.groups.shuffle(using: &rng)
                let a = upstreamModel(raw), b = upstreamModel(raw)
                a.syncWorkspaceGroupsOrderToAnchorOrder()
                b.nestedSyncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: nil)
                note("sync bare", changed: snapshot(a) != raw, same: snapshot(a) == snapshot(b), "seed \(seed)")
                let c = upstreamModel(window), d = upstreamModel(window)
                let preferred = tiered(c.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups().shuffled(using: &rng))
                c.syncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: preferred)
                d.nestedSyncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: preferred)
                note("sync ordered", changed: snapshot(c) != window, same: snapshot(c) == snapshot(d), "seed \(seed): \(stored(window, lab)) preferred \(preferred.map { lab.name($0) }) upstream \(stored(snapshot(c), lab)) nested \(stored(snapshot(d), lab))")
            }
            // the three top-level id reads
            do {
                let tabs = original.tabs.filter { subset.contains($0.id) }
                let a = original.topLevelWorkspaceIds(for: tabs)
                let b = original.nestedTopLevelWorkspaceIds(for: tabs)
                note("top-level ids for", changed: !a.isEmpty, same: a == b, "seed \(seed)")
                let promoted = ids.randomElement(using: &rng)
                let c = original.sidebarTopLevelWorkspaceIds(promotingWorkspaceId: promoted)
                let d = original.nestedSidebarTopLevelWorkspaceIds(promotingWorkspaceId: promoted)
                note("sidebar top-level ids", changed: !c.isEmpty, same: c == d, "seed \(seed)")
                let e = original.topLevelWorkspaceIdsPreservingOrder(desired)
                let f = original.nestedTopLevelWorkspaceIdsPreservingOrder(desired)
                note("top-level ids preserving order", changed: !e.isEmpty, same: e == f, "seed \(seed)")
                let base = original.sidebarTopLevelWorkspaceIds().shuffled(using: &rng)
                let g = original.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(preservingTopLevelIds: base)
                let h = original.nestedSidebarTopLevelWorkspaceIdsIncludingEmptyGroups(preservingTopLevelIds: base)
                note("including empty groups", changed: g != base, same: g == h, "seed \(seed): \(g) vs \(h)")
            }
            // isGlobalPinnedRow and the member clamp
            do {
                for tab in original.tabs {
                    note("global pinned row", changed: original.isGlobalPinnedRow(tab), same: original.isGlobalPinnedRow(tab) == original.nestedIsGlobalPinnedRow(tab), "seed \(seed)")
                    let target = Int.random(in: -1...(ids.count + 1), using: &rng)
                    let a = original.clampedGroupedMemberReorderIndex(for: tab, clampedTargetIndex: target)
                    let b = original.nestedClampedGroupedMemberReorderIndex(for: tab, clampedTargetIndex: target)
                    note("member clamp", changed: a != nil, same: a == b, "seed \(seed): \(String(describing: a)) vs \(String(describing: b))")
                }
            }
            // expand for the selection
            do {
                let selected = ids.randomElement(using: &rng)
                let a = upstreamModel(window), b = upstreamModel(window)
                for model in [a, b] {
                    model.selectedTabId = selected
                    for i in model.workspaceGroups.indices { model.workspaceGroups[i].isCollapsed = true }
                }
                a.expandWorkspaceGroupForSelectionIfNeeded()
                b.nestedExpandWorkspaceGroupForSelectionIfNeeded()
                let aFlags = a.workspaceGroups.map(\.isCollapsed), bFlags = b.workspaceGroups.map(\.isCollapsed)
                note("expand", changed: aFlags.contains(false), same: aFlags == bFlags, "seed \(seed)")
            }
            // moveWorkspaceGroupMembersAfterAnchors
            do {
                let a = upstreamModel(window), b = upstreamModel(window)
                a.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: subset)
                b.nestedMoveWorkspaceGroupMembersAfterAnchors(workspaceIds: subset)
                // Upstream sorts tiers later; the nested edit puts a named member first of its own tier,
                // so compare after the repair both callers run next.
                a.normalizeWorkspaceGroupContiguity()
                b.normalizeWorkspaceGroupContiguity()
                note("members after anchors", changed: snapshot(a) != window, same: snapshot(a) == snapshot(b), "seed \(seed): \(stored(window, lab)) named \(subset.map { lab.name($0) }) upstream \(stored(snapshot(a), lab)) nested \(stored(snapshot(b), lab))")
            }
        }
        for name in comparisons.keys.sorted() {
            print("theNestedOrderFunctionsOnAFlatWindow: \(name): \(comparisons[name] ?? 0) comparisons, \(changes[name] ?? 0) in which the window or the answer changed")
            #expect((comparisons[name] ?? 0) > 0, "no comparison for \(name)")
            #expect((changes[name] ?? 0) > 0, "nothing ever changed for \(name)")
        }
        #expect(comparisons.count == 11, "functions compared: \(comparisons.keys.sorted())")
        #expect(differences == 0)
    }

    // MARK: - Nested cases

    private func model(
        _ lab: inout Labels,
        tabs: [NestWorkspace],
        groups: [NestGroup],
        selected: String? = nil,
        collapsed: [String] = []
    ) -> WorkspacesModel<NestingStubTab> {
        let model = upstreamModel(NestWindow(tabs: tabs, groups: groups))
        if let selected { model.selectedTabId = lab.id(selected) }
        for name in collapsed {
            if let index = model.workspaceGroups.firstIndex(where: { $0.id == lab.id(name) }) {
                model.workspaceGroups[index].isCollapsed = true
            }
        }
        return model
    }

    @Test
    func aGroupedWorkspacesTopLevelRowIsTheOutermostGroup() {
        var lab = Labels()
        let m = model(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("c", in: "C"), lab.ws("w"), lab.ws("p", in: "P")],
            groups: [lab.group("A", own: "a"), lab.group("C", parent: "A", own: "c"), lab.group("P", pinned: true, own: "p")]
        )
        let c = m.tabs.first { $0.id == lab.id("c") }!
        #expect(m.topLevelWorkspaceIds(for: [c]) == [lab.id("a")])
        #expect(m.sidebarTopLevelWorkspaceIds() == [lab.id("a"), lab.id("w"), lab.id("p")])
        #expect(m.topLevelWorkspaceIdsPreservingOrder([lab.id("w"), lab.id("c")]) == [lab.id("w"), lab.id("a"), lab.id("p")])
        #expect(m.sidebarTopLevelPinnedWorkspaceIds() == [lab.id("p")])
        #expect(!m.isGlobalPinnedRow(c))
    }

    @Test
    func aWorkspaceInsideAPinnedParentIsPinnedByTheOutermostGroup() {
        var lab = Labels()
        let m = model(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("c", in: "C")],
            groups: [lab.group("A", pinned: true, own: "a"), lab.group("C", parent: "A", own: "c")]
        )
        #expect(m.isGlobalPinnedRow(m.tabs.first { $0.id == lab.id("c") }!))
    }

    @Test
    func selectingAWorkspaceInsideOpensEveryGroupAboveIt() {
        var lab = Labels()
        let tabs = [lab.ws("a", in: "A"), lab.ws("c", in: "C"), lab.ws("d", in: "D"), lab.ws("x", in: "D")]
        let groups = [lab.group("A", own: "a"), lab.group("C", parent: "A", own: "c"), lab.group("D", parent: "C", own: "d")]
        let inner = model(&lab, tabs: tabs, groups: groups, selected: "x", collapsed: ["A", "C", "D"])
        inner.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(inner.workspaceGroups.map(\.isCollapsed) == [false, false, false])
        // The workspace behind D's name is D's header: D stays folded, the groups above it open.
        let header = model(&lab, tabs: tabs, groups: groups, selected: "d", collapsed: ["A", "C", "D"])
        header.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(header.workspaceGroups.map(\.isCollapsed) == [false, false, true])
    }

    @Test
    func aWorkspaceChangingGroupDoesNotReopenAFoldedParentInANestedWindowButDoesInAFlatOne() {
        var lab = Labels()
        // Nested: P has no workspace of its own and is folded over the selected workspace c.
        let nested = model(
            &lab,
            tabs: [lab.ws("c", in: "C"), lab.ws("w"), lab.ws("z")],
            groups: [lab.group("P"), lab.group("C", parent: "P", own: "c")],
            selected: "c",
            collapsed: ["P"]
        )
        nested.assignGroup(workspaceId: lab.id("w"), groupId: lab.id("C"))
        #expect(nested.workspaceGroups.first { $0.id == lab.id("P") }?.isCollapsed == true)
        nested.assignGroup(workspaceId: lab.id("c"), groupId: lab.id("C"))
        #expect(nested.workspaceGroups.first { $0.id == lab.id("P") }?.isCollapsed == true)
        nested.assignGroup(workspaceId: lab.id("c"), groupId: nil)
        nested.assignGroup(workspaceId: lab.id("c"), groupId: lab.id("C"))
        #expect(nested.workspaceGroups.first { $0.id == lab.id("P") }?.isCollapsed == false)
        // Flat: upstream's quirk stays; any reassignment opens the folded group over the selection.
        let flat = model(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "A"), lab.ws("z")],
            groups: [lab.group("A", own: "a")],
            selected: "b",
            collapsed: ["A"]
        )
        flat.assignGroup(workspaceId: lab.id("z"), groupId: nil)
        flat.assignGroup(workspaceId: lab.id("z"), groupId: lab.id("A"))
        #expect(flat.workspaceGroups.first?.isCollapsed == false)
    }

    @Test
    func hoistingNamedMembersMovesOnlyThoseInsideTheirOwnGroup() {
        var lab = Labels()
        let m = model(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("z", in: "C"), lab.ws("x", in: "G"), lab.ws("u", in: "G")],
            groups: [lab.group("G", own: "g"), lab.group("C", parent: "G", own: "c")]
        )
        m.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [lab.id("z"), lab.id("u")])
        // z goes first inside C, u first among G's own rows (before the child group C); x stays after C.
        #expect(m.tabs.map { lab.name($0.id) } == ["g", "u", "c", "z", "y", "x"])
    }

    @Test
    func onlyATopLevelGroupWithNoWorkspaceAnywhereInsideIsPlacedByTheListOfGroups() {
        var lab = Labels()
        let m = model(
            &lab,
            tabs: [lab.ws("c", in: "C"), lab.ws("w")],
            groups: [lab.group("P"), lab.group("C", parent: "P", own: "c"), lab.group("E")]
        )
        // P has no workspace of its own but holds C: it has a run and is a row by its placeholder id.
        #expect(m.sidebarTopLevelWorkspaceIds() == [lab.id("P"), lab.id("w")])
        #expect(m.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(preservingTopLevelIds: m.sidebarTopLevelWorkspaceIds())
            == [lab.id("P"), lab.id("w"), lab.id("E")])
    }

    @Test
    func aMemberReorderIsHeldInsideItsGroupsWholeRun() {
        var lab = Labels()
        let m = model(
            &lab,
            tabs: [lab.ws("o"), lab.ws("g", in: "G"), lab.ws("x", in: "G"), lab.ws("y", in: "G"), lab.ws("c", in: "C"), lab.ws("q")],
            groups: [lab.group("G", own: "g"), lab.group("C", parent: "G", own: "c")]
        )
        let x = m.tabs.first { $0.id == lab.id("x") }!
        #expect(m.clampedGroupedMemberReorderIndex(for: x, clampedTargetIndex: 99) == 4)
        #expect(m.clampedGroupedMemberReorderIndex(for: x, clampedTargetIndex: 0) == 2)
        #expect(m.clampedGroupedMemberReorderIndex(for: m.tabs.first { $0.id == lab.id("g") }!, clampedTargetIndex: 3) == nil)
    }

    @Test
    func aSavedParentThatNamesNoGroupOrLoopsIsRepairedWhenTheOrderIsNextWritten() {
        var lab = Labels()
        let m = model(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b")]
        )
        m.workspaceGroups[0].parentGroupId = lab.id("B")
        m.workspaceGroups[1].parentGroupId = lab.id("A")
        m.normalizeWorkspaceGroupContiguity()
        // A->B and B->A: the first in list order is opened to the top level.
        #expect(m.workspaceGroups.map(\.parentGroupId) == [nil, lab.id("A")])
    }
}
