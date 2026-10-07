import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): a new group made from workspaces that sit in a group lands in that group, in place.
@MainActor
struct WorkspaceGroupNestedCreateInPlaceTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup], selected: String? = nil) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups), selected: selected.map { lab.id($0) })
    }

    private func create(_ w: NestedWorld, _ lab: inout Labels, children: [String]) -> UUID? {
        let id = w.groups.createWorkspaceGroup(name: "N", childWorkspaceIds: children.map { lab.id($0) }, collapseSidebarSelection: false)
        if let id { lab.name(id, as: "N") }
        return id
    }

    @Test
    func twoWorkspacesInAGroupBecomeANewGroupInsideItAtTheFirstOnesPlace() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("x"), lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("b", in: "G"), lab.ws("c", in: "G"), lab.ws("d", in: "G"), lab.ws("y")],
            groups: [lab.group("G", own: "g")]
        )
        #expect(w.compact(lab) == "x | G[g: a, b, c, d] | y")
        let created = create(w, &lab, children: ["b", "c"])
        #expect(created != nil)
        // The new group's own workspace stands behind its name; the nested name n is the generated one.
        #expect(w.window.groups.first { $0.id == created }?.parentId == lab.id("G"))
        #expect(w.violations(lab).isEmpty)
        // b and c are inside the new group, between a and d.
        let order = w.compact(lab)
        #expect(order.hasPrefix("x | G[g: a, N["))
        #expect(order.hasSuffix("], d] | y"))
        #expect(order.contains("b") && order.contains("c"))
        #expect(w.window.tabs.first { $0.id == lab.id("b") }?.groupId == created)
        #expect(w.window.tabs.first { $0.id == lab.id("c") }?.groupId == created)
    }

    @Test
    func upstreamsFirstAssignmentWouldHaveMadeItATopLevelGroupAndThisDoesNot() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("b", in: "G")],
            groups: [lab.group("G", own: "g")]
        )
        // A flat window: the window-wide switch alone would run upstream's code here.
        #expect(!w.model.hasNestedWorkspaceGroup)
        let created = create(w, &lab, children: ["a"])
        #expect(w.window.groups.first { $0.id == created }?.parentId == lab.id("G"))
        #expect(w.model.hasNestedWorkspaceGroup)
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func theFirstEligibleWorkspaceSittingInNoGroupRunsUpstreamsCodeEvenInANestedWindow() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("u"), lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("v")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        )
        let created = create(w, &lab, children: ["u", "v"])
        #expect(w.window.groups.first { $0.id == created }?.parentId == nil)
        #expect(w.window.tabs.first { $0.id == lab.id("u") }?.groupId == created)
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func workspacesFromDifferentGroupsAllMoveIntoTheNewGroupWhichLandsInTheFirstOnesGroup() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("h", in: "H"), lab.ws("b", in: "H"), lab.ws("u")],
            groups: [lab.group("G", own: "g"), lab.group("H", own: "h")]
        )
        let created = create(w, &lab, children: ["b", "a"])
        // The first in sidebar order is a, in G.
        #expect(w.window.groups.first { $0.id == created }?.parentId == lab.id("G"))
        #expect(w.window.tabs.first { $0.id == lab.id("a") }?.groupId == created)
        #expect(w.window.tabs.first { $0.id == lab.id("b") }?.groupId == created)
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aPinnedFirstWorkspaceStillMakesAnUnpinnedGroupThatLandsAmongTheUnpinnedRows() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("p", in: "G", pinned: true), lab.ws("x", in: "G"), lab.ws("y", in: "G")],
            groups: [lab.group("G", own: "g")]
        )
        let created = create(w, &lab, children: ["p", "x"])
        let group = w.window.groups.first { $0.id == created }
        #expect(group?.parentId == lab.id("G"))
        #expect(group?.isPinned == false)
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aNewGroupInsideAFoldedParentOpensItWhenItsOwnWorkspaceIsSelected() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("b", in: "G"), lab.ws("u")],
            groups: [lab.group("G", own: "g")]
        )
        w.model.workspaceGroups[0].isCollapsed = true
        _ = w.groups.createWorkspaceGroup(name: "N", childWorkspaceIds: [lab.id("a")], selectAnchor: true, collapseSidebarSelection: false)
        #expect(w.model.workspaceGroups.first { $0.id == lab.id("G") }?.isCollapsed == false)
    }

    @Test
    func theGroupAlreadyHasItsOwnWorkspaceWhenItIsPlacedSoItIsNotSnappedToTheRuleFourPlace() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("g", in: "G"), lab.ws("a", in: "G"), lab.ws("z", in: "G"), lab.ws("b", in: "G")],
            groups: [lab.group("G", own: "g")]
        )
        let created = create(w, &lab, children: ["z"])
        let newGroup = w.window.groups.first { $0.id == created }
        #expect(newGroup?.anchorWorkspaceId != nil)
        // z sat between a and b; the new group sits there, not last among G's groups.
        let order = w.compact(lab)
        #expect(order.hasPrefix("G[g: a, N["))
        #expect(order.hasSuffix("], b]"))
    }
}
