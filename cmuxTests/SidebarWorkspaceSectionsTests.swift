import AppKit
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSidebar
import CmuxUpdater
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
        let w = Workspace(); w.clearTaskStatusOverride(); w.customColor = "#112233"
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
        let w = Workspace(); w.clearTaskStatusOverride(); w.customColor = "#112233"
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
        let a = Workspace(), b = Workspace(); b.clearTaskStatusOverride(); b.customColor = "#112233"
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

    // MARK: - cm-110.5 Test Matrix (Rules 1–6, Scenarios 76 and 77)

    @Test func pinnedWorkspaceStaysInPinnedSectionAboveBothSections() throws {
        let pin = Workspace(), loose = Workspace()
        pin.isPinned = true
        for order in WorkspaceSectionOrder.allCases {
            let rows = render([pin, loose], folds: .init(sectionOrder: order)).items
            let firstId = try #require(rows.first?.headerDropIdentity)
            #expect(firstId == SidebarStatusHeaderIdentity.pinnedAreaUUID)
            let pIndex = try #require(rows.firstIndex(where: { $0.id == .workspace(pin.id) }))
            let wIndex = try #require(rows.firstIndex(where: { $0.id == .workspacesArea() }))
            let sIndex = try #require(rows.firstIndex(where: { $0.id == .statusesArea() }))
            #expect(pIndex > 0 && pIndex < min(wIndex, sIndex))
        }
    }

    @Test func pinnedGroupWithNestedGroupsStaysInPinnedSection() throws {
        let anchor = Workspace(), nested = Workspace(), member = Workspace(), loose = Workspace()
        let root = group(anchor: anchor, status: "parked", pinned: true)
        let child = group(anchor: nested, parent: root.id)
        member.groupId = child.id
        for order in WorkspaceSectionOrder.allCases {
            let rows = render([anchor, nested, member, loose], groups: [root, child], folds: .init(sectionOrder: order)).items
            let firstId = try #require(rows.first?.headerDropIdentity)
            #expect(firstId == SidebarStatusHeaderIdentity.pinnedAreaUUID)
            let wIndex = try #require(rows.firstIndex(where: { $0.id == .workspacesArea() }))
            let sIndex = try #require(rows.firstIndex(where: { $0.id == .statusesArea() }))
            let boundary = min(wIndex, sIndex)
            let pinRowIds = rows.prefix(boundary).map(\.id)
            #expect(pinRowIds.contains(.group(root.id)))
            #expect(pinRowIds.contains(.group(child.id)))
            #expect(pinRowIds.contains(.workspace(member.id)))
        }
    }

    @Test func pinnedSectionShowsHeaderOnlyWhenPinsExist() throws {
        let pin = Workspace(), loose = Workspace()
        pin.isPinned = true
        let withPins = render([pin, loose]).items
        let firstId = try #require(withPins.first?.headerDropIdentity)
        #expect(firstId == SidebarStatusHeaderIdentity.pinnedAreaUUID)

        pin.isPinned = false
        let withoutPins = render([pin, loose]).items
        #expect(!withoutPins.contains(where: { $0.headerDropIdentity == SidebarStatusHeaderIdentity.pinnedAreaUUID }))
    }

    // Guard: passes on .4 by design
    @Test func pinnedSectionHiddenWhenNoPinsExist() {
        let loose = Workspace()
        let rows = render([loose]).items
        #expect(!rows.contains(where: { $0.headerDropIdentity == SidebarStatusHeaderIdentity.pinnedAreaUUID }))
    }

    // Guard: passes on .4 by design
    @Test func pinnedSectionHiddenWhenControlsOffOrNoStatusList() {
        let pin = Workspace(), loose = Workspace()
        pin.isPinned = true
        let rows = render([pin, loose], active: false).items
        #expect(!rows.contains(where: { $0.headerDropIdentity == SidebarStatusHeaderIdentity.pinnedAreaUUID }))
    }

    @Test func pinnedHeaderFoldHidesPinnedRows() throws {
        let pin = Workspace(), loose = Workspace()
        pin.isPinned = true
        // Folded: the Pinned header stays first and the pinned rows go.
        let folded = render([pin, loose], folds: WorkspaceStatusGroupsState(pinnedCollapsed: true)).items
        #expect(try #require(folded.first?.headerDropIdentity) == SidebarStatusHeaderIdentity.pinnedAreaUUID)
        #expect(!folded.map(\.id).contains(.workspace(pin.id)), "Folded: the pinned row is hidden")
        // Unfolded: the same header, and the pinned row shows.
        let unfolded = render([pin, loose], folds: WorkspaceStatusGroupsState(pinnedCollapsed: false)).items
        #expect(try #require(unfolded.first?.headerDropIdentity) == SidebarStatusHeaderIdentity.pinnedAreaUUID)
        #expect(unfolded.map(\.id).contains(.workspace(pin.id)), "Unfolded: the pinned row shows")
    }

    // 10_expected-results.md (cm-110.5): the Pinned section starts unfolded. Read from a window nobody has touched, and from a saved record that predates the key.
    @Test func pinnedHeaderStartsUnfoldedInAFreshWindow() throws {
        let pin = Workspace(), loose = Workspace()
        pin.isPinned = true
        var fresh = SidebarState()
        #expect(render([pin, loose], folds: fresh.statusGroups ?? .init()).items.map(\.id).contains(.workspace(pin.id)), "A fresh window shows its pinned rows")
        let restored = try JSONDecoder().decode(WorkspaceStatusGroupsState.self, from: Data(#"{"areaCollapsed":false,"collapsedStatusIds":[]}"#.utf8))
        #expect(render([pin, loose], folds: restored).items.map(\.id).contains(.workspace(pin.id)), "A saved record with no Pinned fold shows them too")
        fresh.togglePinnedArea()
        #expect(!render([pin, loose], folds: fresh.statusGroups ?? .init()).items.map(\.id).contains(.workspace(pin.id)), "The first click on the chevron folds it")
    }

    @Test func pinnedFoldPreservesStatusesAndWorkspacesFolds() {
        let pin = Workspace(), loose = Workspace()
        pin.isPinned = true
        var state = SidebarState(statusGroups: .init(areaCollapsed: true, sectionOrder: .workspacesFirst, workspacesCollapsed: true, pinnedCollapsed: false))
        state.togglePinnedArea()
        #expect(state.statusGroups?.pinnedCollapsed == true)
        #expect(state.statusGroups?.workspacesCollapsed == true)
        #expect(state.statusGroups?.areaCollapsed == true)
        state.toggleWorkspacesArea()
        #expect(state.statusGroups?.pinnedCollapsed == true)
        #expect(state.statusGroups?.workspacesCollapsed == false)
    }

    @Test func pinnedFoldSurvivesSessionRoundTrip() throws {
        let state = SidebarState(statusGroups: .init(areaCollapsed: true, sectionOrder: .statusesFirst, workspacesCollapsed: true, pinnedCollapsed: true))
        let snapshot = SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 280, statusGroups: state.statusGroups)
        let read = try JSONDecoder().decode(SessionSidebarSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = SidebarState(statusGroups: read.statusGroups)
        #expect(restored.statusGroups == state.statusGroups)
        #expect(restored.statusGroups?.pinnedCollapsed == true)
        #expect(restored.statusGroups?.workspacesCollapsed == true)
        #expect(restored.statusGroups?.areaCollapsed == true)
    }

    @Test func selectingHiddenPinnedWorkspaceRevealsPinnedSection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { UserDefaults.standard.set(previous, forKey: key) }
            let state = SidebarState(statusGroups: .init(areaCollapsed: true, sectionOrder: .workspacesFirst, workspacesCollapsed: true, pinnedCollapsed: true))
            let pin = Workspace()
            pin.isPinned = true
            state.revealStatusGroup(containing: pin, list: list, resolvedHexByStatusId: colors, workspaceGroups: [])
            #expect(state.statusGroups?.pinnedCollapsed == false)
            #expect(state.statusGroups?.workspacesCollapsed == true)
            #expect(state.statusGroups?.areaCollapsed == true)
        }
    }

    @Test func selectingPinnedWorkspaceWithControlsDisabledDoesNotUnfoldPinnedSection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(false, forKey: key)
            defer { UserDefaults.standard.set(previous, forKey: key) }
            let state = SidebarState(statusGroups: .init(areaCollapsed: true, sectionOrder: .workspacesFirst, workspacesCollapsed: true, pinnedCollapsed: true))
            let pin = Workspace()
            pin.isPinned = true
            state.revealStatusGroup(containing: pin, list: list, resolvedHexByStatusId: colors, workspaceGroups: [])
            #expect(state.statusGroups?.pinnedCollapsed == true, "With controls disabled, pinnedCollapsed must remain true")
        }
    }

    @Test func unpinningRowWithStatusMovesItToStatusesSection() throws {
        let kRemaining = Workspace(), k1 = Workspace(), loose = Workspace()
        kRemaining.isPinned = true
        k1.isPinned = true
        k1.setOwnStatus(try #require(list.entry(id: "parked")), list: list)

        // Before unpinning: kRemaining and k1 are in the pinned section above both sections
        let pinnedRows = render([kRemaining, k1, loose]).items
        let pinnedHeaderId = try #require(pinnedRows.first?.headerDropIdentity)
        #expect(pinnedHeaderId == SidebarStatusHeaderIdentity.pinnedAreaUUID)
        let pInitial = try #require(pinnedRows.firstIndex(where: { $0.id == .workspace(k1.id) }))
        let wInitial = try #require(pinnedRows.firstIndex(where: { $0.id == .workspacesArea() }))
        let sInitial = try #require(pinnedRows.firstIndex(where: { $0.id == .statusesArea() }))
        #expect(pInitial > 0 && pInitial < min(wInitial, sInitial), "Initial pinned row sits in pinned area")

        // After unpinning: moves out of pinned section into Statuses section; pinned section remains for kRemaining
        k1.isPinned = false
        for order in WorkspaceSectionOrder.allCases {
            let unpinnedRows = render([kRemaining, k1, loose], folds: .init(sectionOrder: order)).items.map(\.id)
            #expect(unpinnedRows.contains(where: { $0 == .pinnedArea() }), "Pinned header retained when other pins remain")
            let p = try #require(unpinnedRows.firstIndex(of: .pinnedArea()))
            let pRem = try #require(unpinnedRows.firstIndex(of: .workspace(kRemaining.id)))
            let s = try #require(unpinnedRows.firstIndex(of: .statusesArea()))
            let w = try #require(unpinnedRows.firstIndex(of: .workspacesArea()))
            let i = try #require(unpinnedRows.firstIndex(of: .workspace(k1.id)))
            #expect(pRem > p && pRem < min(s, w), "Remaining pin stays in pinned section")
            #expect(i > s && (s > w || i < w), "Unpinned status workspace moves to Statuses section")
        }
    }

    @Test func unpinningRowWithoutStatusMovesItToWorkspacesSection() throws {
        let kRemaining = Workspace(), k2 = Workspace(), loose = Workspace()
        kRemaining.isPinned = true
        k2.isPinned = true

        // Before unpinning: kRemaining and k2 are in the pinned section
        let pinnedRows = render([kRemaining, k2, loose]).items
        let pinnedHeaderId = try #require(pinnedRows.first?.headerDropIdentity)
        #expect(pinnedHeaderId == SidebarStatusHeaderIdentity.pinnedAreaUUID)
        let pInitial = try #require(pinnedRows.firstIndex(where: { $0.id == .workspace(k2.id) }))
        let wInitial = try #require(pinnedRows.firstIndex(where: { $0.id == .workspacesArea() }))
        let sInitial = try #require(pinnedRows.firstIndex(where: { $0.id == .statusesArea() }))
        #expect(pInitial > 0 && pInitial < min(wInitial, sInitial), "Initial pinned row sits in pinned area")

        // After unpinning: moves out of pinned section into Workspaces section; pinned section remains for kRemaining
        k2.isPinned = false
        for order in WorkspaceSectionOrder.allCases {
            let unpinnedRows = render([kRemaining, k2, loose], folds: .init(sectionOrder: order)).items.map(\.id)
            #expect(unpinnedRows.contains(where: { $0 == .pinnedArea() }), "Pinned header retained when other pins remain")
            let p = try #require(unpinnedRows.firstIndex(of: .pinnedArea()))
            let pRem = try #require(unpinnedRows.firstIndex(of: .workspace(kRemaining.id)))
            let s = try #require(unpinnedRows.firstIndex(of: .statusesArea()))
            let w = try #require(unpinnedRows.firstIndex(of: .workspacesArea()))
            let i = try #require(unpinnedRows.firstIndex(of: .workspace(k2.id)))
            #expect(pRem > p && pRem < min(s, w), "Remaining pin stays in pinned section")
            #expect(i > w && (w > s || i < s), "Unpinned plain workspace moves to Workspaces section")
        }
    }

    @Test func pinnedHeaderShownWhenEmptyPinnedGroupExists() throws {
        let emptyGroup = WorkspaceGroup(id: UUID(), name: "Pinned Group", isCollapsed: false, isPinned: true, anchor: .empty(UUID()), customColor: nil, iconSymbol: nil)
        let loose = Workspace()
        let rows = render([loose], groups: [emptyGroup]).items
        let firstId = try #require(rows.first?.headerDropIdentity)
        #expect(firstId == SidebarStatusHeaderIdentity.pinnedAreaUUID)
        let rowIds = rows.map { $0.id }
        #expect(rowIds.contains(.group(emptyGroup.id)))
    }

    @Test func pinnedWorkspaceStatusChangeStaysInPinnedSectionInColorGroup() throws {
        let pin = Workspace(), loose = Workspace()
        pin.isPinned = true
        // Plain pinned workspace without status
        let initialRows = render([pin, loose]).items
        let pInitial = try #require(initialRows.firstIndex(where: { $0.id == .workspace(pin.id) }))
        #expect(pInitial == 1) // Directly after pinnedHeader

        // Change status to "parked" with color #112233
        pin.setOwnStatus(try #require(list.entry(id: "parked")), list: list)
        pin.customColor = "#112233"
        for order in WorkspaceSectionOrder.allCases {
            let rows = render([pin, loose], folds: .init(sectionOrder: order)).items
            let firstId = try #require(rows.first?.headerDropIdentity)
            #expect(firstId == SidebarStatusHeaderIdentity.pinnedAreaUUID)
            let pIndex = try #require(rows.firstIndex(where: { $0.id == .workspace(pin.id) }))
            let wIndex = try #require(rows.firstIndex(where: { $0.id == .workspacesArea() }))
            let sIndex = try #require(rows.firstIndex(where: { $0.id == .statusesArea() }))
            #expect(pIndex > 0 && pIndex < min(wIndex, sIndex))
            // Verify color section header appears in pinned tier above pin
            let colorHeaderIndex = try #require(rows.firstIndex(where: {
                if case .colorSectionHeader(let section) = $0 {
                    return section.id.pinTier == .pinned && section.id.normalizedHex == "#112233"
                }
                return false
            }))
            #expect(colorHeaderIndex < pIndex, "Color section header precedes pinned member")
            #expect(colorHeaderIndex > 0, "Color section header is within pinned tier below pinnedHeader")
        }
    }

    @Test func pinningLastStatusWorkspaceLeavesStatusGroupHeaderEmpty() throws {
        let w = Workspace()
        w.isPinned = true
        w.setOwnStatus(try #require(list.entry(id: "parked")), list: list)
        let rows = render([w]).items
        let firstId = try #require(rows.first?.headerDropIdentity)
        #expect(firstId == SidebarStatusHeaderIdentity.pinnedAreaUUID)
        let rowIds = rows.map { $0.id }
        #expect(rowIds.contains(.statusGroup("parked")))
    }

    @Test func draggedSectionOverPinnedRows_landsFirstBelowPinned_lineDrawsOnTopEdgeOfFirstUnpinnedRow() throws {
        let pin = Workspace(), loose = Workspace()
        pin.isPinned = true
        let resolution = render([pin, loose])
        let items = resolution.items
        let projection = try #require(VerticalTabsSidebar.statusGroupProjection(
            items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: [pin, loose], list: list, groups: []),
            list: list, colorHexes: colors, controlsEnabled: true, workspaceGroups: []))
        let layout = SidebarStatusAreaLayout(items: items, tabs: [pin, loose], groups: [], statusProjection: projection)
        // Measured overlay targets generated through production layout
        var measured: [SidebarWorkspaceReorderDropOverlay.Target] = []
        var y: CGFloat = 0
        for item in items {
            let rowId: UUID
            let isGroup = false
            switch item {
            case .pinnedHeader: rowId = SidebarStatusHeaderIdentity.pinnedAreaUUID
            case .workspacesHeader: rowId = SidebarStatusHeaderIdentity.workspacesAreaUUID
            case .statusesHeader: rowId = SidebarStatusHeaderIdentity.statusesAreaUUID
            case .workspace(let id): rowId = id
            case .groupHeader(let id, _): rowId = id
            case .statusGroupHeader(let id): rowId = SidebarStatusHeaderIdentity.uuid(forStatusId: id)
            default: continue
            }
            measured.append(SidebarWorkspaceReorderDropOverlay.Target(
                workspaceId: rowId,
                groupId: nil,
                isGroupHeader: isGroup,
                frame: CGRect(x: 0, y: y, width: 280, height: 22),
                renderItemId: item.id
            ))
            y += 22
        }
        let targets = layout.headerDropTargets(measured: measured)
        #expect(targets.contains(where: { $0.isPinned && $0.rowId == SidebarStatusHeaderIdentity.pinnedAreaUUID }))
        #expect(targets.contains(where: { $0.isPinned && $0.rowId == pin.id }))
        let plan = try #require(SidebarStatusHeaderDropPlanner().plan(point: CGPoint(x: 100, y: 10), draggedStatusId: nil, targets: targets, draggedWorkspacesArea: false))
        #expect(plan.indicator == .init(tabId: SidebarStatusHeaderIdentity.workspacesAreaUUID, edge: .top))
    }

    @Test func pinnedHeaderDrag_isRefused_neverDragsOrSwaps() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreStatusList = try SidebarNestedStatusDropFixture.installStatusListInUse() // (#cm-110.5) the app's real store, not a test-only hook
            defer { restoreStatusList() }
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let prev = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { UserDefaults.standard.set(prev, forKey: key) }

            let pinUUID = SidebarStatusHeaderIdentity.pinnedAreaUUID
            let kind = SidebarStatusHeaderIdentity.kind(forDragId: pinUUID, list: list)
            #expect(kind == .pinnedArea)
            #expect(kind?.isSection == true)

            let pin = Workspace(), loose = Workspace()
            pin.isPinned = true
            let resolution = render([pin, loose])
            let items = resolution.items
            let projection = try #require(VerticalTabsSidebar.statusGroupProjection(
                items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: [pin, loose], list: list, groups: []),
                list: list, colorHexes: colors, controlsEnabled: true, workspaceGroups: []))
            let layout = SidebarStatusAreaLayout(items: items, tabs: [pin, loose], groups: [], statusProjection: projection)

            let sidebar = VerticalTabsSidebar(
                updateViewModel: UpdateStateModel(), fileExplorerState: FileExplorerState(), featureFlags: CmuxFeatureFlags(),
                sidebarUnread: SidebarUnreadModel(), titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
                windowId: UUID(), onSendFeedback: {}, onToggleSidebar: {}, onNewTab: {},
                observedWindowReference: WeakWindowReference(), chromeBackgroundColor: .black,
                selection: .constant(.tabs), selectedTabIds: .constant([]), lastSidebarSelectionIndex: .constant(nil),
                sidebarRenderWorkerClient: .constant(nil)
            )

            // 1. Drag inception guards refuse pinned area
            #expect(sidebar.activateStatusHeaderDrag(pinUUID) == nil, "Pinned area drag activation is refused")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            window.contentView = view
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let began = sidebar.beginSidebarNativeDrag(
                dragId: pinUUID,
                sourceView: view,
                event: event,
                draggingFrame: NSRect(x: 0, y: 0, width: 100, height: 30),
                dragImage: NSImage(size: NSSize(width: 10, height: 10))
            )
            #expect(began == false, "Pinned header must refuse beginSidebarNativeDrag")

            // 2. Commit guard refuses source .pinnedArea with .area action
            var state = SidebarState(statusGroups: .init(sectionOrder: .workspacesFirst))
            let commitResult = state.commitStatusHeaderDrop(
                source: .pinnedArea,
                plan: .init(indicator: .init(tabId: SidebarStatusHeaderIdentity.workspacesAreaUUID, edge: .top),
                            action: .area(aboveRow: "top", belowRow: nil, last: false)),
                list: list, controlsEnabled: true, validTopLevelRowIds: layout.topLevelRowIds
            )
            #expect(!commitResult, "commitStatusHeaderDrop must refuse source .pinnedArea")
            #expect(state.statusGroups?.sectionOrder == .workspacesFirst, "Section order must not be modified by pinned drop attempt")

            // 3. Commit guard in legacy layout refuses anchoring to pinned rows
            var legacyState = SidebarState(statusGroups: .init(sectionOrder: nil))
            let pinnedOwner = "workspace:\(pin.id.uuidString)"
            #expect(!layout.topLevelRowIds.contains(pinnedOwner), "Pinned rows are excluded from valid top level rows")
            let legacyRefusal = legacyState.commitStatusHeaderDrop(
                source: .statusesArea,
                plan: .init(indicator: .init(tabId: pin.id, edge: .top),
                            action: .area(aboveRow: pinnedOwner, belowRow: nil, last: false)),
                list: list, controlsEnabled: true, validTopLevelRowIds: layout.topLevelRowIds
            )
            #expect(!legacyRefusal, "commitStatusHeaderDrop must refuse anchoring to a pinned row in legacy placement")
        }
    }
}
