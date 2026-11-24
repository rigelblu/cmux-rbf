import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): `createWorkspaceGroup` places a group made from grouped workspaces in place
// (`nestedPlaceNewWorkspaceGroup`) and then runs upstream's assignment and placement lines, with a comment saying they
// "then change nothing". These tests pin that sentence: the window after the whole call equals the window right
// after the nested placement, built by hand with the same first steps.
@MainActor
struct WorkspaceGroupNestedCreateUpstreamLinesTests {
    private struct Case {
        var name: String
        var tabs: [String]            // "name" or "name@Group"
        var groups: [(name: String, parent: String?, own: String)]
        var eligible: [String]
    }

    private func window(_ c: Case, _ lab: inout Labels) -> NestWindow {
        NestWindow(
            tabs: c.tabs.map { entry in
                let parts = entry.split(separator: "@").map(String.init)
                return lab.ws(parts[0], in: parts.count > 1 ? parts[1] : nil)
            },
            groups: c.groups.map { lab.group($0.name, parent: $0.parent, own: $0.own) }
        )
    }

    private func check(_ c: Case) {
        var lab = Labels()
        let start = window(c, &lab)
        let eligible = c.eligible.map { lab.id($0) }

        // The whole call.
        let whole = NestedWorld(start)
        var wholeLab = lab
        let groupId = whole.groups.createWorkspaceGroup(name: "N", childWorkspaceIds: eligible, collapseSidebarSelection: false)
        let created = try! #require(groupId)
        wholeLab.name(created, as: "N")
        wholeLab.name(whole.model.workspaceGroups.first { $0.id == created }!.anchorWorkspaceId, as: "n")

        // Only what comes before upstream's lines: the group stored, then the nested placement.
        // cmux-rbf: changed on purpose (#cm-142.1): built the way createWorkspaceGroup now builds it. Upstream's #15892 makes
        // the first chosen workspace the anchor (provenance `.user`) with no generated workspace and no groupId set before
        // the placement; this used to build a generated anchor first, as the fork's base did.
        let placed = NestedWorld(start)
        var placedLab = lab
        let anchorId = eligible[0]
        let group = WorkspaceGroup(
            id: UUID(), name: "N", isCollapsed: false, isPinned: false, anchorWorkspaceId: anchorId,
            customColor: nil, iconSymbol: nil, externalID: nil, anchorWorkspaceProvenance: .user
        )
        placed.model.workspaceGroups.append(group)
        #expect(placed.groups.nestedPlaceNewWorkspaceGroup(groupId: group.id, anchorId: anchorId, eligibleChildren: eligible), "\(c.name): the nested placement ran")
        placedLab.name(group.id, as: "N")
        placedLab.name(anchorId, as: "n")

        #expect(whole.compact(wholeLab) == placed.compact(placedLab), "\(c.name): upstream's lines after the nested placement changed the window")
        #expect(whole.window.tabs.map { $0.groupId.map { wholeLab.name($0) } } == placed.window.tabs.map { $0.groupId.map { placedLab.name($0) } }, "\(c.name): group of each workspace")
        #expect(whole.window.groups.map { wholeLab.name($0.id) } == placed.window.groups.map { placedLab.name($0.id) }, "\(c.name): order of groups")
        #expect(whole.violations(wholeLab).isEmpty, "\(c.name): \(whole.violations(wholeLab))")
    }

    @Test
    func aGroupMadeFromWorkspacesOfAParentInANestedWindowIsTheSameBeforeAndAfterUpstreamsLines() {
        check(Case(
            name: "inside P",
            tabs: ["p@P", "x@P", "c@C", "c2@C", "y@P", "z"],
            groups: [("P", nil, "p"), ("C", "P", "c")],
            eligible: ["x", "y"]
        ))
    }

    @Test
    func aGroupWhoseFirstWorkspaceSitsInAChildGroupLandsInTheChildAndIsTheSameBeforeAndAfter() {
        check(Case(
            name: "inside C",
            tabs: ["p@P", "c@C", "c2@C", "c3@C", "x@P", "z"],
            groups: [("P", nil, "p"), ("C", "P", "c")],
            eligible: ["c2", "x"]
        ))
    }

    @Test
    func theFirstGroupInsideAGroupOfAFlatWindowIsTheSameBeforeAndAfterUpstreamsLines() {
        check(Case(
            name: "first nested group",
            tabs: ["p@P", "x@P", "y@P", "z"],
            groups: [("P", nil, "p")],
            eligible: ["x", "z"]
        ))
    }
}
