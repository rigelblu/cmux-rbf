import Foundation
import Testing
@testable import CmuxWorkspaces

// `cm-110.3`: folding the parent of a group the sidebar draws under a status. The model has no status list, so the app
// hands it the groups shown under a status (`groupIdsShownOutsideParent`); empty is "as today". Decisions, 2026-10-24
// rulings (7), and the 2026-10-25 rulings (21) to (23).
@MainActor
struct WorkspaceGroupNestedShownUnderStatusTests {
    /// u | P[p, a, Q[q, n1, M[m, m1], n2], c] | v, with the groups in `folded` folded and the groups in `shown` drawn under a status.
    private func world(_ lab: inout Labels, selected: String?, folded: Set<String> = [], shown: Set<String>) -> NestedWorld {
        let window = NestWindow(
            tabs: [lab.ws("u"), lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("q", in: "Q"), lab.ws("n1", in: "Q"),
                   lab.ws("m", in: "M"), lab.ws("m1", in: "M"), lab.ws("n2", in: "Q"), lab.ws("c", in: "P"), lab.ws("v")],
            groups: [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q"), lab.group("M", parent: "Q", own: "m")]
        )
        let world = NestedWorld(window, selected: selected.map { lab.id($0) })
        for name in folded {
            if let index = world.model.workspaceGroups.firstIndex(where: { $0.id == lab.id(name) }) {
                world.model.workspaceGroups[index].isCollapsed = true
            }
        }
        let ids = Set(shown.map { lab.id($0) })
        world.model.groupIdsShownOutsideParent = { ids }
        return world
    }

    private func isFolded(_ world: NestedWorld, _ lab: Labels, _ name: String) -> Bool {
        var lab = lab
        let id = lab.id(name)
        return world.model.workspaceGroups.first { $0.id == id }?.isCollapsed == true
    }

    @Test(arguments: ["n1", "q", "m1"])
    func selectingARowInsideAShownRootLeavesTheFoldedParentFolded(_ selected: String) {
        var lab = Labels()
        let w = world(&lab, selected: selected, folded: ["P"], shown: ["Q"])
        w.model.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(isFolded(w, lab, "P"), "the parent's fold does not hide the root, so it is not opened (ruling (22))")
        #expect(!isFolded(w, lab, "Q"))
        // Without the set, the selection opens the parent, as it always has.
        var control = Labels()
        let c = world(&control, selected: selected, folded: ["P"], shown: [])
        c.model.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(!isFolded(c, control, "P"))
    }

    @Test
    func selectingARowBelowAFoldedGroupInsideTheRootOpensDownToTheRootAndNoFurther() {
        var lab = Labels()
        let w = world(&lab, selected: "m1", folded: ["P", "Q", "M"], shown: ["Q"])
        w.model.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(!isFolded(w, lab, "M") && !isFolded(w, lab, "Q"))
        #expect(isFolded(w, lab, "P"))
    }

    @Test
    func theRootsOwnWorkspaceKeepsTheRootAsItIsAndStillLeavesTheParentAlone() {
        var lab = Labels()
        let w = world(&lab, selected: "q", folded: ["P", "Q"], shown: ["Q"])
        w.model.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(isFolded(w, lab, "Q"), "the root's own workspace is its header: its fold stays")
        #expect(isFolded(w, lab, "P"))
    }

    @Test
    func aSelectionOutsideTheRootStillOpensItsParentsAsToday() {
        var lab = Labels()
        let w = world(&lab, selected: "a", folded: ["P"], shown: ["Q"])
        w.model.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(!isFolded(w, lab, "P"))
    }

    @Test
    func foldingTheParentLeavesTheSelectionAndTheMultiSelectionInsideTheShownRoot() {
        var lab = Labels()
        let w = world(&lab, selected: "n1", shown: ["Q"])
        w.host.sidebarSelectedWorkspaceIds = [lab.id("n1"), lab.id("m1"), lab.id("a")]
        w.groups.toggleWorkspaceGroupCollapsed(groupId: lab.id("P"))
        #expect(isFolded(w, lab, "P"))
        #expect(w.model.selectedTabId == lab.id("n1"))
        #expect(w.host.selectedWorkspaceIds.isEmpty)
        #expect(w.host.sidebarSelectedWorkspaceIds == [lab.id("n1"), lab.id("m1")], "only the row P hides leaves the multi-selection")
        // Without the set the fold takes the selection to P's own workspace, as it always has.
        var control = Labels()
        let c = world(&control, selected: "n1", shown: [])
        c.groups.toggleWorkspaceGroupCollapsed(groupId: control.id("P"))
        #expect(c.model.selectedTabId == control.id("p"))
    }

    @Test
    func aSelectionTheParentHidesStillMovesToItsOwnWorkspace() {
        var lab = Labels()
        let w = world(&lab, selected: "a", shown: ["Q"])
        w.groups.toggleWorkspaceGroupCollapsed(groupId: lab.id("P"))
        #expect(w.model.selectedTabId == lab.id("p"))
    }

    @Test
    func foldingTheRootItselfHidesItsRowsAndMovesTheSelectionToItsOwnWorkspace() {
        var lab = Labels()
        let w = world(&lab, selected: "m1", shown: ["Q"])
        w.groups.toggleWorkspaceGroupCollapsed(groupId: lab.id("Q"))
        #expect(isFolded(w, lab, "Q"))
        #expect(w.model.selectedTabId == lab.id("q"))
    }

    @Test
    func foldingAGroupBetweenTheParentAndTheRootKeepsTheRootShown() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "A"), lab.ws("q", in: "Q"), lab.ws("n1", in: "Q")],
            groups: [lab.group("P", own: "p"), lab.group("A", parent: "P", own: "a"), lab.group("Q", parent: "A", own: "q")]
        )
        let w = NestedWorld(window, selected: lab.id("n1"))
        let shown: Set<UUID> = [lab.id("Q")]
        w.model.groupIdsShownOutsideParent = { shown }
        w.groups.toggleWorkspaceGroupCollapsed(groupId: lab.id("A"))
        #expect(w.model.selectedTabId == lab.id("n1"))
    }

    // MARK: a group leaving its status (ruling (27))

    /// The app's own rule in miniature: a group is shown under a status exactly while it holds a stored status.
    private func worldWhereAStatusShowsQ(_ lab: inout Labels, selected: String?, folded: Set<String>) -> NestedWorld {
        let w = world(&lab, selected: selected, folded: folded, shown: [])
        let q = lab.id("Q")
        if let index = w.model.workspaceGroups.firstIndex(where: { $0.id == q }) { w.model.workspaceGroups[index].statusId = "s" }
        let model = w.model
        w.model.groupIdsShownOutsideParent = { model.workspaceGroups.contains { $0.id == q && $0.statusId != nil } ? [q] : [] }
        return w
    }

    private let writer = WorkspaceGroupStatusActions(list: .cmuxFive, resolveColor: { _ in nil })

    /// The Status menu's None and Auto, the group-color clear, and a restore all write the group; each must bring the selected
    /// row back out of the folded parent that the status had been keeping it out of.
    @Test(arguments: ["none", "auto", "color", "restore"])
    func aGroupLeavingItsStatusWhileTheSelectionIsInsideItUnfoldsTheFoldedGroupsAbove(_ how: String) {
        var lab = Labels()
        let w = worldWhereAStatusShowsQ(&lab, selected: "n1", folded: ["P"])
        let q = lab.id("Q")
        switch how {
        case "none": #expect(w.groups.setWorkspaceGroupStatus(groupId: q, action: .hide, actions: writer))
        case "auto": #expect(w.groups.setWorkspaceGroupStatus(groupId: q, action: .auto, actions: writer))
        case "color": w.groups.setWorkspaceGroupColor(groupId: q, hex: nil)
        default: w.groups.restoreWorkspaceGroupStatus(groupId: q, statusId: nil, hex: nil)
        }
        #expect(!isFolded(w, lab, "P"), "the selected row n1 is hidden by P's fold once Q is back inside P: P unfolds")
        #expect(w.model.selectedTabId == lab.id("n1"))
    }

    @Test
    func aStatusChangeThatKeepsTheGroupShownLeavesTheFoldAlone() {
        var lab = Labels()
        let w = worldWhereAStatusShowsQ(&lab, selected: "n1", folded: ["P"])
        #expect(w.groups.setWorkspaceGroupStatus(groupId: lab.id("Q"), action: .status(id: "done"), actions: writer))
        #expect(isFolded(w, lab, "P"), "still drawn under a status, so still not hidden by P")
    }

    @Test(arguments: ["v", "a"])
    func aGroupLeavingItsStatusWhileTheSelectionIsElsewhereLeavesTheFoldAlone(_ selected: String) {
        var lab = Labels()
        // v is outside every group; a sits in P directly, not inside Q: Q leaving its status hides nothing the selection needs.
        let w = worldWhereAStatusShowsQ(&lab, selected: selected, folded: ["P"])
        #expect(w.groups.setWorkspaceGroupStatus(groupId: lab.id("Q"), action: .hide, actions: writer))
        #expect(isFolded(w, lab, "P"))
    }

    @Test
    func theRootsOwnWorkspaceSelectedIsRevealedToo() {
        var lab = Labels()
        let w = worldWhereAStatusShowsQ(&lab, selected: "q", folded: ["P"])
        #expect(w.groups.setWorkspaceGroupStatus(groupId: lab.id("Q"), action: .hide, actions: writer))
        #expect(!isFolded(w, lab, "P"))
    }
}
