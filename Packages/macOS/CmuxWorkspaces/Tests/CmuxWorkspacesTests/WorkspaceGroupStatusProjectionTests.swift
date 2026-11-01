import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Whole workspace group status projection")
struct WorkspaceGroupStatusProjectionTests {
    private let list = WorkspaceStatusList(entries: [
        WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "#765432"),
        WorkspaceStatusEntry(id: "doing", name: "Doing", extends: .working, color: "#008800"),
        WorkspaceStatusEntry(id: "uncolored", name: "Uncolored", extends: .todo)
    ], source: .file)

    private func group(status: String? = "parked", parent: UUID? = nil, pinned: Bool = false,
                       color: String? = nil, empty: Bool = false) -> WorkspaceGroup {
        let id = UUID()
        var group = WorkspaceGroup(id: id, name: "Group", isCollapsed: false, isPinned: pinned,
                                   anchor: empty ? .empty(id) : .workspace(UUID()), customColor: color,
                                   iconSymbol: nil, parentGroupId: parent)
        group.statusId = status
        return group
    }

    @Test func topLevelGroupProjectsByItsOwnStatus() {
        let root = group(color: "#123456")
        let result = WorkspaceGroupStatusProjection(groups: [root], list: list)
        #expect(result.statusIdByGroupId == [root.id: "parked"])
        #expect(result.depthById[root.id] == 2)
    }

    @Test func aMatchingColorWithoutStatusDoesNotProject() {
        let root = group(status: nil, color: "#765432")
        let result = WorkspaceGroupStatusProjection(groups: [root], list: list)
        #expect(result.statusIdByGroupId.isEmpty)
        #expect(result.depthById.isEmpty)
    }

    // Superseded on purpose by the 2026-10-23 entry on a nested group under its status and the 2026-10-25 view entry: this test
    // said a nested status stays inside its unstaged parent (`cm-110.2`, 2026-10-20). It is `aNestedStatusInAnUnstagedParent...` below. // (#cm-110.3)
    // The root rule of `cm-110.3` (Decisions, 2026-10-23 and the 2026-10-25 view entry): the outermost group in a chain with
    // its own stored, listed status is the root; a pinned top-level ancestor keeps its whole subtree out. // (#cm-110.3)

    @Test func aNestedStatusInAnUnstagedParentIsTheRootAndTakesItsWholeSubtree() {
        let parent = group(status: nil)
        let child = group(parent: parent.id)
        let inner = group(status: "doing", parent: child.id)
        let member = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: inner.id, isPinned: false)
        let anchor = WorkspaceGroupWorkspaceItem(id: child.anchorWorkspaceId, groupId: child.id, isPinned: false)
        let result = WorkspaceGroupStatusProjection(groups: [parent, child, inner], workspaces: [anchor, member], list: list)
        #expect(result.rootGroupIds == [child.id])
        #expect(result.nestedRootGroupIds == [child.id])
        #expect(result.statusIdByGroupId == [child.id: "parked", inner.id: "parked"])
        #expect(result.rootIdByGroupId == [child.id: child.id, inner.id: child.id])
        #expect(result.statusIdByWorkspaceId == [anchor.id: "parked", member.id: "parked"])
    }

    @Test func aNestedRootRendersAtTheDepthOfATopLevelRoot() {
        let top = group(status: nil), mid = group(status: nil, parent: top.id)
        let root = group(parent: mid.id), inside = group(status: nil, parent: root.id)
        let anchor = WorkspaceGroupWorkspaceItem(id: root.anchorWorkspaceId, groupId: root.id, isPinned: false)
        let member = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: inside.id, isPinned: false)
        let result = WorkspaceGroupStatusProjection(groups: [top, mid, root, inside], workspaces: [anchor, member], list: list)
        #expect(result.depthById[root.id] == 2)
        #expect(result.depthById[inside.id] == 3)
        #expect(result.depthById[anchor.id] == 3)
        #expect(result.depthById[member.id] == 4)
        #expect(result.depthById[top.id] == nil && result.depthById[mid.id] == nil)
    }

    @Test func aParentWithAStatusKeepsItsNestedGroupInsideAndShowsItsOwnStatusOnIt() {
        let parent = group(status: "doing"), child = group(status: "parked", parent: parent.id)
        let result = WorkspaceGroupStatusProjection(groups: [parent, child], list: list)
        #expect(result.rootGroupIds == [parent.id] && result.nestedRootGroupIds.isEmpty, "the parent is a top-level root; nothing is drawn away from it")
        #expect(result.statusIdByGroupId == [parent.id: "doing", child.id: "doing"])
        #expect(result.depthById[child.id] == 3)
    }

    @Test(arguments: [1, 2])
    func aPinnedTopLevelAncestorKeepsEveryNestedStatusAmongPins(_ depth: Int) {
        let top = group(pinned: true)
        var parent = top, groups = [top]
        for _ in 1..<depth { let next = group(status: nil, parent: parent.id); groups.append(next); parent = next }
        let child = group(parent: parent.id)
        groups.append(child)
        let result = WorkspaceGroupStatusProjection(groups: groups, list: list)
        #expect(result.statusIdByGroupId.isEmpty && result.rootGroupIds.isEmpty && result.depthById.isEmpty)
    }

    @Test func aNestedColorWithoutAStoredStatusAndAnUnlistedStatusAreNotRoots() {
        let parent = group(status: nil)
        let colorOnly = group(status: nil, parent: parent.id, color: "#765432")
        let unlisted = group(status: "unlisted", parent: parent.id, color: "#765432")
        #expect(WorkspaceGroupStatusProjection(groups: [parent, colorOnly, unlisted], list: list).statusIdByGroupId.isEmpty)
    }

    @Test func theBuiltInListProjectsNoNestedGroup() {
        let parent = group(status: nil), child = group(status: "done", parent: parent.id)
        #expect(WorkspaceGroupStatusProjection(groups: [parent, child], list: .cmuxFive).rootGroupIds.isEmpty)
    }

    @Test func anEmptyNestedHeaderWithAStatusIsARoot() {
        let parent = group(status: nil), child = group(parent: parent.id, empty: true)
        let result = WorkspaceGroupStatusProjection(groups: [parent, child], list: list)
        #expect(result.nestedRootGroupIds == [child.id] && result.depthById[child.id] == 2)
    }

    @Test func aPinnedRootKeepsItsWholeTreeAmongPins() {
        let root = group(pinned: true)
        let child = group(status: "doing", parent: root.id)
        let member = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: child.id, isPinned: false)
        let result = WorkspaceGroupStatusProjection(groups: [root, child], workspaces: [member], list: list)
        #expect(result.statusIdByGroupId.isEmpty)
        #expect(result.statusIdByWorkspaceId.isEmpty)
    }

    @Test func anUnlistedStatusDoesNotPlaceAGroup() {
        let root = group(status: "unlisted", color: "#765432")
        #expect(WorkspaceGroupStatusProjection(groups: [root], list: list).statusIdByGroupId.isEmpty)
    }

    @Test func descendantsFollowTheRootsPlacementAndAddTwoLevels() {
        let root = group(status: "doing")
        let child = group(parent: root.id)
        let member = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: child.id, isPinned: false)
        let anchor = WorkspaceGroupWorkspaceItem(id: root.anchorWorkspaceId, groupId: root.id, isPinned: false)
        let result = WorkspaceGroupStatusProjection(groups: [root, child], workspaces: [anchor, member], list: list)
        #expect(result.statusIdByGroupId == [root.id: "doing", child.id: "doing"])
        #expect(result.statusIdByWorkspaceId == [anchor.id: "doing", member.id: "doing"])
        #expect(result.depthById[root.id] == 2)
        #expect(result.depthById[child.id] == 3)
        #expect(result.depthById[anchor.id] == 3)
        #expect(result.depthById[member.id] == 4)
    }

    @Test func anEmptyUnpinnedHeaderCanSitUnderItsStatus() {
        let root = group(empty: true)
        let result = WorkspaceGroupStatusProjection(groups: [root], list: list)
        #expect(result.statusIdByGroupId[root.id] == "parked")
        #expect(result.depthById[root.id] == 2)
    }

    @Test func aStatusWithNoColorStillPlacesItsGroup() {
        let root = group(status: "uncolored")
        #expect(WorkspaceGroupStatusProjection(groups: [root], list: list).statusIdByGroupId[root.id] == "uncolored")
    }

    @Test func anUnconfiguredListHasNoGroupPlacement() {
        let root = group(status: "done")
        #expect(WorkspaceGroupStatusProjection(groups: [root], list: .cmuxFive).statusIdByGroupId.isEmpty)
    }

    @Test func unrelatedRowsKeepTheirOriginalDepths() {
        let normal = group(status: nil), projected = group()
        let member = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: normal.id, isPinned: false)
        let loose = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: nil, isPinned: false)
        let result = WorkspaceGroupStatusProjection(groups: [normal, projected], workspaces: [member, loose], list: list)
        #expect(result.depthById[normal.id] == nil)
        #expect(result.depthById[member.id] == nil)
        #expect(result.statusIdByWorkspaceId[loose.id] == nil)
        #expect(result.statusIdByGroupId[projected.id] == "parked")
    }
}
