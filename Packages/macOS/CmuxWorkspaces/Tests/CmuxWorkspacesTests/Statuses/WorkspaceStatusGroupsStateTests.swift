import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite struct WorkspaceStatusGroupsStateTests {
    struct SeedCase: Sendable {
        let id: String
        let folded: Bool
    }

    private static let list = WorkspaceStatusList(entries: [
        WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo),
        WorkspaceStatusEntry(id: "done", name: "Done"),
        WorkspaceStatusEntry(id: "next", name: "Next", extends: .todo),
        WorkspaceStatusEntry(id: "plain", name: "Plain", extends: .todo),
    ], source: .file)

    @Test(arguments: [
        SeedCase(id: "parked", folded: true), SeedCase(id: "done", folded: true),
        SeedCase(id: "next", folded: false), SeedCase(id: "plain", folded: false),
    ])
    func theFirstCopyUsesEachStatusesResolvedColor(_ row: SeedCase) {
        let state = WorkspaceStatusGroupsState.seeded(
            list: Self.list,
            resolvedHexByStatusId: ["parked": "aabbcc", "done": "#AABBCC", "next": "#112233"],
            collapsedColorHexes: ["#aabbcc"]
        )
        #expect(state.collapsedStatusIds.contains(row.id) == row.folded)
    }

    @Test func aNewWindowStartsWithEveryGroupAndTheAreaOpen() {
        let state = WorkspaceStatusGroupsState()
        #expect(!state.areaCollapsed)
        #expect(state.collapsedStatusIds.isEmpty)
    }

    @Test(arguments: [false, true])
    func aStatusToggleWorksInBothDirections(_ initiallyFolded: Bool) {
        var state = WorkspaceStatusGroupsState(collapsedStatusIds: initiallyFolded ? ["parked"] : [])
        state.toggleStatus(id: "parked")
        #expect(state.collapsedStatusIds.contains("parked") == !initiallyFolded)
    }

    @Test(arguments: [false, true])
    func theAreaToggleWorksInBothDirections(_ initiallyFolded: Bool) {
        var state = WorkspaceStatusGroupsState(areaCollapsed: initiallyFolded)
        state.toggleArea()
        #expect(state.areaCollapsed == !initiallyFolded)
    }

    @Test func aFoldForAnAbsentStatusSurvivesChangesToOtherGroups() {
        var state = WorkspaceStatusGroupsState(collapsedStatusIds: ["no-longer-listed"])
        state.toggleStatus(id: "done")
        #expect(state.collapsedStatusIds == ["no-longer-listed", "done"])
    }

    @Test func selectingAMemberOpensItsGroupAndArea() {
        var state = WorkspaceStatusGroupsState(areaCollapsed: true, collapsedStatusIds: ["parked", "done"])
        state.reveal(statusId: "parked")
        #expect(!state.areaCollapsed)
        #expect(!state.collapsedStatusIds.contains("parked"))
        #expect(state.collapsedStatusIds.contains("done"))
    }
}
