import CmuxFoundation
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarStatusHeaderCommitTests {
    private static let list = WorkspaceStatusList(entries: ["a", "b", "c"].map {
        WorkspaceStatusEntry(id: $0, name: $0, extends: .todo)
    }, source: .file)
    private func plan(_ action: SidebarStatusHeaderDropPlan.Action) -> SidebarStatusHeaderDropPlan {
        .init(indicator: .init(tabId: UUID(), edge: .top), action: action)
    }

    @Test(arguments: [false, true])
    func aHeaderDropChangesOnlyThisWindowsOrderAndKeepsUnknownIdsAndFolds(_ before: Bool) {
        let original = WorkspaceStatusGroupsState(collapsedStatusIds: ["a", "not-listed"], order: ["a", "not-listed", "b", "c"])
        let state = SidebarState(statusGroups: original)
        let otherWindow = SidebarState(statusGroups: original)
        #expect(state.commitStatusHeaderDrop(source: .statusGroup("c"),
            plan: plan(.statusGroup(targetStatusId: "a", insertBefore: before)), list: Self.list, controlsEnabled: true))
        #expect(state.statusGroups?.order == (before ? ["c", "a", "not-listed", "b"] : ["a", "c", "not-listed", "b"]))
        #expect(state.statusGroups?.collapsedStatusIds == original.collapsedStatusIds)
        #expect(state.statusGroups?.areaCollapsed == original.areaCollapsed)
        #expect(otherWindow.statusGroups == original)
    }
    @Test func anAreaDropStoresBothNeighboursAndKeepsFoldAndOrder() {
        let original = WorkspaceStatusGroupsState(areaCollapsed: true, collapsedStatusIds: ["a"], order: ["c", "a", "b"])
        let state = SidebarState(statusGroups: original)
        #expect(state.commitStatusHeaderDrop(source: .statusesArea,
            plan: plan(.area(aboveRow: "workspace:a", belowRow: "group:b", last: false)),
            list: Self.list, controlsEnabled: true, validTopLevelRowIds: ["workspace:a", "group:b"]))
        #expect(state.statusGroups?.aboveRow == "workspace:a")
        #expect(state.statusGroups?.belowRow == "group:b")
        #expect(state.statusGroups?.last == false)
        #expect(state.statusGroups?.order == original.order)
        #expect(state.statusGroups?.areaCollapsed == true)
        #expect(state.statusGroups?.collapsedStatusIds == original.collapsedStatusIds)
    }

    @Test func anAcceptedNonSelfNoOpMaterializesOrderBeforeAnyActualReorder() {
        let state = SidebarState()
        #expect(state.commitStatusHeaderDrop(source: .statusGroup("b"),
            plan: plan(.statusGroup(targetStatusId: "a", insertBefore: false)), list: Self.list, controlsEnabled: true))
        #expect(state.statusGroups?.order == ["a", "b", "c"])
    }
    @Test func movingOnlyTheAreaNeverInitializesStatusGroupOrder() {
        let state = SidebarState()
        #expect(state.commitStatusHeaderDrop(source: .statusesArea,
            plan: plan(.area(aboveRow: "top", belowRow: "workspace:live", last: false)), list: Self.list,
            controlsEnabled: true, validTopLevelRowIds: ["workspace:live"]))
        #expect(state.statusGroups?.order == nil)
        #expect(state.statusGroups?.belowRow == "workspace:live")
    }
    @Test(arguments: [false, true])
    func refusedSelfOrUnknownTargetCannotCreateOrder(_ unknown: Bool) {
        let original = WorkspaceStatusGroupsState()
        let state = SidebarState(statusGroups: original)
        #expect(!state.commitStatusHeaderDrop(source: .statusGroup("a"),
            plan: plan(.statusGroup(targetStatusId: unknown ? "removed" : "a", insertBefore: true)),
            list: Self.list, controlsEnabled: true))
        #expect(state.statusGroups == original)
        #expect(state.statusGroups?.order == nil)
    }

    enum Refusal: CaseIterable, Equatable, Sendable {
        case controlsOff, noList, emptyList, removedSource, removedTarget, wrongKind, staleAreaOwners, pendingOldWindow
    }
    @Test(arguments: Refusal.allCases)
    func anInvalidOrStaleDropChangesNothing(_ refusal: Refusal) {
        var source = SidebarStatusHeaderKind.statusGroup("c")
        var action = SidebarStatusHeaderDropPlan.Action.statusGroup(targetStatusId: "a", insertBefore: true)
        var list = Self.list
        var controls = true
        let original = WorkspaceStatusGroupsState(order: ["a", "not-listed", "b", "c"])
        let state = SidebarState(statusGroups: refusal == .pendingOldWindow ? nil : original)
        switch refusal {
        case .controlsOff: controls = false
        case .noList: list = .cmuxFive
        case .emptyList: list = .init(entries: [], source: .file)
        case .removedSource: source = .statusGroup("removed")
        case .removedTarget: action = .statusGroup(targetStatusId: "removed", insertBefore: true)
        case .wrongKind: source = .statusesArea
        case .staleAreaOwners:
            source = .statusesArea
            action = .area(aboveRow: "workspace:gone", belowRow: "group:also-gone", last: false)
        case .pendingOldWindow: break
        }
        let before = state.statusGroups
        #expect(!state.commitStatusHeaderDrop(source: source, plan: plan(action), list: list, controlsEnabled: controls,
                                             validTopLevelRowIds: ["workspace:live"]))
        #expect(state.statusGroups == before)
    }
}
