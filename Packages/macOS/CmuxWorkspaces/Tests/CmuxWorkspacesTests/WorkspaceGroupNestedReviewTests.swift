import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): a flat window never enters the nested path, the two lines once
// called uncatchable, and the survivors of the reviewer's 64 breaks.
@MainActor
struct WorkspaceGroupNestedReviewTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup], selected: String? = nil) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups), selected: selected.map { lab.id($0) })
    }

    // MARK: - A flat window runs upstream's code

    @Test
    func aFlatWindowNeverEntersTheNestedPathInAnyFunctionThatHandsOver() {
        var calls = [String: Int]()
        var entered = [String]()
        var noticeMismatches = [String]()
        var noticesCompared = [String: Int]()
        for index in 0..<150 {
            let seed = UInt64(99_000 + index)
            var rng = SplitMix64(seed: seed)
            let window = upstreamNormalized(randomFlatWindow(&rng))
            guard window.tabs.count >= 2, let group = window.groups.randomElement(using: &rng) else { continue }
            let selected = window.tabs.randomElement(using: &rng)?.id
            let ids = window.tabs.map(\.id)
            let desired = ids.shuffled(using: &rng)
            let member = window.tabs.first { $0.groupId != nil && !window.isAnchor($0.id) }
            let loose = window.tabs.first { $0.groupId == nil && !window.isAnchor($0.id) }
            func check(_ names: String..., body: (NestedWorld) -> Void) { checkNames(names, body: body) }
            func checkNames(_ names: [String], body: (NestedWorld) -> Void) {
                let w = NestedWorld(window, selected: selected)
                w.host.sidebarSelectedWorkspaceIds = Set(ids.prefix(2))
                body(w)
                for name in names { calls[name, default: 0] += 1 }
#if DEBUG
                if w.model.nestedGroupTreeBuilds != 0 { entered.append("\(names.joined(separator: ", ")) (seed \(seed))") }
#endif
            }
            // The notice a flat window sends is what v0.31.0 sends: a call that sent one is compared with the base's rule.
            func compare(_ name: String, _ w: NestedWorld, noticesBefore: Int, base expected: [UUID]) {
                guard w.host.orderChanges.count > noticesBefore else { return }
                noticesCompared[name, default: 0] += 1
                if w.host.orderChanges.last != expected {
                    noticeMismatches.append("\(name) (seed \(seed)): sent \(w.host.orderChanges.last ?? []), v0.31.0 sends \(expected)")
                }
            }
            check("setWorkspaceGroupPinned: the notice ids") { w in
                let before = w.host.orderChanges.count
                let isPinned = w.model.workspaceGroups.first { $0.id == group.id }?.isPinned ?? false
                w.groups.setWorkspaceGroupPinned(groupId: group.id, isPinned: !isPinned)
                // Base: the group's direct members in tabs order, read after the pin.
                compare("setWorkspaceGroupPinned: the notice ids", w, noticesBefore: before, base: w.model.tabs.filter { $0.groupId == group.id }.map(\.id))
            }
            check("moveTabsToTop: the notice ids") { w in
                let before = w.host.orderChanges.count
                let selected = Set(ids.suffix(2))
                let selectedInOrder = w.model.tabs.map(\.id).filter { selected.contains($0) }
                w.reorder.moveTabsToTop(selected)
                compare("moveTabsToTop: the notice ids", w, noticesBefore: before, base: selectedInOrder)
            }
            check("moveTabToTopForNotification: the notice ids") { w in
                let before = w.host.orderChanges.count
                w.reorder.moveTabToTopForNotification(ids[1])
                compare("moveTabToTopForNotification: the notice ids", w, noticesBefore: before, base: [ids[1]])
            }
            check("reorderWorkspace(tabId:toIndex:): the notice ids") { w in
                guard !w.model.workspaceGroups.contains(where: { $0.isPinned }) else { return }
                let before = w.host.orderChanges.count
                _ = w.reorder.reorderWorkspace(tabId: ids[0], toIndex: 1)
                compare("reorderWorkspace(tabId:toIndex:): the notice ids", w, noticesBefore: before, base: [ids[0]])
            }
            check("reorderTopLevelWorkspaceItem: the notice ids") { w in
                guard let anchor = group.anchorWorkspaceId else { return }
                let before = w.host.orderChanges.count
                _ = w.reorder.reorderSidebarWorkspace(tabId: anchor, toIndex: 0, isDragOperation: true, usesTopLevelRows: true)
                // Base: the group the dragged workspace stands behind, its direct members in tabs order, read after the move.
                compare("reorderTopLevelWorkspaceItem: the notice ids", w, noticesBefore: before, base: w.model.tabs.filter { $0.groupId == group.id }.map(\.id))
            }
            check("reorderWorkspaces: the notice ids") { w in
                let before = w.host.orderChanges.count
                guard case .success(let plan) = w.reorder.reorderWorkspaces(orderedWorkspaceIds: desired) else { return }
                // Base: the planned workspaces whose index changes, in request order.
                compare("reorderWorkspaces: the notice ids", w, noticesBefore: before, base: plan.filter { $0.fromIndex != $0.toIndex }.map(\.workspaceId))
            }
            let anchors = window.groups.compactMap(\.anchorWorkspaceId)
            if anchors.count >= 2 {
                check("reorderTopLevelWorkspaceBlock: the notice ids") { w in
                    let before = w.host.orderChanges.count
                    let movedAnchors = Set(anchors.prefix(2))
                    _ = w.reorder.reorderSidebarWorkspaces(
                        tabIds: Array(anchors.prefix(2)), draggedTabId: anchors[0], toIndex: w.model.tabs.count,
                        isDragOperation: true, usesTopLevelRows: true
                    )
                    let movedGroups = Set(w.model.workspaceGroups.compactMap { movedAnchors.contains($0.anchorWorkspaceId) ? $0.id : nil })
                    // Base: every workspace whose group is a moved group, in tabs order, read after the move.
                    compare("reorderTopLevelWorkspaceBlock: the notice ids", w, noticesBefore: before, base: w.model.tabs.compactMap { tab in tab.groupId.map(movedGroups.contains) == true ? tab.id : nil })
                }
            }
            check("normalizeWorkspaceGroupRunsPreservingOrder") { $0.model.normalizeWorkspaceGroupRunsPreservingOrder(desired) }
            check("normalizeWorkspaceGroupContiguity") { $0.model.normalizeWorkspaceGroupContiguity() }
            check("syncWorkspaceGroupsOrderToAnchorOrder") { $0.model.syncWorkspaceGroupsOrderToAnchorOrder() }
            check("expandWorkspaceGroupForSelectionIfNeeded") { $0.model.expandWorkspaceGroupForSelectionIfNeeded() }
            check("moveWorkspaceGroupMembersAfterAnchors") { $0.model.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: desired) }
            check("topLevelWorkspaceIds(for:)") { w in _ = w.model.topLevelWorkspaceIds(for: w.model.tabs) }
            check("sidebarTopLevelWorkspaceIds") { w in _ = w.model.sidebarTopLevelWorkspaceIds(promotingWorkspaceId: ids.first) }
            check("sidebarTopLevelWorkspaceIdsIncludingEmptyGroups") { w in _ = w.model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(preservingTopLevelIds: desired) }
            check("topLevelWorkspaceIdsPreservingOrder") { w in _ = w.model.topLevelWorkspaceIdsPreservingOrder(desired) }
            check("isGlobalPinnedRow") { w in for tab in w.model.tabs { _ = w.model.isGlobalPinnedRow(tab) } }
            check("clampedGroupedMemberReorderIndex") { w in for tab in w.model.tabs { _ = w.model.clampedGroupedMemberReorderIndex(for: tab, clampedTargetIndex: 1) } }
            check("assignGroup") { w in w.model.assignGroup(workspaceId: ids[0], groupId: group.id) }
            check("dissolveGroupsAnchoredBy: which groups keep the header", "dissolveGroupsAnchoredBy: the keep-header loop", "dissolveGroupsAnchoredBy: workspaces take the parent", "dissolveGroupsAnchoredBy: the parent's own workspace") { w in w.model.tabs.removeAll { $0.id == ids[0] }; w.model.dissolveGroupsAnchoredBy(closedWorkspaceId: ids[0]) }
            check("promoteAnchorOrRemoveGroupsAnchoredBy") { w in w.model.tabs.removeAll { $0.id == ids[0] }; w.model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: ids[0]) }
            check("ungroupWorkspaceGroup") { w in _ = w.groups.ungroupWorkspaceGroup(groupId: group.id) }
            check("toggleWorkspaceGroupCollapsed") { w in w.groups.toggleWorkspaceGroupCollapsed(groupId: group.id) }
            check("moveWorkspaceGroup") { w in w.groups.moveWorkspaceGroup(groupId: group.id, toIndex: 0) }
            check("deletionConfirmation") { w in _ = w.groups.deletionConfirmation(groupId: group.id) }
            check("deleteWorkspaceGroup") { w in _ = w.groups.deleteWorkspaceGroup(groupId: group.id) }
            check("moveTabsToTop") { w in w.reorder.moveTabsToTop(Set(ids.prefix(2))) }
            check("moveTabToTopForNotification") { w in w.reorder.moveTabToTopForNotification(ids[1]) }
            // The drop entrances: a flat window gives the result, the answer and the notice v0.31.0 gives (the frozen copy of
            // v0.31.0's coordinator, run on a second copy of the same window).
            func againstBase(_ names: String..., live: (WorkspaceReorderCoordinator<NestingStubTab>) -> Bool, base: (FrozenV0_31_0ReorderCoordinator<NestingStubTab>) -> Bool) {
                checkNames(names) { w in
                    let other = NestedWorld(window, selected: selected)
                    other.host.sidebarSelectedWorkspaceIds = w.host.sidebarSelectedWorkspaceIds
                    let frozen = FrozenV0_31_0ReorderCoordinator(model: other.model)
                    frozen.attach(host: other.host)
                    let liveAnswer = live(w.reorder)
                    let baseAnswer = base(frozen)
                    if liveAnswer != baseAnswer || w.window != other.window || w.host.orderChanges != other.host.orderChanges {
                        noticeMismatches.append("\(names.joined(separator: ", ")) (seed \(seed)): live \(liveAnswer) \(w.compact(Labels())) \(w.host.orderChanges.count) notices, v0.31.0 \(baseAnswer) \(other.compact(Labels())) \(other.host.orderChanges.count) notices")
                    }
                    noticesCompared[names[0], default: 0] += 1
                }
            }
            againstBase("applyDragInferredGroupMembership", "reorderSidebarWorkspace: a nested group's header",
                        live: { $0.reorderSidebarWorkspace(tabId: ids[0], toIndex: 1, isDragOperation: true) },
                        base: { $0.reorderSidebarWorkspace(tabId: ids[0], toIndex: 1, isDragOperation: true) })
            againstBase("reorderSidebarWorkspace: a workspace dropped on a group of a nested window",
                        live: { $0.reorderSidebarWorkspace(tabId: ids[0], toIndex: 1, isDragOperation: true, explicitGroupId: group.id) },
                        base: { $0.reorderSidebarWorkspace(tabId: ids[0], toIndex: 1, isDragOperation: true, explicitGroupId: group.id) })
            againstBase("applyDragInferredGroupMembership", "reorderSidebarWorkspaces: headers that include a nested group's header",
                        live: { $0.reorderSidebarWorkspaces(tabIds: Array(ids.prefix(2)), draggedTabId: ids[0], toIndex: 0, isDragOperation: true) },
                        base: { $0.reorderSidebarWorkspaces(tabIds: Array(ids.prefix(2)), draggedTabId: ids[0], toIndex: 0, isDragOperation: true) })
            againstBase("reorderSidebarWorkspaces: workspaces dropped on a group of a nested window",
                        live: { $0.reorderSidebarWorkspaces(tabIds: Array(ids.prefix(2)), draggedTabId: ids[0], toIndex: 0, isDragOperation: true, explicitGroupId: group.id) },
                        base: { $0.reorderSidebarWorkspaces(tabIds: Array(ids.prefix(2)), draggedTabId: ids[0], toIndex: 0, isDragOperation: true, explicitGroupId: group.id) })
            againstBase("reorderSidebarWorkspaces: workspaces dropped at the top level of a nested window",
                        live: { $0.reorderSidebarWorkspaces(tabIds: Array(ids.prefix(3)), draggedTabId: ids[0], toIndex: 1, isDragOperation: true, usesTopLevelRows: true) },
                        base: { $0.reorderSidebarWorkspaces(tabIds: Array(ids.prefix(3)), draggedTabId: ids[0], toIndex: 1, isDragOperation: true, usesTopLevelRows: true) })
            againstBase("reorderSidebarWorkspaces: workspaces dropped at the top level of a nested window",
                        live: { $0.reorderSidebarWorkspaces(tabIds: Array(ids.prefix(3)), draggedTabId: ids[1], toIndex: 2, isDragOperation: true) },
                        base: { $0.reorderSidebarWorkspaces(tabIds: Array(ids.prefix(3)), draggedTabId: ids[1], toIndex: 2, isDragOperation: true) })
            check("setPinned(workspaceIds:)") { w in w.reorder.setPinned(workspaceIds: Array(ids.prefix(2)), pinned: true) }
            check("reorderWorkspace(tabId:toIndex:)") { w in
                // Upstream's step: any index is brought into range by its own clamp, except the trap a flat window has: upstream's code traps on an unpinned workspace behind the name of a pinned group.
                if !w.model.workspaceGroups.contains(where: { $0.isPinned }) {
                    _ = w.reorder.reorderWorkspace(tabId: ids[0], toIndex: 1)
                }
            }
            if let member {
                check("removeWorkspaceFromGroup") { w in w.groups.removeWorkspaceFromGroup(workspaceId: member.id) }
            }
            if let loose {
                check("addWorkspaceToGroup") { w in w.groups.addWorkspaceToGroup(workspaceId: loose.id, groupId: group.id) }
                check("addWorkspaceToGroup") { w in w.groups.addWorkspaceToGroup(workspaceId: loose.id, groupId: group.id, placement: .top) }
            }
            check("createWorkspaceInGroup") { w in _ = w.groups.createWorkspaceInGroup(groupId: group.id, placement: .end) }
            // A new group takes the nested version when its first eligible workspace sits in a group; in a flat window
            // that is the one case that differs from upstream by design, so the check makes it from ungrouped ones.
            let ungrouped = window.tabs.filter { $0.groupId == nil && !window.isAnchor($0.id) }.prefix(2).map(\.id)
            if !ungrouped.isEmpty {
                check("createWorkspaceGroup: the first eligible workspace in a group") { w in
                    _ = w.groups.createWorkspaceGroup(name: "New", childWorkspaceIds: Array(ungrouped), collapseSidebarSelection: false)
                }
            }
            check("removeGeneratedAnchorWorkspace: the guard on a group that holds groups") { w in
                if let at = w.model.workspaceGroups.firstIndex(where: { $0.id == group.id }) {
                    w.model.workspaceGroups[at].anchorWorkspaceProvenance = .generated
                }
                _ = w.groups.ungroupWorkspaceGroup(groupId: group.id, removeGeneratedAnchor: true)
            }
        }
        // The exact list: every hand-over site has a line above, and no line above is for something else.
        for name in WorkspaceGroupNestedHandOverGuardTests.flatHandOverSites {
            print("aFlatWindowNeverEntersTheNestedPath: \(name): \(calls[name] ?? 0) flat windows")
            #expect((calls[name] ?? 0) > 0, "never called: \(name)")
        }
        #expect(
            Set(calls.keys).subtracting(WorkspaceGroupNestedHandOverGuardTests.flatHandOverSites).subtracting(WorkspaceGroupNestedHandOverGuardTests.flatChecksThatAreNotSites).isEmpty,
            "a check for something that is not on the list of hand-over sites: \(Set(calls.keys).subtracting(WorkspaceGroupNestedHandOverGuardTests.flatHandOverSites))"
        )
        #expect(entered.isEmpty, "entered the nested path in a flat window: \(entered.prefix(5))")
        #expect(noticeMismatches.isEmpty, "a flat window's order-change notice differs from v0.31.0's: \(noticeMismatches.prefix(5))")
        for name in WorkspaceGroupNestedHandOverGuardTests.flatHandOverSites where name.hasSuffix(": the notice ids") {
            print("aFlatWindowNeverEntersTheNestedPath: \(name): \(noticesCompared[name] ?? 0) notices compared")
            #expect((noticesCompared[name] ?? 0) > 0, "no notice was ever compared: \(name)")
        }
    }

    // MARK: - Two lines once called uncatchable

    @Test
    func theHeaderOfAGroupThatHoldsGroupsPassesToTheNextOwnWorkspaceWhenItsWorkspaceLeavesTheWindow() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("w4", in: "G0"), lab.ws("w2", in: "G1"), lab.ws("w3", in: "G1"), lab.ws("w0", in: "G0", pinned: true), lab.ws("w5"), lab.ws("w1")],
            groups: [lab.group("G0", own: "w4"), lab.group("G1", parent: "G0", pinned: true, own: "w2")]
        )
        #expect(w.compact(lab) == "G0[w4: G1*[w2: w3], w0*] | w5 | w1")
        w.model.tabs.removeAll { $0.id == lab.id("w4") }
        w.model.dissolveGroupsAnchoredBy(closedWorkspaceId: lab.id("w4"))
        // w0, pinned, now stands behind G0's name (the header is not a row, so no star is drawn).
        #expect(w.compact(lab) == "G0[w0: G1*[w2: w3]] | w5 | w1")
        #expect(w.window.groups.first { $0.id == lab.id("G0") }?.anchorWorkspaceId == lab.id("w0"))
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aNewWorkspaceInAnEmptyPinnedHeaderKeepsTheHeadersPlaceBeforeItsPinnedSibling() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("w5", in: "G0"), lab.ws("w6", in: "G1"), lab.ws("w3", in: "G1", pinned: true)],
            groups: [lab.group("G0", own: "w5"), lab.group("G2", parent: "G0", pinned: true), lab.group("G1", parent: "G0", pinned: true, own: "w6")]
        )
        #expect(w.compact(lab) == "G0[w5: G2*[-], G1*[w6: w3*]]")
        let created = try! #require(w.groups.createWorkspaceInGroup(groupId: lab.id("G2"), placement: .end))
        lab.name(created.id, as: "NEW")
        #expect(w.compact(lab) == "G0[w5: G2*[NEW], G1*[w6: w3*]]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - The survivors

    @Test
    func aHeaderOnlyParentTakesTheFirstWorkspaceThatArrivesNotTheLast() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "C"), lab.ws("b", in: "C"), lab.ws("c", in: "C"), lab.ws("u")],
            groups: [lab.group("P", pinned: true), lab.group("C", parent: "P", own: "a")]
        )
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("C"))
        #expect(w.compact(lab) == "P*[a: b, c] | u")
        #expect(w.window.groups.first { $0.id == lab.id("P") }?.anchorWorkspaceId == lab.id("a"))
    }

    @Test
    func aGroupThatNamesAWorkspaceItDoesNotOwnLosesTheNameInTheNestedRepair() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("c", in: "C"), lab.ws("x")],
            groups: [lab.group("P", pinned: true), lab.group("C", parent: "P", own: "c")]
        )
        // P stores x as the workspace behind its name, but x is not P's.
        w.model.workspaceGroups[0].anchor = .workspace(lab.id("x"))
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("P") }?.liveAnchorWorkspaceId == nil)
        #expect(w.compact(lab) == "P*[-: C[c]] | x")
    }

    @Test
    func rowsAnOrderLeavesOutKeepTheirRelativeOrderAfterThoseItNames() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a"), lab.ws("g", in: "G"), lab.ws("c", in: "C"), lab.ws("b"), lab.ws("x")],
            groups: [lab.group("G", own: "g"), lab.group("C", parent: "G", own: "c")]
        )
        #expect(w.compact(lab) == "a | G[g: C[c]] | b | x")
        w.model.normalizeWorkspaceGroupRunsPreservingOrder([lab.id("x")])
        #expect(w.window.tabs.map { lab.name($0.id) } == ["x", "a", "g", "c", "b"])
    }

    @Test
    func theMemberClampCountsOnlyThePinnedDirectMembersOfTheGroup() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("p", in: "G", pinned: true), lab.ws("x", in: "G"), lab.ws("c", in: "C"), lab.ws("q", in: "C", pinned: true)],
            groups: [lab.group("G", own: "g"), lab.group("C", parent: "G", own: "c")]
        )
        let x = w.model.tabs.first { $0.id == lab.id("x") }!
        #expect(w.compact(lab) == "G[g: p*, x, C[c: q*]]")
        #expect(w.model.clampedGroupedMemberReorderIndex(for: x, clampedTargetIndex: 0) == 2)
    }

    @Test
    func addingAWorkspaceDoesNotReopenAFoldedParentOverTheSelection() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("n"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")],
            selected: "c"
        )
        w.model.workspaceGroups[0].isCollapsed = true
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("n"), groupId: lab.id("C"))
        #expect(w.model.workspaceGroups[0].isCollapsed)
        // Adding the selected workspace itself does show it.
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("c"), groupId: lab.id("P"))
        w.model.selectedTabId = lab.id("n")
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("u"), groupId: lab.id("P"))
        #expect(w.model.workspaceGroups[0].isCollapsed)
    }

    @Test
    func foldingAParentHidesEveryLevelInsideNotOnlyTwo() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("d", in: "D"), lab.ws("e", in: "E"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("D", parent: "C", own: "d"), lab.group("E", parent: "D", own: "e")],
            selected: "e"
        )
        w.host.sidebarSelectedWorkspaceIds = [lab.id("e"), lab.id("u")]
        w.groups.toggleWorkspaceGroupCollapsed(groupId: lab.id("P"))
        #expect(w.host.subtractedSidebarSelections.last?.hidden == [lab.id("c"), lab.id("d"), lab.id("e")])
        #expect(w.model.selectedTabId == lab.id("p"))
    }

    @Test
    func foldingNamesTheFocusedWorkspaceWhenTheSelectionIsTheHeader() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")],
            selected: "p"
        )
        w.host.sidebarSelectedWorkspaceIds = [lab.id("p"), lab.id("c")]
        w.groups.toggleWorkspaceGroupCollapsed(groupId: lab.id("P"))
        #expect(w.host.subtractedSidebarSelections.last?.hidden == [lab.id("c")])
        #expect(w.host.subtractedSidebarSelections.last?.focused == lab.id("p"))
    }

    @Test
    func aDeleteEndsInTheRepairSoALateJoinersTierIsLegal() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O"), lab.ws("t", in: "O"), lab.ws("p", in: "P"), lab.ws("n", pinned: true), lab.ws("u")],
            groups: [lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("n"), groupId: lab.id("P"))
        _ = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        // n, pinned, goes up to O at P's place, after the unpinned t: the repair puts it first.
        #expect(w.compact(lab) == "O[o: n*, t] | u")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aDeleteCountsOnlyTheWorkspacesThatReallyClosed() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("c", in: "C"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        w.host.refusesToClose = [lab.id("a")]
        #expect(w.groups.deleteWorkspaceGroup(groupId: lab.id("P")) == 2)
    }

    @Test
    func theNotificationWalkTakesTheOutermostGroupFirstAtDepthThree() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("u"), lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C"), lab.ws("z", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("B", parent: "A", pinned: true, own: "b"), lab.group("C", parent: "B", own: "c")]
        )
        #expect(w.compact(lab) == "u | A[a: B*[b: C[c: z]]]")
        w.reorder.moveTabToTopForNotification(lab.id("z"))
        // A (unpinned) goes first; the walk stops at B (pinned): C and z do not move.
        #expect(w.compact(lab) == "A[a: B*[b: C[c: z]]] | u")
        // With the chain read innermost first, C would have moved inside B before the walk stopped.
        var lab2 = Labels()
        let w2 = world(
            &lab2,
            tabs: [lab2.ws("a", in: "A"), lab2.ws("b", in: "B"), lab2.ws("y", in: "C"), lab2.ws("c", in: "C"), lab2.ws("z", in: "D"), lab2.ws("d", in: "D")],
            groups: [lab2.group("A", own: "a"), lab2.group("B", parent: "A", pinned: true, own: "b"), lab2.group("C", parent: "B", own: "y"), lab2.group("D", parent: "B", own: "z")]
        )
        let before = w2.compact(lab2)
        w2.reorder.moveTabToTopForNotification(lab2.id("d"))
        #expect(w2.compact(lab2) == before)
    }

    @Test
    func aSocketIndexInsideARunBeforeItsFirstDirectWorkspaceMapsToThatGroupsRow() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("v"), lab.ws("w"), lab.ws("c", in: "C"), lab.ws("t"), lab.ws("u")],
            groups: [lab.group("P"), lab.group("C", parent: "P", own: "c")]
        )
        #expect(w.compact(lab) == "v | w | P[-: C[c]] | t | u")
        // Index 2 is c, inside P's run, which starts there though P has no workspace of its own: the nearest row is P.
        #expect(w.reorder.reorderWorkspace(tabId: lab.id("u"), toIndex: 2))
        #expect(w.compact(lab) == "v | w | u | P[-: C[c]] | t")
    }

    @Test
    func aStepThatChangesNothingSendsNoNoticeAndOneThatMovesSendsOne() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("u1"), lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("u2")],
            groups: [lab.group("A", own: "a"), lab.group("B", parent: "A", own: "b")]
        )
        let before = w.host.orderChanges.count
        // u1 is the first row: one step up changes nothing.
        #expect(w.reorder.reorderWorkspace(tabId: lab.id("u1"), toIndex: -1))
        #expect(w.host.orderChanges.count == before)
        #expect(w.reorder.reorderWorkspace(tabId: lab.id("u1"), toIndex: 1))
        #expect(w.host.orderChanges.last == [lab.id("u1")])
    }

    @Test
    func theOperationsThatChangeOrderOrMembershipSendTheOrderChangeNotice() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("n"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("n"), groupId: lab.id("P"))
        #expect(w.host.orderChanges.last == [lab.id("n")])
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("C"))
        #expect(Set(w.host.orderChanges.last ?? []) == [lab.id("c"), lab.id("y")])
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aNestedDeleteSendsTheOrderChangeNoticeWithTheConfirmedWorkspaces() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("y", in: "C"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        let noticesBefore = w.host.orderChanges.count
        _ = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(w.host.orderChanges.count == noticesBefore + 1)
        #expect(w.host.orderChanges.last == confirmation.memberWorkspaceIds)
    }

    @Test
    func aNotificationMoveThatAppliesNothingLeavesAWindowNotAtRestAsItIs() {
        var lab = Labels()
        // The list of groups is out of the order the runs start in, and u is pinned and ungrouped.
        let window = NestWindow(
            tabs: [lab.ws("u", pinned: true), lab.ws("a", in: "A"), lab.ws("x", in: "X"), lab.ws("y", in: "X")],
            groups: [lab.group("X", own: "x"), lab.group("A", own: "a"), lab.group("Z", parent: "A")]
        )
        let w = NestedWorld(window)
        let before = w.model.workspaceGroups.map(\.id)
        w.reorder.moveTabToTopForNotification(lab.id("u"))
        #expect(w.model.workspaceGroups.map(\.id) == before)
    }

    @Test
    func aSingleDragInANestedWindowKeepsItsMembershipInference() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("u"), lab.ws("a", in: "A"), lab.ws("x", in: "A"), lab.ws("y", in: "A"), lab.ws("c", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("C", parent: "A", own: "c")]
        )
        // Dropped between x and y, u joins A: the step path would only move the row.
        #expect(w.reorder.reorderWorkspace(tabId: lab.id("u"), toIndex: 2, isDragOperation: true))
        #expect(w.window.tabs.first { $0.id == lab.id("u") }?.groupId == lab.id("A"))
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func theRouterRefusesAHeaderDragThatUsesTopLevelRowsEvenWhenItIsNotMarkedADrag() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B")],
            groups: [lab.group("A", own: "a"), lab.group("B", parent: "A", own: "b")]
        )
        #expect(!w.reorder.reorderSidebarWorkspace(tabId: lab.id("b"), toIndex: 0, usesTopLevelRows: true))
    }

