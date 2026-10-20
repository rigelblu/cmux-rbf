import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
@Suite("Group status coordinator")
struct WorkspaceGroupStatusCoordinatorTests {
    private var actions: WorkspaceGroupStatusActions {
        WorkspaceGroupStatusActions(list: WorkspaceStatusList(entries: [
            WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "Brown")
        ], source: .file), resolveColor: { _ in "#765432" })
    }

    private func world() -> (NestedWorld, UUID, UUID) {
        var lab = Labels()
        let world = NestedWorld(NestWindow(tabs: [lab.ws("a", in: "G"), lab.ws("b", in: "G"), lab.ws("u")],
                                          groups: [lab.group("G", own: "a")]), selected: lab.id("u"))
        return (world, lab.id("G"), lab.id("a"))
    }

    @Test func statusDoesNotMutateMembersSelectionOrOrder() throws {
        let (world, id, _) = world()
        let before = world.model.tabs.map { ($0.id, $0.groupId, $0.isPinned) }
        let selected = world.model.selectedTabId
        #expect(world.groups.setWorkspaceGroupStatus(groupId: id, action: .status(id: "parked"), actions: actions))
        let group = try #require(world.model.workspaceGroups.first)
        #expect(group.statusId == "parked")
        #expect(group.customColor == "#765432")
        #expect(world.model.tabs.map(\.id) == before.map(\.0))
        #expect(world.model.tabs.map(\.groupId) == before.map(\.1))
        #expect(world.model.tabs.map(\.isPinned) == before.map(\.2))
        #expect(world.model.selectedTabId == selected)
        #expect(world.host.orderChanges.isEmpty)
    }

    @Test func statusSurvivesClosingAnchor() throws {
        let (world, id, anchor) = world()
        world.groups.setWorkspaceGroupStatus(groupId: id, action: .status(id: "parked"), actions: actions)
        let tab = try #require(world.model.tabs.first { $0.id == anchor })
        world.host.closeWorkspaceForGroupDeletion(tab, recordHistory: false)
        let group = try #require(world.model.workspaceGroups.first)
        #expect(group.liveAnchorWorkspaceId != anchor)
        #expect(group.statusId == "parked")
        #expect(group.customColor == "#765432")
    }

    @Test func snapshotRestoreDoesNotReinterpretColorAsPick() throws {
        let (world, id, _) = world()
        world.groups.restoreWorkspaceGroupStatus(groupId: id, statusId: "unlisted", hex: "#765432")
        #expect(world.model.workspaceGroups.first?.statusId == "unlisted")
        #expect(world.model.workspaceGroups.first?.customColor == "#765432")
        world.groups.restoreWorkspaceGroupStatus(groupId: id, statusId: nil, hex: "#123456")
        #expect(world.model.workspaceGroups.first?.statusId == nil)
        #expect(world.model.workspaceGroups.first?.customColor == "#123456")
    }

    @Test func missingGroupIsRefused() {
        let (world, _, _) = world()
        #expect(!world.groups.setWorkspaceGroupStatus(groupId: UUID(), action: .done, actions: actions))
    }

    @Test(arguments: ["Brown", "#12345", "#GG1122", "12abcf0"])
    func malformedColorLeavesTheStoredPairAndMembersUnchanged(_ hex: String) {
        let (world, id, _) = world()
        world.groups.restoreWorkspaceGroupStatus(groupId: id, statusId: "parked", hex: "#765432")
        let before = world.model.workspaceGroups
        let order = world.model.tabs.map(\.id)
        world.groups.setWorkspaceGroupColor(groupId: id, hex: hex)
        #expect(world.model.workspaceGroups == before)
        #expect(world.model.tabs.map(\.id) == order)
    }
}
