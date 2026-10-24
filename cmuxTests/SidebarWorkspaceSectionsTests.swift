import AppKit
import CmuxNotifications
import CmuxSettings
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarWorkspaceSectionsTests {
    private let list = WorkspaceStatusList(entries: [
        .init(id: "parked", name: "Parked", extends: .todo, color: "#112233"),
        .init(id: "done", name: "Done")
    ], source: .file)
    private let colors = ["parked": "#112233"]

    private func render(_ tabs: [Workspace], groups: [WorkspaceGroup] = [],
        folds: WorkspaceStatusGroupsState = .init(), active: Bool = true) -> SidebarStatusRenderItemsResolution {
        let base = SidebarWorkspaceRenderItem.renderItems(tabs: tabs,
            groupsById: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }), orderedGroups: groups)
        let projection = VerticalTabsSidebar.statusGroupProjection(
            items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: tabs, list: list, groups: groups),
            list: list, colorHexes: colors, controlsEnabled: active, workspaceGroups: groups)
        let color = VerticalTabsSidebar.colorSectionProjection(workspaces: tabs.map {
            .init(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned, customColor: $0.customColor)
        }, collapsedHexes: [], statusGroupProjection: projection, colorHexes: colors, paletteEntries: [])
        let result = VerticalTabsSidebar.resolveRenderItems(colorSectionProjection: color, baseItems: base,
            statusGroupProjection: projection, folds: folds, tabs: tabs, groups: groups)
        #expect(result.numberedWorkspaceIndexById == SidebarWorkspaceRenderItem.numberedWorkspaceIndexById(from: base))
        return result
    }

    private func assertSection(_ row: SidebarWorkspaceRenderItemID, statuses: Bool,
        tabs: [Workspace], groups: [WorkspaceGroup] = []) throws {
        let original = tabs.map(\.id)
        for order in WorkspaceSectionOrder.allCases {
            let rows = render(tabs, groups: groups, folds: .init(sectionOrder: order)).items.map(\.id)
            let w = try #require(rows.firstIndex(of: .workspacesArea()))
            let s = try #require(rows.firstIndex(of: .statusesArea()))
            let i = try #require(rows.firstIndex(of: row))
            let start = statuses ? s : w, end = statuses ? w : s
            #expect(i > start && (start > end || i < end))
            #expect(tabs.map(\.id) == original)
        }
    }

    private func group(anchor: Workspace, parent: UUID? = nil, status: String? = nil, pinned: Bool = false) -> WorkspaceGroup {
        var group = WorkspaceGroup(id: UUID(), name: "Group", isCollapsed: false, isPinned: pinned,
            anchorWorkspaceId: anchor.id, customColor: nil, iconSymbol: nil, parentGroupId: parent)
        group.statusId = status
        anchor.groupId = group.id
        return group
    }

    @Test func pinnedWorkspaceStaysAboveBothSectionsInItsColorGroup() throws {
        let pin = Workspace(), peer = Workspace(), loose = Workspace()
        for w in [pin, peer] { w.isPinned = true; w.customColor = "#112233" }
        for order in WorkspaceSectionOrder.allCases {
            let rows = render([pin, peer, loose], folds: .init(sectionOrder: order)).items.map(\.id)
            let i = try #require(rows.firstIndex(of: .workspace(pin.id)))
            #expect(i < (try #require(rows.firstIndex(of: .workspacesArea()))))
            #expect(i < (try #require(rows.firstIndex(of: .statusesArea()))))
            #expect(render([pin, peer, loose], folds: .init(sectionOrder: order)).items.prefix(i).contains { if case .colorSectionHeader = $0 { return true }; return false })
        }
    }
    @Test func pinnedGroupKeepsItsWholeSubtreeAboveBothSections() throws {
        let anchor = Workspace(), nested = Workspace(), member = Workspace()
        let root = group(anchor: anchor, status: "parked", pinned: true)
        let child = group(anchor: nested, parent: root.id)
        member.groupId = child.id
        for order in WorkspaceSectionOrder.allCases {
            let rows = render([anchor, nested, member], groups: [root, child], folds: .init(sectionOrder: order)).items.map(\.id)
            let boundary = min(try #require(rows.firstIndex(of: .workspacesArea())), try #require(rows.firstIndex(of: .statusesArea())))
            #expect(rows.prefix(boundary).contains(.group(root.id)))
            #expect(rows.prefix(boundary).contains(.group(child.id)))
            #expect(rows.prefix(boundary).contains(.workspace(member.id)))
        }
    }
    @Test func looseWorkspaceWithProjectedStatusIsInStatuses() throws {
        let w = Workspace(); w.setOwnStatus(try #require(list.entry(id: "parked")), list: list)
        try assertSection(.workspace(w.id), statuses: true, tabs: [Workspace(), w])
    }
    @Test func plainLooseWorkspaceIsInWorkspacesAtTabOrderPlace() throws {
        let a = Workspace(), b = Workspace()
        try assertSection(.workspace(b.id), statuses: false, tabs: [a, b])
        let rows = render([a, b]).items.map(\.id)
        #expect(rows.firstIndex(of: .workspace(a.id))! < rows.firstIndex(of: .workspace(b.id))!)
    }
    @Test func colorOnlyStatusMemberIsInStatuses() throws {
        let w = Workspace(); w.customColor = "#112233"
        try assertSection(.workspace(w.id), statuses: true, tabs: [w])
    }
    @Test func unprojectedStatusUsesWorkspacesUnlessItsColorProjects() throws {
        let w = Workspace(); w.setOwnStatus(.init(id: "orphan", name: "Orphan", extends: .todo), list: .init(entries: [.init(id: "orphan", name: "Orphan", extends: .todo)], source: .file))
        try assertSection(.workspace(w.id), statuses: false, tabs: [w])
        w.customColor = "#112233"
        try assertSection(.workspace(w.id), statuses: true, tabs: [w])
    }
    @Test func nonStatusColorGroupStaysInWorkspaces() throws {
        let a = Workspace(), b = Workspace()
        a.customColor = "#AABBCC"; b.customColor = "#AABBCC"
        try assertSection(.workspace(a.id), statuses: false, tabs: [a, b])
        #expect(render([a, b]).items.contains { if case .colorSectionHeader = $0 { return true }; return false })
    }
    @Test func topLevelStatusGroupMovesAsAWholeIntoStatuses() throws {
        let a = Workspace(), b = Workspace(), g = group(anchor: a, status: "parked")
        b.groupId = g.id
        try assertSection(.group(g.id), statuses: true, tabs: [a, b], groups: [g])
        try assertSection(.workspace(b.id), statuses: true, tabs: [a, b], groups: [g])
    }
    @Test func topLevelPlainGroupStaysInWorkspaces() throws {
        let a = Workspace(), b = Workspace(), g = group(anchor: a)
        b.groupId = g.id
        try assertSection(.group(g.id), statuses: false, tabs: [a, b], groups: [g])
    }
    @Test(arguments: [false, true])
    func plainNestedGroupFollowsItsParentSection(_ status: Bool) throws {
        let a = Workspace(), b = Workspace(), c = Workspace()
        let root = group(anchor: a, status: status ? "parked" : nil), child = group(anchor: b, parent: root.id)
        c.groupId = child.id
        try assertSection(.group(child.id), statuses: status, tabs: [a, b, c], groups: [root, child])
        try assertSection(.workspace(c.id), statuses: status, tabs: [a, b, c], groups: [root, child])
    }
    @Test func memberOwnStatusDoesNotPullItOutOfItsWorkspaceGroup() throws {
        let a = Workspace(), b = Workspace(), g = group(anchor: a)
        b.groupId = g.id; b.setOwnStatus(try #require(list.entry(id: "parked")), list: list)
        try assertSection(.workspace(b.id), statuses: false, tabs: [a, b], groups: [g])
    }
    @Test func emptyWorkspacesStillHasItsHeader() {
        let w = Workspace(); w.customColor = "#112233"
        #expect(render([w]).items.map(\.id).contains(.workspacesArea()))
    }
    @Test func noListOrControlsOffKeepsLegacyLayout() {
        let a = Workspace(), b = Workspace()
        #expect(render([a, b], active: false).items.map(\.id) == [.workspace(a.id), .workspace(b.id)])
        #expect(VerticalTabsSidebar.statusGroupProjection(items: [], list: .cmuxFive,
            colorHexes: [:], controlsEnabled: true, workspaceGroups: []) == nil)
    }
    @Test func workspacesStartsUnfoldedInEachWindow() {
        let w = Workspace()
        for _ in 0..<2 {
            let state = SidebarState()
            #expect(state.statusGroups?.workspacesCollapsed != true)
            #expect(render([w], folds: state.statusGroups!).items.map(\.id).contains(.workspace(w.id)))
            #expect(render([w], folds: state.statusGroups!).items.map(\.id).contains(.workspacesArea()))
        }
    }
    @Test func foldingOneSectionLeavesTheOtherVisible() {
        let a = Workspace(), b = Workspace(); b.customColor = "#112233"
        let state = SidebarState(statusGroups: .init(sectionOrder: .workspacesFirst))
        state.toggleWorkspacesArea()
        let first = render([a, b], folds: state.statusGroups!).items.map(\.id)
        #expect(!first.contains(.workspace(a.id)) && first.contains(.workspace(b.id)))
        state.toggleWorkspacesArea(); state.toggleStatusesArea()
        let second = render([a, b], folds: state.statusGroups!).items.map(\.id)
        #expect(second.contains(.workspace(a.id)) && !second.contains(.workspace(b.id)))
        #expect(second.contains(.statusesArea()) && second.contains(.workspacesArea()))
    }
    @Test func sectionFoldsAndOrderSurviveSessionRoundTrip() throws {
        let state = SidebarState(statusGroups: .init(areaCollapsed: true, sectionOrder: .statusesFirst, workspacesCollapsed: true))
        let snapshot = SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 280, statusGroups: state.statusGroups)
        let read = try JSONDecoder().decode(SessionSidebarSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = SidebarState(statusGroups: read.statusGroups)
        #expect(restored.statusGroups == state.statusGroups)
        #expect(restored.statusGroups?.workspacesCollapsed == true && restored.statusGroups?.areaCollapsed == true)
    }
    enum SelectedPlacement: CaseIterable, Sendable { case loose, plainGroup, pinnedGroup, statusGroup }

    @Test(arguments: SelectedPlacement.allCases)
    func selectingHiddenWorkspaceRevealsOnlyItsSection(_ placement: SelectedPlacement) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { UserDefaults.standard.set(previous, forKey: key) }
            let state = SidebarState(statusGroups: .init(areaCollapsed: true, collapsedStatusIds: ["parked", "done"],
                sectionOrder: .workspacesFirst, workspacesCollapsed: true))
            let w = Workspace(), anchor = Workspace()
            var groups: [WorkspaceGroup] = []
            if placement != .loose {
                let g = group(anchor: anchor, status: placement == .plainGroup ? nil : "parked", pinned: placement == .pinnedGroup)
                w.groupId = g.id; groups = [g]
                w.setOwnStatus(try #require(list.entry(id: placement == .statusGroup ? "done" : "parked")), list: list)
            }
            state.revealStatusGroup(containing: w, list: list, resolvedHexByStatusId: colors, workspaceGroups: groups)
            #expect(state.statusGroups?.workspacesCollapsed == !(placement == .loose || placement == .plainGroup))
            #expect(state.statusGroups?.areaCollapsed == (placement != .statusGroup))
            #expect(state.statusGroups?.collapsedStatusIds == (placement == .statusGroup ? ["done"] : ["parked", "done"]))
        }
    }
    @Test func sectionFoldPreservesInnerStatusAndWorkspaceGroupFolds() {
        let a = Workspace(), b = Workspace()
        var g = group(anchor: a); g.isCollapsed = true; b.groupId = g.id
        let state = SidebarState(statusGroups: .init(collapsedStatusIds: ["parked"], sectionOrder: .statusesFirst))
        state.toggleWorkspacesArea(); state.toggleWorkspacesArea()
        #expect(state.statusGroups?.collapsedStatusIds == ["parked"])
        let rows = render([a, b], groups: [g], folds: state.statusGroups!).items.map(\.id)
        #expect(rows.contains(.group(g.id)) && !rows.contains(.workspace(b.id)))
        #expect(render([a, b], groups: [g], folds: .init(workspacesCollapsed: true)).workspacesSectionMemberIds == [a.id, b.id])
    }
    @Test func sectionFoldsAreWindowLocal() {
        let a = SidebarState(), b = SidebarState()
        a.toggleWorkspacesArea()
        #expect(a.statusGroups?.workspacesCollapsed == true)
        #expect(b.statusGroups?.workspacesCollapsed != true)
    }
}
