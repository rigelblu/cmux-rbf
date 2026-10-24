import AppKit
import CmuxFoundation
import CmuxNotifications
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace groups in the status area", .serialized)
struct SidebarWorkspaceGroupStatusProjectionTests {
    private typealias Sidebar = VerticalTabsSidebar
    private let list = WorkspaceStatusList(entries: [
        WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "#765432"),
        WorkspaceStatusEntry(id: "doing", name: "Doing", extends: .working, color: "#008800")
    ], source: .file)
    private let colors = ["parked": "#765432", "doing": "#008800"]

    @MainActor
    private struct Fixture {
        let before = Workspace(), anchor = Workspace(), member = Workspace(), after = Workspace()
        var groups: [WorkspaceGroup] = []
        var tabs: [Workspace] = []
        init() {
            var group = WorkspaceGroup(id: UUID(), name: "Root", isCollapsed: false, isPinned: false,
                                       anchorWorkspaceId: anchor.id, customColor: "#765432", iconSymbol: nil)
            group.statusId = "parked"
            anchor.groupId = group.id; member.groupId = group.id
            before.customColor = "#765432"; after.customColor = "#765432"
            anchor.customColor = "#008800"; member.customColor = "#008800"
            groups = [group]; tabs = [before, anchor, member, after]
        }
    }

    private func projection(_ f: Fixture) throws -> WorkspaceStatusGroupProjection {
        try #require(Sidebar.statusGroupProjection(
            items: Sidebar.statusGroupProjectionItems(tabs: f.tabs, list: list, groups: f.groups),
            list: list, colorHexes: colors, controlsEnabled: true, workspaceGroups: f.groups))
    }

    private func base(_ f: Fixture) -> [SidebarWorkspaceRenderItem] {
        SidebarWorkspaceRenderItem.renderItems(tabs: f.tabs,
            groupsById: Dictionary(uniqueKeysWithValues: f.groups.map { ($0.id, $0) }), orderedGroups: f.groups)
    }

    private func render(_ f: Fixture, folds: WorkspaceStatusGroupsState = .init()) throws -> SidebarStatusRenderItemsResolution {
        Sidebar.resolveRenderItems(colorSectionProjection: .project(workspaces: [], paletteEntries: [], collapsedHexes: []),
            baseItems: base(f), statusGroupProjection: try projection(f), folds: folds, tabs: f.tabs, groups: f.groups)
    }

    @Test func aWholeGroupSharesItsStatusAndKeepsItsRunBetweenLooseRows() throws {
        let f = Fixture()
        let ids = f.tabs.map(\.id)
        let result = try render(f)
        #expect(result.items.map(\.id) == [.workspacesArea(), .statusesArea(), .statusGroup("parked"), .workspace(f.before.id), // (#cm-110.4) supersedes cm-110.1's single-area layout
            .group(f.groups[0].id), .workspace(f.member.id), .workspace(f.after.id), .statusGroup("doing")])
        #expect(f.tabs.map(\.id) == ids)
        #expect(result.numberedWorkspaceIndexById == SidebarWorkspaceRenderItem.numberedWorkspaceIndexById(from: base(f)))
    }

    @Test func clearingStatusRestoresTheOriginalRunWithoutReorderingTabs() throws {
        var f = Fixture()
        f.before.customColor = nil; f.after.customColor = nil
        let original = base(f).map(\.id), tabIds = f.tabs.map(\.id)
        #expect(try render(f).items.map(\.id) == [.workspacesArea(), .workspace(f.before.id), .workspace(f.after.id), .statusesArea(), // (#cm-110.4) supersedes cm-110.1's single-area layout
            .statusGroup("parked"), .group(f.groups[0].id), .workspace(f.member.id), .statusGroup("doing")])
        f.groups[0].statusId = nil; f.groups[0].customColor = nil
        #expect(try render(f).items.map(\.id) == [.workspacesArea()] + original + [.statusesArea(), .statusGroup("parked"), .statusGroup("doing")]) // (#cm-110.4) supersedes cm-110.1's single-area layout
        #expect(f.tabs.map(\.id) == tabIds)
    }

    @Test func aNestedGroupsOwnStatusNeverOverridesItsParentsPlacement() throws {
        var f = Fixture()
        let childAnchor = Workspace(), childMember = Workspace()
        var child = WorkspaceGroup(id: UUID(), name: "Child", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: childAnchor.id, customColor: "#008800", iconSymbol: nil, parentGroupId: f.groups[0].id)
        child.statusId = "doing"
        childAnchor.groupId = child.id; childMember.groupId = child.id
        f.groups.append(child); f.tabs.insert(contentsOf: [childAnchor, childMember], at: 3)
        #expect(try render(f).items.map(\.id) == [.workspacesArea(), .statusesArea(), .statusGroup("parked"), .workspace(f.before.id), // (#cm-110.4) supersedes cm-110.1's single-area layout
            .group(f.groups[0].id), .workspace(f.member.id), .group(child.id), .workspace(childMember.id),
            .workspace(f.after.id), .statusGroup("doing")])
        #expect(f.groups[1].parentGroupId == f.groups[0].id)
        #expect(f.groups[1].statusId == "doing")
    }

    @Test func theGroupsOwnFoldRemainsClosedUnderItsStatus() throws {
        var f = Fixture(); f.groups[0].isCollapsed = true
        #expect(try render(f).items.map(\.id) == [.workspacesArea(), .statusesArea(), .statusGroup("parked"), .workspace(f.before.id), // (#cm-110.4) supersedes cm-110.1's single-area layout
            .group(f.groups[0].id), .workspace(f.after.id), .statusGroup("doing")])
        #expect(f.groups[0].isCollapsed)
    }

    @Test(arguments: [false, true])
    func foldingTheStatusOrAreaHidesTheEntireGroup(_ area: Bool) throws {
        let f = Fixture()
        let folds = WorkspaceStatusGroupsState(areaCollapsed: area, collapsedStatusIds: ["parked"])
        let expected: [SidebarWorkspaceRenderItemID] = area ? [.workspacesArea(), .statusesArea()] : // (#cm-110.4) supersedes cm-110.1's single-area layout
            [.workspacesArea(), .statusesArea(), .statusGroup("parked"), .statusGroup("doing")] // (#cm-110.4) supersedes cm-110.1's single-area layout
        #expect(try render(f, folds: folds).items.map(\.id) == expected)
    }

    @Test func theStatusLevelsCountTowardTheSharedIndentCap() throws {
        var f = Fixture()
        var parent = f.groups[0].id
        for _ in 0..<4 {
            let anchor = Workspace()
            let child = WorkspaceGroup(id: UUID(), name: "Deep", isCollapsed: false, isPinned: false,
                anchorWorkspaceId: anchor.id, customColor: nil, iconSymbol: nil, parentGroupId: parent)
            anchor.groupId = child.id; f.groups.append(child); f.tabs.insert(anchor, at: f.tabs.count - 1)
            parent = child.id
        }
        let deep = Workspace(); deep.groupId = parent; f.tabs.insert(deep, at: f.tabs.count - 1)
        let map = SidebarNestedWorkspaceRows.depthById(groupsById: Dictionary(uniqueKeysWithValues: f.groups.map { ($0.id, $0) }),
            effectiveMembership: SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: f.tabs,
                groupsById: Dictionary(uniqueKeysWithValues: f.groups.map { ($0.id, $0) })))
        let p = try projection(f)
        #expect(Sidebar.rowDepth(of: f.groups[0].id, rowDepthById: map, statusGroupProjection: p) == 2)
        let depth = Sidebar.rowDepth(of: deep.id, rowDepthById: map, statusGroupProjection: p)
        #expect(depth == 7)
        #expect(SidebarNestedIndent.points(levels: depth, availableWidth: 120) == 48)
    }

    @Test func memberColorsAndStatusesNeverPullRowsOutOfTheGroup() throws {
        let f = Fixture()
        f.member.setOwnStatus(try #require(list.entry(id: "doing")), list: list)
        let p = try projection(f)
        #expect(!p.contains(workspaceId: f.member.id))
        #expect(p.group(for: "doing")?.memberWorkspaceIds.isEmpty == true)
        #expect(try render(f).items.map(\.id) == [.workspacesArea(), .statusesArea(), .statusGroup("parked"), .workspace(f.before.id), // (#cm-110.4) supersedes cm-110.1's single-area layout
            .group(f.groups[0].id), .workspace(f.member.id), .workspace(f.after.id), .statusGroup("doing")])
    }

    @Test func anEmptyGroupHeaderCanMoveUnderItsStatus() throws {
        var f = Fixture()
        let id = UUID()
        var empty = WorkspaceGroup(id: id, name: "Empty", isCollapsed: true, isPinned: false,
                                  anchor: .empty(id), customColor: "#765432", iconSymbol: nil)
        empty.statusId = "parked"; f.groups = [empty]; f.tabs = []
        #expect(base(f).map(\.id) == [.group(id)])
        #expect(try render(f).items.map(\.id) == [.workspacesArea(), .statusesArea(), .statusGroup("parked"), .group(id), .statusGroup("doing")]) // (#cm-110.4) supersedes cm-110.1's single-area layout
    }

    @Test func debugHeadersReportOwnStatusAndTheirRealParent() throws {
        var f = Fixture()
        let childAnchor = Workspace()
        var child = WorkspaceGroup(id: UUID(), name: "Child", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: childAnchor.id, customColor: "#008800", iconSymbol: nil, parentGroupId: f.groups[0].id)
        child.statusId = "doing"; childAnchor.groupId = child.id
        f.groups.append(child); f.tabs.insert(childAnchor, at: 3)
        let p = try projection(f)
        let rows = SidebarDebugRow.rows(from: try render(f).items,
            workspaceTitle: { _ in "Workspace" }, groupName: { _ in "Root" }, groupIsFolded: { _ in false },
            groupIdOfWorkspace: { id in f.tabs.first { $0.id == id }?.groupId }, statusName: { $0 },
            statusIdByWorkspaceId: Dictionary(uniqueKeysWithValues: p.groups.flatMap { g in g.memberWorkspaceIds.map { ($0, g.statusId) } }),
            groupStatusId: { id in f.groups.first { $0.id == id }?.statusId },
            parentGroupId: { id in f.groups.first { $0.id == id }?.parentGroupId },
            statusIdByGroupId: p.workspaceGroups?.statusIdByGroupId ?? [:])
        let root = try #require(rows.first { $0.kind == "groupHeader" })
        #expect(root.statusId == "parked")
        #expect(root.header == "parked")
        let nested = try #require(rows.first { $0.id == child.id.uuidString })
        #expect(nested.statusId == "doing")
        #expect(nested.header == f.groups[0].id.uuidString)
        #expect(rows.first { $0.id == f.member.id.uuidString }?.header == f.groups[0].id.uuidString)
    }

    @Test func projectedGroupKeepsItsSavedStatusesAreaAnchor() throws {
        let f = Fixture(), p = try projection(f)
        let items = try render(f).items
        let layout = SidebarStatusAreaLayout(items: items, tabs: f.tabs, groups: f.groups, statusProjection: p)
        #expect(layout.owner(of: .group(f.groups[0].id)) == nil)
        #expect(layout.owner(of: .workspace(f.member.id)) == nil)
        let measured = [SidebarWorkspaceReorderDropOverlay.Target(workspaceId: f.anchor.id, groupId: f.groups[0].id,
            isGroupHeader: true, frame: CGRect(x: 0, y: 0, width: 240, height: 20), renderItemId: .group(f.groups[0].id))]
        #expect(layout.headerDropTargets(measured: measured).first?.statusId == "parked")
        let anchor = "group:\(f.groups[0].id.uuidString)"
        #expect(layout.saving(state: .init(last: false, aboveRow: anchor))?.aboveRow == anchor)
    }

    @Test func setAutosaveAndClearRestoresTheGroupAboveTheArea() throws {
        var f = Fixture()
        f.before.customColor = nil; f.after.customColor = nil
        f.groups[0].statusId = nil; f.groups[0].customColor = nil
        let anchor = "group:\(f.groups[0].id.uuidString)"
        let state = WorkspaceStatusGroupsState(last: false, aboveRow: anchor,
            belowRow: "workspace:\(f.after.id.uuidString)")
        let original = try render(f, folds: state).items.map(\.id), order = f.tabs.map(\.id)
        let writer = WorkspaceGroupStatusActions(list: list, resolveColor: { $0 })
        #expect(writer.apply(.status(id: "parked"), to: &f.groups[0]))
        let layout = SidebarStatusAreaLayout(items: try render(f, folds: state).items,
            tabs: f.tabs, groups: f.groups, statusProjection: try projection(f))
        let saved = try #require(layout.saving(state: state))
        let decoded = try JSONDecoder().decode(WorkspaceStatusGroupsState.self, from: JSONEncoder().encode(saved))
        #expect(decoded.aboveRow == anchor)
        #expect(writer.apply(.hide, to: &f.groups[0]))
        #expect(try render(f, folds: decoded).items.map(\.id) == original)
        #expect(f.tabs.map(\.id) == order)
    }

    @Test func foldedStatusUnreadIncludesTheAnchorAndEveryGroupMember() throws {
        let f = Fixture(), p = try projection(f)
        let unread = SidebarUnreadSnapshot(summaryByWorkspaceId: Dictionary(uniqueKeysWithValues: f.tabs.map {
            ($0.id, SidebarWorkspaceUnreadSummary(unreadCount: 1, latestNotificationText: nil))
        }))
        let header = try #require(Sidebar.sidebarStatusGroupHeaderRow(statusId: "parked", projection: p,
            presentations: Sidebar.statusGroupPresentations(projection: p, list: list, colorHexes: colors), listWidth: 240,
            environment: .init(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init()),
            folds: .init(collapsedStatusIds: ["parked"]), unreadSnapshot: unread))
        #expect(header.unreadCount == 4)
        #expect(header.memberCount == 4)
    }

    @Test func aProjectedHeaderIsRefusedBeforeTheOrdinaryDropPath() throws {
        var f = Fixture(); f.before.customColor = nil
        let p = try projection(f)
        let targets = [SidebarWorkspaceReorderDropOverlay.Target(workspaceId: f.before.id, groupId: nil,
            isGroupHeader: false, frame: CGRect(x: 0, y: 0, width: 240, height: 20), renderItemId: .workspace(f.before.id))]
        let snapshot = Sidebar.WorkspaceStatusDropSnapshot(tabs: f.tabs, workspaceGroups: f.groups,
            workspaceRenderItems: try render(f).items, statusGroupProjection: p, statusGroupFolds: .init(),
            colorSectionProjection: .project(workspaces: [], paletteEntries: [], collapsedHexes: []), selectedIds: [f.anchor.id])
        var ordinaryCalls = 0
        let routed = Sidebar.workspaceStatusRoute(point: .init(x: 10, y: 10), targets: targets, snapshot: snapshot,
            draggedId: f.anchor.id, sourceKind: .workspaceGroupHeader(groupId: f.groups[0].id), token: UUID(),
            foreignDraggedIsPinned: nil, controlsEnabled: true, hasUserStatusList: true,
            ordinary: { _, _, _ in ordinaryCalls += 1; return nil })
        _ = Sidebar.workspaceStatusOrOrdinaryPlan(status: routed, ordinary: { ordinaryCalls += 1; return nil })
        if case .refused = routed {} else { Issue.record("A projected group header must be refused") }
        #expect(ordinaryCalls == 0)
    }

    @Test func selectingAMemberRevealsItsWholeGroupsStatusInsteadOfTheMembersOwnStatus() throws {
        let f = Fixture()
        f.member.setOwnStatus(try #require(list.entry(id: "doing")), list: list)
        let state = SidebarState(statusGroups: .init(areaCollapsed: true, collapsedStatusIds: ["parked", "doing"]))
        state.prepareStatusGroupsForSelection(list: list, resolvedHexByStatusId: colors,
            selectedWorkspace: f.member, workspaceGroups: f.groups)
        let folds = try #require(state.statusGroups)
        #expect(!folds.areaCollapsed)
        #expect(!folds.collapsedStatusIds.contains("parked"))
        #expect(folds.collapsedStatusIds.contains("doing"))
    }
}

