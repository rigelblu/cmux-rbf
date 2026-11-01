import Foundation
import Testing
@testable import CmuxWorkspaces

struct WorkspaceSidebarPinTests {
    enum PlacementCase: CaseIterable, Sendable {
        case loosePin, groupedPin, nestedPin, anchorPin, nestedPinnedGroupMember, rootPinnedGroupMember, noSectionsGroupedPin, ordinary
    }

    @Test(arguments: PlacementCase.allCases)
    func sharedAnswerKeepsPinsAnchorsAndPinnedAncestorsInTheirDecidedSections(_ kind: PlacementCase) {
        let own = UUID(), member = UUID()
        let parent = WorkspaceGroup(id: UUID(), name: "Parent", isCollapsed: false, isPinned: kind == .rootPinnedGroupMember,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil)
        let nested = kind == .nestedPin || kind == .nestedPinnedGroupMember || kind == .rootPinnedGroupMember
        let group = WorkspaceGroup(id: UUID(), name: "Group", isCollapsed: false, isPinned: kind == .nestedPinnedGroupMember,
            anchorWorkspaceId: own, customColor: nil, iconSymbol: nil, parentGroupId: nested ? parent.id : nil)
        let groups = Dictionary(uniqueKeysWithValues: [parent, group].map { ($0.id, $0) })
        let workspace = WorkspaceGroupWorkspaceItem(id: kind == .anchorPin ? own : member,
            groupId: kind == .loosePin ? nil : group.id, isPinned: kind != .ordinary)
        let actual = workspace.sidebarPin(in: groups, sectionsShown: kind != .noSectionsGroupedPin)
        let expectedPinned = kind == .loosePin || kind == .groupedPin || kind == .nestedPin || kind == .rootPinnedGroupMember || kind == .nestedPinnedGroupMember
        let expectedOutside = kind == .groupedPin || kind == .nestedPin
        #expect(actual.isPinned == expectedPinned)
        #expect(actual.isOutsideGroup == expectedOutside)
    }
}

@Suite("Nested pinned group placement")
struct WorkspaceNestedPinnedGroupTests {
    @Test(arguments: [false, true])
    func aNestedPinnedGroupHoldsItsOrdinaryAndOwnPinnedMembers(_ ownPin: Bool) {
        let parent = WorkspaceGroup(id: UUID(), name: "Parent", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil)
        let child = WorkspaceGroup(id: UUID(), name: "Child", isCollapsed: false, isPinned: true,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil, parentGroupId: parent.id)
        let groups = Dictionary(uniqueKeysWithValues: [parent, child].map { ($0.id, $0) })
        let member = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: child.id, isPinned: ownPin)
        #expect(member.sidebarPin(in: groups, sectionsShown: true).isPinned, "a nested pinned group's member is drawn in Pinned")
        #expect(!member.sidebarPin(in: groups, sectionsShown: true).isOutsideGroup, "the member stays with its pinned group")
        #expect(!member.sidebarPin(in: groups, sectionsShown: false).isPinned, "without sections it keeps the parent's tier")
        let header = WorkspaceGroupWorkspaceItem(id: child.anchorWorkspaceId, groupId: child.id, isPinned: false)
        #expect(header.sidebarPin(in: groups, sectionsShown: true).isPinned, "the nested pinned group's header is drawn in Pinned")
    }

    @Test(arguments: [false, true])
    func aPinnedBranchLeavesItsParentsStatusEvenWhenTheParentHasOne(_ ownStatus: Bool) {
        var parent = WorkspaceGroup(id: UUID(), name: "Parent", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil)
        parent.statusId = "parked"
        var child = WorkspaceGroup(id: UUID(), name: "Child", isCollapsed: false, isPinned: true,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil, parentGroupId: parent.id)
        child.statusId = ownStatus ? "parked" : nil
        let inner = WorkspaceGroup(id: UUID(), name: "Inner", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil, parentGroupId: child.id)
        let member = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: inner.id, isPinned: false)
        let list = WorkspaceStatusList(entries: [.init(id: "parked", name: "Parked", extends: .todo)], source: .file)
        let projection = WorkspaceGroupStatusProjection(groups: [parent, child, inner], workspaces: [member], list: list)
        #expect(projection.statusIdByGroupId == [parent.id: "parked"], "Pinned excludes the child and its whole branch from Parked")
        #expect(projection.statusIdByWorkspaceId[member.id] == nil)
        #expect(projection.rootIdByGroupId[child.id] == nil && projection.rootIdByGroupId[inner.id] == nil)
        #expect(projection.depthById[child.id] == nil && projection.depthById[member.id] == nil)
    }
}

extension WorkspaceNestedPinnedGroupTests {
    @Test(arguments: [false, true])
    func nestedPinnedGroupsUseTheOutermostPinnedRoot(_ ownPin: Bool) {
        let top = WorkspaceGroup(id: UUID(), name: "Top", isCollapsed: false, isPinned: true,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil)
        let inner = WorkspaceGroup(id: UUID(), name: "Inner", isCollapsed: false, isPinned: true,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil, parentGroupId: top.id)
        let leaf = WorkspaceGroup(id: UUID(), name: "Leaf", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil, parentGroupId: inner.id)
        let groups = Dictionary(uniqueKeysWithValues: [top, inner, leaf].map { ($0.id, $0) })
        let pin = WorkspaceGroupWorkspaceItem(id: UUID(), groupId: leaf.id, isPinned: ownPin).sidebarPin(in: groups, sectionsShown: true)
        #expect(pin.isPinned && !pin.isOutsideGroup)
        #expect(pin.pinRootGroupId == top.id)
    }
}

struct WorkspaceSidebarSectionVisibilityTests {
    @Test(arguments: [false, true], ["builtin", "empty", "listed"])
    func theSectionGateRequiresControlsAndANonemptyFileList(_ controls: Bool, _ mode: String) {
        let entries = mode == "empty" ? [] : [WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo)]
        let list = WorkspaceStatusList(entries: entries, source: mode == "builtin" ? .cmux : .file)
        #expect(WorkspaceStatusGroupProjection.showsSections(list: list, controlsEnabled: controls) == (controls && mode == "listed"))
    }
}
