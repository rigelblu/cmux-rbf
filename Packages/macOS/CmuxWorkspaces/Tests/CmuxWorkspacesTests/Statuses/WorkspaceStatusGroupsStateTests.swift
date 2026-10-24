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

    @Test func sectionStateRoundTripsWithoutChangingInnerFolds() throws {
        let data = Data(#"{"areaCollapsed":true,"collapsedStatusIds":["parked"],"order":["parked","next"],"sectionOrder":"statusesFirst","workspacesCollapsed":true,"last":false,"aboveRow":"top"}"#.utf8)
        let state = try JSONDecoder().decode(WorkspaceStatusGroupsState.self, from: data)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(saved["sectionOrder"] as? String == "statusesFirst")
        #expect(saved["workspacesCollapsed"] as? Bool == true)
        #expect(state.areaCollapsed)
        #expect(state.collapsedStatusIds == ["parked"])
        #expect(state.order == ["parked", "next"])
    }

    @Test func pendingLegacyRecordsKeepTheirPlacementUntilMigration() throws {
        let state = WorkspaceStatusGroupsState(areaCollapsed: true, collapsedStatusIds: ["parked"],
            last: false, aboveRow: "workspace:old", belowRow: "workspace:next")
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(saved["sectionOrder"] == nil)
        #expect(saved["workspacesCollapsed"] == nil)
        #expect(saved["aboveRow"] as? String == "workspace:old")
        #expect(saved["belowRow"] as? String == "workspace:next")
        #expect(saved["last"] as? Bool == false)
    }

    @Test func unknownSectionOrderDoesNotLoseWindow() throws {
        let data = Data(#"{"sectionOrder":"future-order","workspacesCollapsed":true,"areaCollapsed":true,"collapsedStatusIds":["parked"],"last":true,"aboveRow":"workspace:old"}"#.utf8)
        let state = try JSONDecoder().decode(WorkspaceStatusGroupsState.self, from: data)
        #expect(state.sectionOrder == nil)
        #expect(state.workspacesCollapsed == true)
        #expect(state.areaCollapsed && state.collapsedStatusIds == ["parked"])
        #expect(state.last == true && state.aboveRow == "workspace:old")
    }

    @Test(arguments: WorkspaceSectionOrder.allCases)
    func canonicalMirrorsDecodeWithReleasedState(_ order: WorkspaceSectionOrder) throws {
        var state = WorkspaceStatusGroupsState(areaCollapsed: true, collapsedStatusIds: ["parked"],
            order: ["next", "parked"], sectionOrder: order, workspacesCollapsed: true)
        // A stale legacy writer may alter only the copy; saving must still obey the primary order.
        state.aboveRow = "workspace:stale"
        state.belowRow = "workspace:other"
        state.last = order != .workspacesFirst
        let data = try JSONEncoder().encode(state)
        let old = try JSONDecoder().decode(ReleasedWorkspaceStatusGroupsState.self, from: data)
        #expect(old.last == (order == .workspacesFirst))
        #expect(old.aboveRow == "top" && old.belowRow == nil)
        #expect(old.areaCollapsed && old.collapsedStatusIds == ["parked"])
        #expect(old.order == ["next", "parked"])
        let downgraded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(downgraded["sectionOrder"] == nil && downgraded["workspacesCollapsed"] == nil)
    }
}