#if DEBUG
    @Test
    func theFlatPathsThatDoNotRepairStillDoNot() {
        // Unpinning two ungrouped workspaces together in a flat window, and a drag that leaves an ungrouped row
        // ungrouped, end with no repair, as upstream's code does (v0.31.0).
        var lab = Labels()
        let pinned = world(
            &lab,
            tabs: [lab.ws("w0", pinned: true), lab.ws("w1", pinned: true), lab.ws("g", in: "G", pinned: true), lab.ws("h", in: "G")],
            groups: [lab.group("G", pinned: true, own: "g")]
        )
        pinned.reorder.setPinned(workspaceIds: [lab.id("w0"), lab.id("w1")], pinned: false)
        #expect(pinned.model.contiguityRepairs == 0)
        var lab2 = Labels()
        let drag = world(
            &lab2,
            tabs: [lab2.ws("p", in: "P"), lab2.ws("c", in: "Q"), lab2.ws("x")],
            groups: [lab2.group("P", own: "p"), lab2.group("Q", own: "c")]
        )
        #expect(drag.reorder.reorderSidebarWorkspace(tabId: lab2.id("x"), toIndex: 1, isDragOperation: true))
        #expect(drag.model.contiguityRepairs == 0)
    }
#endif

    // MARK: - Second round after review: Delete Group on a confirmation taken in a nested window

    @Test
    func aDeleteAskedOnANestedGroupAndPressedAfterTheWindowWentFlatClosesOnlyWhatIsStillInside() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("c", in: "C"), lab.ws("c2", in: "C"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        #expect(w.compact(lab) == "P[p: a, C[c: c2]] | z")
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(confirmation.containedGroupCount == 1 && confirmation.memberCount == 4)
        // C moves to the top level while the question is open: the window is flat now.
        w.model.workspaceGroups[1].parentGroupId = nil
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(!w.model.hasNestedWorkspaceGroup)
        let closed = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(closed == 2)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["a", "p"])
        #expect(w.compact(lab) == "C[c: c2] | z")
    }

    @Test
    func aDeleteAskedOnANestedGroupWhoseGroupWasUngroupedMeanwhileClosesNothing() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("c", in: "C"), lab.ws("c2", in: "C"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("P"))
        #expect(!w.model.hasNestedWorkspaceGroup)
        let before = w.compact(lab)
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 0)
        #expect(w.host.closedWorkspaceIds.isEmpty)
        #expect(w.compact(lab) == before)
    }

    // MARK: - What was named and now sits inside a group that joined late is left alone

    @Test
    func aConfirmedGroupThatMovedInsideAGroupThatJoinedLateIsNotDeletedAndItsWorkspacesDoNotClose() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("c", in: "C"), lab.ws("c2", in: "C"), lab.ws("l", in: "L"), lab.ws("m", in: "L"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("L", own: "l")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        // L joins P, then C moves into L, while the question is open.
        w.model.workspaceGroups[2].parentGroupId = lab.id("P")
        w.model.workspaceGroups[1].parentGroupId = lab.id("L")
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(w.compact(lab) == "P[p: a, L[l: C[c: c2], m]] | z")
        let closed = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(closed == 2)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["a", "p"])
        #expect(w.compact(lab) == "L[l: C[c: c2], m] | z")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aConfirmedWorkspaceThatMovedInsideAGroupThatJoinedLateIsNotClosed() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("c", in: "C"), lab.ws("l", in: "L"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("L", own: "l")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.model.workspaceGroups[2].parentGroupId = lab.id("P")
        w.model.tabs.first { $0.id == lab.id("a") }!.groupId = lab.id("L")
        w.model.normalizeWorkspaceGroupContiguity()
        let closed = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(closed == 2)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["c", "p"])
        #expect(w.model.tabs.contains { $0.id == lab.id("a") })
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aGroupThatJoinedLateWithGroupsOfItsOwnKeepsThemAndTakesTheDeletedGroupsParent() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("l", in: "L"), lab.ws("m", in: "M"), lab.ws("m2", in: "M", pinned: true), lab.ws("o", in: "O"), lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("t", in: "O")],
            groups: [lab.group("L", pinned: true, own: "l"), lab.group("M", parent: "L", own: "m"), lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p")]
        )
        #expect(w.compact(lab) == "L*[l: M[m: m2*]] | O[o: P[p: a], t]")
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.model.workspaceGroups[0].parentGroupId = lab.id("P")
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 2)
        #expect(w.compact(lab) == "O[o: L*[l: M[m: m2*]], t]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - The clamp's boundary

    @Test
    func aGroupIndexOnTheLastSlotThatHoldsAGroupInAnotherParentIsRefused() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b"), lab.group("C", parent: "B", own: "c")]
        )
        let before = w.compact(lab)
        #expect(before == "A[a] | B[b: C[c]]")
        // Index 2 is the last slot of the list and holds C, which is inside B: not a group beside A.
        w.groups.moveWorkspaceGroup(groupId: lab.id("A"), toIndex: 2)
        #expect(w.compact(lab) == before)
        // One past the last slot is an index past the end: the nearest slot among the groups beside A.
        w.groups.moveWorkspaceGroup(groupId: lab.id("A"), toIndex: 3)
        #expect(w.compact(lab) == "B[b: C[c]] | A[a]")
    }

    // MARK: - Third round after review: a confirmation taken in a nested window is always pressed nested

    @Test
    func aDeleteAskedWhenNoGroupWasCountedAndPressedAfterTheGroupWasUngroupedClosesNothing() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O"), lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("z")],
            groups: [lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p")]
        )
        #expect(w.compact(lab) == "O[o: P[p: a]] | z")
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(confirmation.containedGroupCount == 0 && confirmation.memberCount == 2)
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("P"))
        #expect(w.compact(lab) == "O[o: p, a] | z")
        #expect(!w.model.hasNestedWorkspaceGroup)
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 0)
        #expect(w.host.closedWorkspaceIds.isEmpty)
        #expect(w.compact(lab) == "O[o: p, a] | z")
    }

    @Test
    func aDeleteAskedWhenNoGroupWasCountedLeavesAWorkspaceThatLeftTheGroupAndTheGroupWentToTheTopLevel() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O"), lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("z")],
            groups: [lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.groups.removeWorkspaceFromGroup(workspaceId: lab.id("a"))
        w.model.workspaceGroups[1].parentGroupId = nil
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(!w.model.hasNestedWorkspaceGroup)
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 1)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["p"])
        #expect(w.model.tabs.contains { $0.id == lab.id("a") })
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aDeleteAskedBesideANestedGroupLeavesAWorkspaceThatLeftWhenThatGroupWasUnNested() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("q", in: "Q"), lab.ws("r", in: "R")],
            groups: [lab.group("P", own: "p"), lab.group("Q", own: "q"), lab.group("R", parent: "Q", own: "r")]
        )
        #expect(w.compact(lab) == "P[p: a] | Q[q: R[r]]")
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.groups.removeWorkspaceFromGroup(workspaceId: lab.id("a"))
        w.model.workspaceGroups[2].parentGroupId = nil
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(!w.model.hasNestedWorkspaceGroup)
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 1)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["p"])
        #expect(w.model.tabs.contains { $0.id == lab.id("a") })
    }

    @Test
    func aConfirmationTakenInAFlatWindowStillRunsUpstreamsCode() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("z")],
            groups: [lab.group("P", own: "p")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 2)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) }.sorted() == ["a", "p"])
        #if DEBUG
        #expect(w.model.nestedGroupTreeBuilds == 0)
        #endif
    }

    // MARK: - The late-group rule more than one level down

    @Test
    func aConfirmedGroupBelowAConfirmedGroupThatMovedInsideALateGroupIsLeftAloneToo() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("c", in: "C"), lab.ws("c2", in: "C"), lab.ws("d", in: "D"), lab.ws("d2", in: "D"), lab.ws("l", in: "L")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("D", parent: "C", own: "d"), lab.group("L", own: "l")]
        )
        #expect(w.compact(lab) == "P[p: a, C[c: c2, D[d: d2]]] | L[l]")
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.model.workspaceGroups[3].parentGroupId = lab.id("P")
        w.model.workspaceGroups[1].parentGroupId = lab.id("L")
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 2)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["a", "p"])
        #expect(w.compact(lab) == "L[l: C[c: c2, D[d: d2]]]")
        #expect(w.violations(lab).isEmpty)
    }

    // MARK: - The count when the host declines to close the group's own workspace

    @Test
    func theReturnedCountLeavesOutAGroupsOwnWorkspaceThatTheHostDidNotClose() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("o", in: "O"), lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("z")],
            groups: [lab.group("O", own: "o"), lab.group("P", parent: "O", own: "p")]
        )
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.host.refusesToClose = [lab.id("p")]
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 1)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["a", "p"])
        #expect(w.model.tabs.contains { $0.id == lab.id("p") })
        #expect(!w.model.workspaceGroups.contains { $0.id == lab.id("P") })
    }

    // MARK: - A header whose group record is already gone

    @Test
    func aHeaderWhoseGroupRecordIsGoneClosesTheHeadersWorkspaceInAFlatWindow() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("x"), lab.ws("y"), lab.ws("g", in: "G")],
            groups: [lab.group("G", own: "g")]
        )
        let gone = UUID()
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: gone, fallbackGroupName: "Gone", fallbackAnchorWorkspaceId: lab.id("x")))
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 1)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["x"])
    }

    @Test
    func aHeaderWhoseGroupRecordIsGoneClosesTheHeadersWorkspaceInANestedWindowToo() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("x"), lab.ws("y"), lab.ws("g", in: "G"), lab.ws("h", in: "H")],
            groups: [lab.group("G", own: "g"), lab.group("H", parent: "G", own: "h")]
        )
        #expect(w.model.hasNestedWorkspaceGroup)
        let gone = UUID()
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: gone, fallbackGroupName: "Gone", fallbackAnchorWorkspaceId: lab.id("x")))
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 1)
        #expect(w.host.closedWorkspaceIds.map { lab.name($0) } == ["x"])
        #expect(w.compact(lab) == "y | G[g: H[h]]")
    }

    @Test
    func aGroupDeletedMeanwhileClosesNothingWhenTheWindowBecameNestedBeforeThePress() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("q", in: "Q"), lab.ws("r", in: "R")],
            groups: [lab.group("P", own: "p"), lab.group("Q", own: "q"), lab.group("R", own: "r")]
        )
        // Asked in a flat window; P is ungrouped, then R goes inside Q, while the question is open.
        let confirmation = try! #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        w.groups.ungroupWorkspaceGroup(groupId: lab.id("P"))
        w.model.workspaceGroups[1].parentGroupId = lab.id("Q")
        w.model.normalizeWorkspaceGroupContiguity()
        #expect(w.model.hasNestedWorkspaceGroup)
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 0)
        #expect(w.host.closedWorkspaceIds.isEmpty)
    }
}
