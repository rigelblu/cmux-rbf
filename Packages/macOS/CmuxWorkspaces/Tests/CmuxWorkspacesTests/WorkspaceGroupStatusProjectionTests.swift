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

    @Test func aNestedStatusStaysInsideItsUnstagedParent() {
        let root = group(status: nil)
        let child = group(parent: root.id)
        let result = WorkspaceGroupStatusProjection(groups: [root, child], list: list)
        #expect(result.statusIdByGroupId.isEmpty)
        #expect(result.depthById.isEmpty)
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
        let member = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: child.id, isPinned: true)
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
