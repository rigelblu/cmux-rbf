import CmuxFoundation
import CmuxSettings
import CmuxSidebar
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
struct SidebarStatusAreaLastBoundaryRoutingTests {
    enum HiddenArea: CaseIterable, Sendable { case collapsedArea, foldedGroups, emptyGroups }
    enum Half: CaseIterable, Sendable { case left, right }

    @Test(arguments: HiddenArea.allCases, Half.allCases)
    func belowTheLastHiddenAreaDetachesAGroupedWorkspaceAtRootOnBothHalves(_ area: HiddenArea, _ half: Half) throws {
        try requireWorkingLeftControl(area: area, pinned: false)
        let f = try Fixture(area: area, pinned: false)
        defer { f.close() }
        try f.requireUsableLastArea()
        let held = f.held(), otherOrder = f.unmovedIds, groups = f.manager.workspaceGroups
        let folds = try #require(f.state.statusGroups)
        let possiblePlan = f.plan(half)
        let plan = try #require(possiblePlan, "The actual status adapter must accept this below-last-area drop")
        f.assertCanonicalEndPaintHandoff(plan)
        #expect(f.perform(plan), "The actual model must perform the accepted drop")
        #expect(f.source.groupId == nil, "Below the whole Statuses area leaves Q and P on either half")
        #expect(f.rendered().last?.id == .workspace(f.source.id))
        let rows = f.rendered()
        let sourceRow = try #require(rows.firstIndex { $0.id == .workspace(f.source.id) })
        let areaRow = try #require(rows.firstIndex { $0.id == .statusesArea() })
        let qaRow = try #require(rows.firstIndex { $0.id == .workspace(f.qa.id) })
        #expect(qaRow < areaRow && areaRow < sourceRow, "Unmoved P/Q stay above the area and the detached source lands below")
        #expect(f.held() == held && f.unmovedIds == otherOrder && f.manager.workspaceGroups == groups)
        #expect(f.state.statusGroups?.order == folds.order && f.state.statusGroups?.collapsedStatusIds == folds.collapsedStatusIds
            && f.state.statusGroups?.areaCollapsed == folds.areaCollapsed)
    }

    @Test(arguments: HiddenArea.allCases, Half.allCases)
    func belowTheLastHiddenAreaMovesAPinnedWorkspaceToItsRootTierEndOnBothHalves(_ area: HiddenArea, _ half: Half) throws {
        try requireWorkingLeftControl(area: area, pinned: true)
        let f = try Fixture(area: area, pinned: true)
        defer { f.close() }
        try f.requireUsableLastArea()
        let held = f.held(), otherOrder = f.unmovedIds, record = f.state.statusGroups, groups = f.manager.workspaceGroups
        let possiblePlan = f.plan(half)
        let plan = try #require(possiblePlan, "The same pinned-tier operation must remain usable on either half")
        f.assertCanonicalEndPaintHandoff(plan)
        #expect(f.perform(plan), "The pinned source starts before other pinned rows, so this must actually move")
        #expect(f.source.isPinned && f.source.groupId == nil, "The right half must retain the same root membership as the left")
        let raw = f.manager.tabs.map(\.id)
        let sourceIndex = try #require(raw.firstIndex(of: f.source.id))
        let qaIndex = try #require(raw.firstIndex(of: f.qa.id))
        #expect(sourceIndex > qaIndex)
        #expect(f.rendered().last?.id == .statusesArea() || f.rendered().last?.id == .statusGroup("parked"))
        #expect(f.held() == held && f.unmovedIds == otherOrder && f.manager.workspaceGroups == groups)
        #expect(f.state.statusGroups == record)
    }

    private func requireWorkingLeftControl(area: HiddenArea, pinned: Bool) throws {
        let control = try Fixture(area: area, pinned: pinned)
        defer { control.close() }
        try control.requireUsableLastArea()
        let before = control.manager.tabs.map(\.id)
        try control.requireActualHiddenPinEndAlias()
        let possiblePlan = control.plan(.left)
        let plan = try #require(possiblePlan, "Control: the left half must produce a usable production plan")
        try #require(control.perform(plan), "Control: the real model must move")
        try #require(control.manager.tabs.map(\.id) != before && control.source.groupId == nil)
        try #require(control.source.isPinned == pinned)
        let rows = control.rendered()
        let source = try #require(rows.firstIndex { $0.id == .workspace(control.source.id) })
        let areaRow = try #require(rows.firstIndex { $0.id == .statusesArea() })
        try #require(pinned ? source < areaRow : source > areaRow)
    }

    private struct Held: Equatable {
        let own: String?, cmux: WorkspaceTaskStatus?, hidden: Bool, color: String?, pinned: Bool
        @MainActor init(_ workspace: Workspace) {
            own = workspace.todoState.ownStatus?.id; cmux = workspace.todoState.statusOverride?.status; hidden = workspace.todoState.statusHidden
            color = workspace.customColor; pinned = workspace.isPinned
        }
    }

    @MainActor
    private final class Fixture {
        let manager: TabManager
        let defaults: UserDefaults, suite: String
        let shape: HiddenArea, pinned: Bool
        let source: Workspace, otherPinned: Workspace, qa: Workspace, statusMember: Workspace
        let p: UUID, q: UUID
        let list = WorkspaceStatusList(entries: [.init(id: "parked", name: "Parked", extends: .todo, color: "5: PARKED")], source: .file)
        let state: SidebarState
        let scope = SidebarStatusGroupDragSource(), drag = SidebarDragState(), windowId = UUID()
        let token: UUID
        var ordinaryCalls = 0
        init(area: HiddenArea, pinned: Bool) throws {
            self.shape = area; self.pinned = pinned
            suite = "cmux.p4.r2.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false,
                settings: UserDefaultsSettingsClient(defaults: defaults), closeTabWarningDefaults: defaults)
            source = manager.addWorkspace(autoWelcomeIfNeeded: false)
            otherPinned = manager.addWorkspace(autoWelcomeIfNeeded: false)
            qa = manager.addWorkspace(autoWelcomeIfNeeded: false)
            statusMember = manager.addWorkspace(autoWelcomeIfNeeded: false)
            p = try #require(manager.createWorkspaceGroup(name: "P"))
            q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [qa.id]))
            state = SidebarState(statusGroups: .init(areaCollapsed: area == .collapsedArea,
                collapsedStatusIds: area == .foldedGroups ? ["parked", "not-listed"] : ["not-listed"], order: ["parked", "not-listed"], last: true))
            let session = drag.beginDragging(tabId: source.id); token = session.id
            scope.began(windowId: windowId, session: session, rowId: .workspace(source.id))
            _ = manager.moveWorkspaceGroup(groupId: q, intoParent: p)
            if pinned {
                manager.setPinned(source, pinned: true); manager.setPinned(otherPinned, pinned: true)
                manager.setWorkspaceGroupPinned(groupId: p, isPinned: true)
                if area == .emptyGroups { manager.setPinned(statusMember, pinned: true) }
            } else { manager.addWorkspaceToGroup(workspaceId: source.id, groupId: q) }
            let pa = try #require(manager.workspaceGroupAnchor(for: p)), qaAnchor = try #require(manager.workspaceGroupAnchor(for: q))
            manager.tabs = pinned ? [source, otherPinned, pa, qaAnchor, qa, statusMember] : [otherPinned, pa, qaAnchor, source, qa, statusMember]
            if area == .emptyGroups {
                manager.tabs.removeAll { $0.id == statusMember.id }
                manager.tabs.insert(statusMember, at: pinned ? 2 : 1)
            }
            for workspace in manager.tabs { workspace.hideTaskStatus() }
            if area != .emptyGroups { statusMember.setOwnStatus(try #require(list.entry(id: "parked")), list: list) }
        }
        func close() {
            drag.finishDrag()
            manager.finalizeAllWorkspacesForWindowClose()
            defaults.removePersistentDomain(forName: suite)
        }
        var unmovedIds: [UUID] { manager.tabs.filter { $0.id != source.id }.map(\.id) }
        func held() -> [UUID: Held] { Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, Held($0)) }) }
        func projection() -> WorkspaceStatusGroupProjection? {
            VerticalTabsSidebar.statusGroupProjection(items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: manager.tabs, list: list),
                list: list, colorHexes: ["parked": "#555555"], controlsEnabled: true, storedOrder: state.statusGroups?.order)
        }
        func colors(_ projection: WorkspaceStatusGroupProjection?) -> SidebarWorkspaceColorSectionProjection {
            VerticalTabsSidebar.colorSectionProjection(workspaces: manager.tabs.map {
                .init(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned, customColor: $0.customColor)
            }, collapsedHexes: [], statusGroupProjection: projection, colorHexes: ["parked": "#555555"], paletteEntries: [])
        }
        func rendered() -> [SidebarWorkspaceRenderItem] {
            let projection = projection()
            let base = SidebarWorkspaceRenderItem.renderItems(tabs: manager.tabs,
                groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) }), orderedGroups: manager.workspaceGroups)
            return VerticalTabsSidebar.resolveRenderItems(colorSectionProjection: colors(projection), baseItems: base,
                statusGroupProjection: projection, folds: state.statusGroups ?? .init(), tabs: manager.tabs, groups: manager.workspaceGroups).items
        }
        func requireUsableLastArea() throws {
            let rows = rendered(), projection = try #require(projection())
            let layout = SidebarStatusAreaLayout(items: rows, tabs: manager.tabs, groups: manager.workspaceGroups, statusProjection: projection)
            try #require(layout.saving(state: state.statusGroups)?.last == true)
            try #require(!projection.groups.isEmpty && rows.contains { $0.id == .statusesArea() })
            try #require(!rows.contains { row in
                guard case .workspace(let id) = row else { return false }
                return projection.contains(workspaceId: id)
            })
            try #require(manager.workspaceGroups.first { $0.id == q }?.parentGroupId == p)
            try #require(rows.contains { $0.id == .workspace(qa.id) })
            let ordinaryRows = rows.filter { row in
                switch row { case .statusesHeader, .statusGroupHeader: return false; default: return true }
            }
            try #require(ordinaryRows.last?.id == .workspace(qa.id))
            if shape == .emptyGroups { try #require(projection.groups.allSatisfy { $0.memberWorkspaceIds.isEmpty }) }
            else { try #require(projection.contains(workspaceId: statusMember.id)) }
            let raw = manager.tabs.map(\.id)
            try #require(raw.firstIndex(of: source.id)! < raw.firstIndex(of: qa.id)!)
            try #require(source.isPinned == pinned && (pinned ? source.groupId == nil : source.groupId == q))
        }
        func routingInputs(_ half: Half) -> (VerticalTabsSidebar.WorkspaceStatusDropSnapshot, [SidebarWorkspaceReorderDropOverlay.Target], CGPoint) {
            let items = rendered(), projection = projection()
            let targets: [SidebarWorkspaceReorderDropOverlay.Target] = items.enumerated().compactMap { index, item in
                guard let payload = item.headerDropIdentity else { return nil }
                return .init(workspaceId: payload, groupId: item.id.groupId ?? manager.tabs.first { $0.id == payload }?.groupId,
                    isGroupHeader: item.id.groupId != nil, frame: CGRect(x: 0, y: CGFloat(index) * 30, width: 300, height: 28), renderItemId: item.id)
            }
            let snapshot = VerticalTabsSidebar.WorkspaceStatusDropSnapshot(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups,
                workspaceRenderItems: items, statusGroupProjection: projection, statusGroupFolds: state.statusGroups ?? .init(),
                colorSectionProjection: colors(projection), selectedIds: [source.id])
            let point = CGPoint(x: half == .left ? 20 : 280, y: (targets.last?.frame.maxY ?? 0) + 20)
            return (snapshot, targets, point)
        }
        func requireActualHiddenPinEndAlias() throws {
            guard pinned, shape != .emptyGroups else { return }
            let (snapshot, targets, point) = routingInputs(.left)
            let possibleBase = VerticalTabsSidebar.workspaceLegacyBaseReorderPlan(point: point, targets: targets,
                snapshot: snapshot, draggedTabId: source.id, foreignDraggedIsPinned: nil)
            let base = try #require(possibleBase, "The actual legacy resolver must produce the hidden pin-end alias")
            try #require(base.indicator?.tabId == statusMember.id && base.indicator?.edge == .top)
            let isRoot: Bool
            if case .reorder(_, _, nil) = base.action { isRoot = true } else { isRoot = false }
            try #require(isRoot, "Expected actual root pin-end legacy action")
            let isInterimRefusal: Bool
            if case .refused = VerticalTabsSidebar.statusGroupInterimDrop(draggedTabId: source.id, basePlan: base,
                projection: snapshot.statusGroupProjection) { isInterimRefusal = true } else { isInterimRefusal = false }
            try #require(isInterimRefusal, "Expected retained P1 hidden-status-target refusal")
        }
        func plan(_ half: Half) -> SidebarWorkspaceReorderDropPlan? {
            let (snapshot, targets, point) = routingInputs(half)
            let ordinary: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], Bool, Bool) -> SidebarWorkspaceReorderDropPlan? = { [self] point, targets, escape, boundary in
                ordinaryCalls += 1
                return VerticalTabsSidebar.workspaceOrdinaryReorderPlan(point: point, targets: targets, snapshot: snapshot,
                    draggedTabId: source.id, foreignDraggedIsPinned: nil, permitsGroupEscape: escape, permitsStatusBoundaryAlias: boundary)
            }
            let captured = scope.source(windowId: windowId, workspaceId: source.id, sessionId: token, dragState: drag)
            let status = VerticalTabsSidebar.workspaceStatusRoute(point: point, targets: targets, snapshot: snapshot,
                draggedId: source.id, sourceKind: captured?.kind, token: token, foreignDraggedIsPinned: nil,
                controlsEnabled: true, hasUserStatusList: true, ordinary: { ordinary($0, $1, true, $2) })
            return VerticalTabsSidebar.workspaceStatusOrOrdinaryPlan(status: status, ordinary: { ordinary(point, targets, false, false) })
        }
        /// Checks the actual native feedback and SwiftUI parent handoffs; this is not an interactive/raster verdict.
        func assertCanonicalEndPaintHandoff(_ plan: SidebarWorkspaceReorderDropPlan) {
            let items = rendered(), projection = projection()
            let rowIds = items.compactMap(\.headerDropIdentity)
            let groupsById = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
            let effective = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: manager.tabs, groupsById: groupsById)
            let depths = SidebarNestedWorkspaceRows.depthById(groupsById: groupsById, effectiveMembership: effective)
            let level = SidebarNestedDropLine.level(for: plan, depthById: depths)
            #expect(plan.indicator == SidebarDropIndicator(tabId: nil, edge: .bottom), "Below the whole area advertises today's canonical end-of-list line")
            #expect(plan.indicatorScope == .raw && level == 0, "Both renderer handoffs need the root-level whole-area row space")
            let nativeRows = VerticalTabsSidebar.workspaceStatusFeedbackRows(plan: plan, items: items, projection: projection)
            #expect(nativeRows == rowIds, "Native feedback must include the actual final Statuses row rather than a hidden raw member")
            if let nativeRows {
                #expect(SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(draggedTabId: source.id,
                    dropIndicator: plan.indicator, lastTabId: nativeRows.last))
            }
            let parentRows = VerticalTabsSidebar.workspaceAreaBoundaryPaintRows(draggedId: source.id, scope: plan.indicatorScope,
                indicator: plan.indicator, level: level, items: items, projection: projection)
            #expect(parentRows == rowIds, "The real SwiftUI parent predicate must own the line outside drag source cells")
            let frames = Dictionary(uniqueKeysWithValues: rowIds.enumerated().map { index, id in
                (id, CGRect(x: 0, y: CGFloat(index) * 30, width: 300, height: 28))
            })
            let frame = parentRows.flatMap { rows in
                VerticalTabsSidebar.statusHeaderFinalAppendFrame(draggedId: source.id, indicator: plan.indicator,
                    rowIds: rows, frames: frames, level: 0, width: 300)
            }
            let expected = rowIds.last.flatMap { frames[$0] }.map { CGRect(x: 8, y: $0.maxY - 1, width: 284, height: 2) }
            #expect(frame == expected && frame != nil, "The shared parent end-line geometry must reach the visible last row")
            // Component check only: the actual ordinary-plan level convention in a flat window stays nil.
            let flatLevel = SidebarNestedDropLine.level(for: plan, depthById: [:])
            if case .reorder = plan.action { #expect(flatLevel == nil) }
            let flatParentRows = VerticalTabsSidebar.workspaceAreaBoundaryPaintRows(draggedId: source.id,
                scope: plan.indicatorScope, indicator: plan.indicator, level: flatLevel, items: items, projection: projection)
            #expect(flatParentRows == rowIds, "Flat nil-level ordinary plans still reach the existing whole-area parent")
            let flatFrame = flatParentRows.flatMap { rows in
                VerticalTabsSidebar.statusHeaderFinalAppendFrame(draggedId: source.id, indicator: plan.indicator,
                    rowIds: rows, frames: frames, level: flatLevel ?? 0, width: 300)
            }
            #expect(flatFrame == expected && flatFrame != nil)

        }
        func perform(_ plan: SidebarWorkspaceReorderDropPlan) -> Bool {
            switch plan.action {
            case .statusAreaBoundaryDrop(let boundary, _):
                return StatusAreaDropPerformer(state: state, movingGroupIds: [], currentTabs: { [self] in manager.tabs },
                    currentGroups: { [self] in manager.workspaceGroups }, currentProjection: { [self] in projection() },
                    currentRenderItems: { [self] in rendered() }, performOrdinary: { [self] move in
                        guard case .workspaces(let index, let top, let group) = move else { return false }
                        return manager.reorderSidebarWorkspace(tabId: source.id, toIndex: index, isDragOperation: true,
                            usesTopLevelRows: top, explicitGroupId: group)
                    }).perform(boundary, workspaceId: source.id, sourceKind: .workspace)
            case .reorder(let index, let top, let group):
                return manager.reorderSidebarWorkspace(tabId: source.id, toIndex: index, isDragOperation: true,
                    usesTopLevelRows: top, explicitGroupId: group)
            default: return false
            }
        }
    }
}