@MainActor
@Suite("Drops around workspace groups under statuses", .serialized)
struct SidebarProjectedWorkspaceGroupDropTests {
    private typealias F = SidebarNestedStatusDropFixture
    private func fixture(following: Bool = true) throws -> F {
        let f = try F(scene: .f2b)
        f.projectsWorkspaceGroups = true
        var groups = f.manager.workspaceGroups
        let index = try #require(groups.firstIndex { $0.id == f.p })
        groups[index].statusId = "parked"; groups[index].customColor = "#555555"
        f.manager.workspaceGroups = groups
        // One loose status member after the entire root, or none. Child Q still ends P's run.
        let loose = [f.w("c1"),f.w("c2"),f.w("c3")]
        let looseIds = Set(loose.map(\.id))
        var tabs = f.manager.tabs.filter { !looseIds.contains($0.id) }
        let beforeGroup = try #require(tabs.firstIndex { $0.id == f.w("pAnchor").id })
        tabs.insert(contentsOf: following ? Array(loose.prefix(2)) : loose,at: beforeGroup)
        if following { tabs.append(f.w("c3")) }
        f.manager.tabs = tabs
        let rows = f.rendered().map(\.id)
        let last = try #require(rows.firstIndex(of: .workspace(f.w("qa").id)))
        if following { try #require(rows[last+1] == .workspace(f.w("c3").id)) }
        else { try #require(last == rows.count-1) }
        return f
    }
    private func geometry(_ f: F, native: Bool, id: UUID) throws -> ([SidebarWorkspaceReorderDropOverlay.Target], CGRect) {
        let targets = f.targets(native ? .native : .swiftUI)
        let frame = try #require(f.physicalMeasurements()[id]?.content)
        return (targets, frame)
    }
    @Test(arguments: [false,true], [false,true])
    func rowsAndGapsInsideTheProjectedGroupJoinWithoutAStatus(_ native: Bool, _ gap: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            try f.begin(row: .workspace(f.source.id))
            let (targets,frame) = try geometry(f,native: native,id: f.w("pa").id)
            let held = F.Held(f.source), group = f.manager.workspaceGroups
            let point = CGPoint(x: 180,y: gap ? frame.maxY+0.5 : frame.midY+1)
            let plan = try #require(try f.route(point: point,targets: targets))
            guard case .reorder(_,false,let target) = plan.action else { Issue.record("Expected group join, got \(plan.action)"); return }
            #expect(target == f.p)
            #expect(VerticalTabsSidebar.workspaceProjectedStatusDropLineLevel(for: plan,
                depthById: f.depths(),projection: f.projection()) == 3)
            #expect(f.commit(plan))
            #expect(f.source.groupId == f.p)
            #expect(f.source.todoState.ownStatus?.id == held.own && f.source.customColor == held.color)
            #expect(f.writes.isEmpty && f.manager.workspaceGroups == group)
        }
    }
    @Test(arguments: [false,true], [false,true])
    func aFollowingStatusRowKeepsTheLastMemberEdgeSplit(_ native: Bool, _ right: Bool) async throws {
        try await checkEdge(native: native,right: right,following: true,gap: false)
    }
    @Test(arguments: [false, true])
    func anOffscreenFollowingStatusRowStillKeepsTheRightEdgeJoin(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            try f.begin(row: .workspace(f.source.id))
            let (allTargets, frame) = try geometry(f, native: native, id: f.w("qa").id)
            let targets = allTargets.filter { $0.frame.minY < frame.maxY }
            try #require(!targets.contains { $0.workspaceId == f.w("c3").id })
            let rows = f.rendered().map(\.id)
            let last = try #require(rows.firstIndex(of: .workspace(f.w("qa").id)))
            try #require(rows[last + 1] == .workspace(f.w("c3").id))
            let held = F.Held(f.source)
            let typed = VerticalTabsSidebar.workspaceStatusDropTargets(items: f.rendered(), measured: targets)
            let frames = Dictionary(uniqueKeysWithValues: typed.map { ($0.workspaceId, $0.frame) })
            let point = try #require(SidebarDebugHeaderDrop.point(targetId: f.w("qa").id,
                zone: .bottomEdge, side: .right, targets: targets,
                renderItemId: .workspace(f.w("qa").id), pointFrames: frames))
            let plan = try #require(try f.route(point: point, targets: targets))
            guard case .reorder(_, false, let destination) = plan.action else {
                Issue.record("Offscreen following status row must retain group join, got \(plan.action)"); return
            }
            #expect(destination == f.q && f.commit(plan))
            #expect(f.source.groupId == f.q && f.writes.isEmpty)
            #expect(f.source.todoState.ownStatus?.id == held.own && f.source.customColor == held.color)
        }
    }
    @Test(arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func aModelLastGroupGivesStatusWithOtherStatusRowsVisibleOrOffscreen(_ native: Bool, _ settings: (Bool, Bool)) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (right, clipped) = settings
            let f = try fixture(following: false); defer { f.close() }
            var folds = try #require(f.state.statusGroups)
            folds.order = ["parked", "next", "done"]
            f.state.setStatusGroups(folds)
            await f.applyRows()
            try f.begin(row: .workspace(f.source.id))
            let (allTargets, frame) = try geometry(f, native: native, id: f.w("qa").id)
            let targets = clipped ? allTargets.filter { $0.frame.minY < frame.maxY } : allTargets
            try #require(targets.contains { $0.workspaceId == f.w("n1").id } == !clipped)
            let typed = VerticalTabsSidebar.workspaceStatusDropTargets(items: f.rendered(), measured: targets)
            let frames = Dictionary(uniqueKeysWithValues: typed.map { ($0.workspaceId, $0.frame) })
            let point = try #require(SidebarDebugHeaderDrop.point(targetId: f.w("qa").id,
                zone: .bottomEdge, side: right ? .right : .left, targets: targets,
                renderItemId: .workspace(f.w("qa").id), pointFrames: frames))
            let plan = try #require(try f.route(point: point, targets: targets))
            guard case .statusGroupDrop = plan.action else {
                Issue.record("Model-last group must give its status on both halves, got \(plan.action)"); return
            }
            #expect(f.commit(plan))
            #expect(f.source.groupId == nil && f.source.todoState.ownStatus?.id == "parked")
            #expect(f.source.customColor == "#555555" && f.writes.count == 1)
        }
    }
    @Test(arguments: [false,true], [false,true])
    func aLastGroupGivesItsStatusOnBothBottomHalves(_ native: Bool, _ right: Bool) async throws {
        try await checkEdge(native: native,right: right,following: false,gap: false)
    }
    @Test(arguments: [false,true], [false,true])
    func theRemainingGapAfterAGroupBelongsToTheStatus(_ native: Bool, _ right: Bool) async throws {
        try await checkEdge(native: native,right: right,following: true,gap: true)
    }
    private func checkEdge(native: Bool,right: Bool,following: Bool,gap: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(following: following); defer { f.close() }; await f.applyRows()
            try f.begin(row: .workspace(f.source.id))
            let (targets,frame) = try geometry(f,native: native,id: f.w("qa").id)
            let held = F.Held(f.source)
            let y: CGFloat
            if gap {
                let next = try #require(f.physicalMeasurements()[f.w("c3").id]?.content)
                try #require(next.minY > frame.maxY)
                y = frame.maxY + (next.minY - frame.maxY) * 0.75
            } else { y = frame.maxY - 0.5 }
            let plan = try #require(try f.route(point: .init(x: right ? 180 : 60,y: y),targets: targets))
            if following && right && !gap {
                guard case .reorder(_,false,let target) = plan.action else { Issue.record("Expected right-half join, got \(plan.action)"); return }
                #expect(target == f.q); #expect(f.commit(plan)); #expect(f.source.groupId == f.q)
                #expect(f.source.todoState.ownStatus?.id == held.own && f.source.customColor == held.color)
            } else {
                guard case .statusGroupDrop = plan.action else { Issue.record("Expected status landing below whole group, got \(plan.action)"); return }
                #expect(f.commit(plan)); #expect(f.source.groupId == nil)
                #expect(f.source.todoState.ownStatus?.id == "parked" && f.source.customColor == "#555555")
                let rows = f.rendered().map(\.id)
                let member = try #require(rows.firstIndex(of: .workspace(f.source.id)))
                #expect(rows[member-1] == .workspace(f.w("qa").id))
                #expect(f.writes.count == 1)
            }
        }
    }
    @Test(arguments: [false,true])
    func theUpperGapHalfAfterAGroupStillJoinsOnTheRight(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            try f.begin(row: .workspace(f.source.id))
            let (targets, frame) = try geometry(f, native: native, id: f.w("qa").id)
            let next = try #require(f.physicalMeasurements()[f.w("c3").id]?.content)
            let gap = next.minY - frame.maxY
            try #require(gap > 0)
            let held = F.Held(f.source)
            let plan = try #require(try f.route(point: .init(x: 180, y: frame.maxY + gap * 0.25), targets: targets))
            guard case .reorder(_, false, let target) = plan.action else { Issue.record("Upper gap must join, got \(plan.action)"); return }
            #expect(target == f.q && f.commit(plan))
            #expect(f.source.groupId == f.q && f.writes.isEmpty)
            #expect(f.source.todoState.ownStatus?.id == held.own && f.source.customColor == held.color)
        }
    }

    @Test(arguments: [false,true])
    func looseReorderKeepsTheExistingStatusPermutationAroundAGroup(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            let source = f.w("c1"), second = f.w("c2"), target = f.w("c3")
            let before = f.manager.tabs.map(\.id)
            let loose = [source.id, second.id, target.id], reordered = [second.id, target.id, source.id]
            var expected = before, index = 0
            for slot in expected.indices where loose.contains(expected[slot]) { expected[slot] = reordered[index]; index += 1 }
            try f.begin(row: .workspace(source.id))
            let (targets, frame) = try geometry(f, native: native, id: target.id)
            let plan = try #require(try f.route(point: .init(x: 60, y: frame.maxY - 0.5), targets: targets))
            guard case .statusGroupDrop = plan.action else { Issue.record("Expected loose status reorder"); return }
            #expect(f.commit(plan))
            #expect(f.reorderCalls == 1 && f.ordinaryCalls == 0)
            #expect(f.manager.tabs.map(\.id) == expected)
        }
    }

    @Test(arguments: [false,true])
    func groupAwareLandingWritesStatusBeforeMovingTheRoot(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(following: false); defer { f.close() }; await f.applyRows()
            try f.begin(row: .workspace(f.source.id))
            let before = f.manager.tabs.map(\.id)
            let (targets, frame) = try geometry(f, native: native, id: f.w("qa").id)
            let plan = try #require(try f.route(point: .init(x: 60, y: frame.maxY - 0.5), targets: targets))
            #expect(f.commit(plan))
            #expect(f.orderAtWrites == [before])
            #expect(f.manager.tabs.map(\.id) != before)
        }
    }

    @Test(arguments: [false,true], [false,true])
    func foldedLastGroupHeaderBottomGivesStatusOnBothSides(_ native: Bool, _ right: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(following: false); defer { f.close() }
            let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == f.p })
            f.manager.workspaceGroups[index].isCollapsed = true
            await f.applyRows()
            try #require(f.rendered().last?.id == .group(f.p))
            try f.begin(row: .workspace(f.source.id))
            let (targets, frame) = try geometry(f, native: native, id: f.w("pAnchor").id)
            let plan = try #require(try f.route(point: .init(x: right ? 180 : 60, y: frame.maxY - 0.5), targets: targets))
            guard case .statusGroupDrop = plan.action else { Issue.record("Folded last header must give status, got \(plan.action)"); return }
            #expect(f.commit(plan))
            #expect(f.source.groupId == nil && f.source.todoState.ownStatus?.id == "parked")
            let rows = f.rendered().map(\.id)
            let source = try #require(rows.firstIndex(of: .workspace(f.source.id)))
            #expect(rows[source - 1] == .group(f.p))
        }
    }

    @Test(arguments: [false,true])
    func legacyHeaderDragIsRefusedWithoutRowMetadata(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            let targets = f.targets(native ? .native : .swiftUI)
            for group in [f.p, f.q] {
                try f.begin(row: .group(group), legacy: true)
                for id in [f.w("l1").id, f.w("pa").id, SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")] {
                    let row = try #require(targets.first { $0.workspaceId == id })
                    #expect(try f.route(point: .init(x: 180, y: row.frame.midY), targets: targets) == nil,
                        "Legacy header \(group) at destination \(id)")
                }
                let bottom = try #require(targets.map { $0.frame.maxY }.max())
                #expect(try f.route(point: .init(x: 180, y: bottom + 20), targets: targets) == nil)
            }
        }
    }

    @Test(arguments: [false,true])
    func aMemberLeavesToALoosePlaceWithItsOwnStatusAndColor(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            let source = f.w("qa"); source.setCustomColor("#AABBCC")
            try f.begin(row: .workspace(source.id))
            let (targets,frame) = try geometry(f,native: native,id: f.w("l1").id)
            let plan = try #require(try f.route(point: .init(x: 60,y: frame.midY-1),targets: targets))
            #expect(f.commit(plan)); #expect(source.groupId == nil)
            #expect(source.customColor == "#AABBCC" && source.todoState.statusHidden)
            #expect(f.writes.isEmpty)
        }
    }
    @Test(arguments: [false,true])
    func aProjectedMemberLeavesItsGroupWhenDroppedIntoAnotherStatus(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            let source = f.w("qa")
            try f.begin(row: .workspace(source.id))
            let targets = f.targets(native ? .native : .swiftUI)
            let target = try #require(targets.first { $0.workspaceId == SidebarStatusHeaderIdentity.uuid(forStatusId: "next") })
            let plan = try #require(try f.route(point: .init(x: 180,y: target.frame.midY),targets: targets))
            guard case .statusGroupDrop = plan.action else { Issue.record("Expected another status's loose landing"); return }
            #expect(f.commit(plan))
            #expect(source.groupId == nil)
            #expect(source.todoState.ownStatus?.id == "next" && source.customColor == "#111111")
            #expect(f.projection()?.group(for: "next")?.memberWorkspaceIds.first == source.id)
            #expect(f.manager.workspaceGroups.first { $0.id == f.p }?.statusId == "parked")
            #expect(f.writes.count == 1)
        }
    }
    @Test(arguments: [false,true])
    func aProjectedHeaderAcceptsStatusDestinationsButKeepsOutsideRefusals(_ native: Bool) async throws { // (#cm-110.8)
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            try f.begin(row: .group(f.q))
            let targets = f.targets(native ? .native : .swiftUI),before = f.manager.tabs.map(\.id)
            // Rulings (5)/(11) keep the outside refusal; status/member destinations now set the nested group's own status. // (#cm-110.8)
            let looseRow = try #require(targets.first { $0.workspaceId == f.w("l1").id }) // (#cm-110.8)
            #expect(try f.route(point: .init(x: 180,y: looseRow.frame.midY),targets: targets) == nil) // (#cm-110.8)
            for id in [f.w("pa").id,SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")] { // (#cm-110.8)
                let row = try #require(targets.first { $0.workspaceId == id }) // (#cm-110.8)
                let plan = try #require(try f.route(point: .init(x: 180,y: row.frame.midY),targets: targets)) // (#cm-110.8)
                guard case .statusGroupDrop(let value, _) = plan.action else { Issue.record("Expected header status drop"); return } // (#cm-110.8)
                #expect(value.statusId == "parked" && value.setsStatus) // (#cm-110.8)
            } // (#cm-110.8)
            let bottom = try #require(targets.map { $0.frame.maxY }.max())
            #expect(try f.route(point: .init(x: 180,y: bottom+20),targets: targets) == nil)
            #expect(f.manager.tabs.map(\.id) == before)
        }
    }
}
