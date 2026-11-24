import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106) meeting upstream code new in the 2026-11 sync (cm-142.1). Each case below is a path
// upstream wrote for one level of groups that a nested group can reach: P1 the selection after a close, P6 the
// generated-anchor cleanup on add and remove, P7 Delete Group's closed count. Each was run red on the unfixed tip first.
@MainActor
struct WorkspaceGroupNestedSyncGapTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup], selected: String? = nil) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups), selected: selected.map { lab.id($0) })
    }

    private func setCollapsed(_ w: NestedWorld, _ groupId: UUID, _ collapsed: Bool) {
        guard let index = w.model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        w.model.workspaceGroups[index].isCollapsed = collapsed
    }

    /// Marks a group's own workspace as one cmux generated and the user never touched.
    private func makeGenerated(_ w: NestedWorld, group groupId: UUID, own ownId: UUID) {
        guard let index = w.model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        w.model.workspaceGroups[index].anchorWorkspaceProvenance = .generated
        w.host.untouchedGeneratedAnchors.insert(ownId)
    }

    /// Closes a workspace the way `TabManager.closeWorkspace` does before it asks for the next selection: removed
    /// from `tabs`, then the group fix-up. Returns the index it stood at.
    private func close(_ w: NestedWorld, _ workspaceId: UUID) -> Int? {
        guard let index = w.model.tabs.firstIndex(where: { $0.id == workspaceId }) else { return nil }
        w.model.tabs.remove(at: index)
        w.model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: workspaceId)
        return index
    }

    // MARK: - P1: the selection after a close

    @Test
    // P[p: y, C[c: x]] | z with P folded and C open: closing z leaves x in its slot, a workspace in an open child of a
    // folded parent; selecting it would unfold P.
    func closingTheRowBelowAFoldedParentSelectsTheParentNotAWorkspaceInsideIt() throws {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("y", in: "P"), lab.ws("c", in: "C"), lab.ws("x", in: "C"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")],
            selected: "z"
        )
        let parentId = lab.id("P")
        setCollapsed(w, parentId, true)
        let index = try #require(close(w, lab.id("z")))
        let target = try #require(w.model.selectionTargetAfterClose(closedIndex: index))
        #expect(lab.name(target) == "p", "the folded parent's own workspace is the row the sidebar draws")
        w.model.selectedTabId = target
        w.model.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(w.model.workspaceGroups.first { $0.id == parentId }?.isCollapsed == true, "the parent the user folded stays folded")
    }

    @Test
    func closingTheRowBelowTwoFoldedGroupsSelectsTheOutermost() throws {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("x", in: "C"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")],
            selected: "z"
        )
        setCollapsed(w, lab.id("P"), true)
        setCollapsed(w, lab.id("C"), true)
        let index = try #require(close(w, lab.id("z")))
        let target = try #require(w.model.selectionTargetAfterClose(closedIndex: index))
        #expect(lab.name(target) == "p")
    }

    // Control: only the child is folded, so its own workspace is the row drawn; passes before and after the fix.
    @Test
    func closingTheRowBelowAFoldedChildInsideAnOpenParentSelectsTheChild() throws {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("x", in: "C"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")],
            selected: "z"
        )
        setCollapsed(w, lab.id("C"), true)
        let index = try #require(close(w, lab.id("z")))
        let target = try #require(w.model.selectionTargetAfterClose(closedIndex: index))
        #expect(lab.name(target) == "c")
    }

    // D2 (review-b): a fold above a row the sidebar draws outside its parent does not hide it. Both projections are set as
    // the app sets them (Sources/TabManager.swift:757-764). P[p: y, C[c: x]] | z with P folded and C open: closing z leaves
    // x in the slot. Red on 1c6a3083da1c in all three cases: the walk read P's fold and answered p.
    enum DrawnElsewhere: CaseIterable { case childUnderAStatus, childInPinned, workspaceInPinned }

    @Test(arguments: DrawnElsewhere.allCases)
    func closingTheRowBelowARowDrawnOutsideItsFoldedParentSelectsThatRow(_ how: DrawnElsewhere) throws {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("y", in: "P"), lab.ws("c", in: "C"),
                   lab.ws("x", in: "C", pinned: how == .workspaceInPinned), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")],
            selected: "z"
        )
        let parentId = lab.id("P"), childId = lab.id("C"), x = lab.id("x")
        setCollapsed(w, parentId, true)
        let child = try #require(w.model.workspaceGroups.firstIndex { $0.id == childId })
        switch how {
        case .childUnderAStatus: w.model.workspaceGroups[child].statusId = "parked"
        case .childInPinned: w.model.workspaceGroups[child].isPinned = true
        case .workspaceInPinned: break
        }
        w.model.groupIdsShownOutsideParent = { how == .workspaceInPinned ? [] : [childId] }
        w.model.workspaceIdsShownInPinned = { how == .workspaceInPinned ? [x] : [] }
        let index = try #require(close(w, lab.id("z")))
        let target = try #require(w.model.selectionTargetAfterClose(closedIndex: index))
        #expect(lab.name(target) == "x", "x is drawn outside P's fold (\(how)), so it is the row in the slot")
        w.model.selectedTabId = target
        w.model.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(w.model.workspaceGroups.first { $0.id == parentId }?.isCollapsed == true, "the parent the user folded stays folded")
    }

    // MARK: - P6: upstream's generated-anchor cleanup on the nested add and remove

    private func windowWithAGeneratedGroup(_ lab: inout Labels) -> NestedWorld {
        let w = world(
            &lab,
            tabs: [lab.ws("q", in: "Q"), lab.ws("r", in: "R"), lab.ws("e", in: "E"), lab.ws("m", in: "E"), lab.ws("u")],
            groups: [lab.group("Q", own: "q"), lab.group("R", parent: "Q", own: "r"), lab.group("E", own: "e")]
        )
        makeGenerated(w, group: lab.id("E"), own: lab.id("e"))
        return w
    }

    @Test
    func removingTheLastRealWorkspaceRemovesTheGeneratedGroupInANestedWindow() {
        var lab = Labels()
        let w = windowWithAGeneratedGroup(&lab)
        #expect(w.model.hasNestedWorkspaceGroup, "control: the window holds a nested group")
        w.groups.removeWorkspaceFromGroup(workspaceId: lab.id("m"))
        #expect(!w.model.workspaceGroups.contains { $0.id == lab.id("E") }, "the generated group goes with its last real workspace: \(w.compact(lab))")
        #expect(!w.model.tabs.contains { $0.id == lab.id("e") }, "its untouched generated workspace closes")
        #expect(w.violations(lab).isEmpty, "\(w.violations(lab))")
    }

    @Test
    func movingTheLastRealWorkspaceAwayRemovesTheGeneratedGroupInANestedWindow() {
        var lab = Labels()
        let w = windowWithAGeneratedGroup(&lab)
        w.groups.addWorkspaceToGroup(workspaceId: lab.id("m"), groupId: lab.id("Q"))
        #expect(w.model.tabs.first { $0.id == lab.id("m") }?.groupId == lab.id("Q"), "control: the move happened")
        #expect(!w.model.workspaceGroups.contains { $0.id == lab.id("E") }, "the generated group goes with its last real workspace: \(w.compact(lab))")
        #expect(!w.model.tabs.contains { $0.id == lab.id("e") })
        #expect(w.violations(lab).isEmpty, "\(w.violations(lab))")
    }

    // Control: a generated group that holds a group keeps its header (the cleanup's #cm-106 refusal); same before and after.
    @Test
    func aGeneratedGroupThatHoldsAGroupKeepsItsHeaderWhenItsLastWorkspaceLeaves() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("e", in: "E"), lab.ws("k", in: "K"), lab.ws("m", in: "E"), lab.ws("u")],
            groups: [lab.group("E", own: "e"), lab.group("K", parent: "E", own: "k")]
        )
        makeGenerated(w, group: lab.id("E"), own: lab.id("e"))
        w.groups.removeWorkspaceFromGroup(workspaceId: lab.id("m"))
        #expect(w.model.workspaceGroups.contains { $0.id == lab.id("E") })
        #expect(w.model.tabs.contains { $0.id == lab.id("e") })
    }

    // MARK: - P7: Delete Group's closed count

    @Test
    func deletingAGroupCountsAnInsideGroupsGeneratedWorkspace() throws {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("g", in: "C"), lab.ws("x", in: "C"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "g")]
        )
        makeGenerated(w, group: lab.id("C"), own: lab.id("g"))
        let confirmation = try #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(Set(confirmation.memberWorkspaceIds) == Set(["p", "g", "x"].map { lab.id($0) }), "control: the question names all three")
        let closed = w.groups.deleteWorkspaceGroup(confirmed: confirmation)
        #expect(closed == 3, "every confirmed workspace closed, so the count is 3; host closed \(w.host.closedWorkspaceIds.map { lab.name($0) })")
        #expect(w.model.tabs.map { lab.name($0.id) } == ["z"])
    }

    // Control: the inside group's own workspace is the user's, so no cleanup can take it; 3 before and after.
    @Test
    func deletingAGroupCountsEveryWorkspaceWhenNoneIsGenerated() throws {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("g", in: "C"), lab.ws("x", in: "C"), lab.ws("z")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "g")]
        )
        let confirmation = try #require(w.groups.deletionConfirmation(groupId: lab.id("P")))
        #expect(w.groups.deleteWorkspaceGroup(confirmed: confirmation) == 3)
    }
}
