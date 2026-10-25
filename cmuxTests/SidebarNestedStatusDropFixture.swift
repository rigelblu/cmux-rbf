import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Real per-window model, both production target builders, and the actual guarded status-aware commit seam.
@MainActor
final class SidebarNestedStatusDropFixture {
    enum Scene: String, CaseIterable, Sendable { case f1, f2b, gap, r3, r3Before, interleaved } // (#cm-110.5) `interleaved`: tabs l1, c1 (Parked), l2, c2 (Parked), u, so a status group sits between loose rows in the tab order
    enum Renderer: String, CaseIterable, Sendable { case native, swiftUI }
    enum Side: String, CaseIterable, Sendable { case left, right; var x: CGFloat { self == .left ? 60 : 180 } }
    enum Role: String, CaseIterable, Sendable {
        case outside, own, ownLast, colorOnlyOwn, colorOnlyOwnLast, otherStatus, plainColor, pinned, grouped, pinnedMatching, groupedMatching, groupedColor
    }
    /// `gapBeforeP` is the gap under c3, the last status row. What sits under it depends on the section order (#cm-110.5): with `sectionOrder` unset the Statuses area is last (nothing below c3), with `.statusesFirst` the Workspaces header is the next row, where before `#cm-110.4` it was P's header.
    enum Zone: String, Sendable { case header, quietHeader, firstTop, lowerC2, lastEdge, memberGap, statusGap, gapBeforeP, belowAll }
    struct Held: Equatable {
        let own: String?, cmux: WorkspaceTaskStatus?, hidden: Bool, color: String?, pin: Bool, group: UUID?
        @MainActor init(_ w: Workspace) {
            own = w.todoState.ownStatus?.id; cmux = w.todoState.statusOverride?.status; hidden = w.todoState.statusHidden
            color = w.customColor; pin = w.isPinned; group = w.groupId
        }
    }
    struct Write: Equatable { let id: UUID, color: String }
    private struct Band: View, Equatable { var body: some View { Color.gray.frame(height: 28) } }
    let scene: Scene, role: Role
    let manager: TabManager, defaults: UserDefaults, suite: String
    let p: UUID, q: UUID
    var named: [String: Workspace] = [:]
    let state: SidebarState
    let windowId = UUID(), scope = SidebarStatusGroupDragSource(), drag = SidebarDragState()
    let controller = SidebarWorkspaceTableController()
    let container: SidebarWorkspaceTableContainerView, window: NSWindow
    var rows: [SidebarWorkspaceTableRowConfiguration] = []
    var selected: Set<UUID> = [], selectionIndex: Int?
    var sourceId: UUID?, sourceRow: SidebarWorkspaceRenderItemID?, token: UUID?
    var controls = true
    var projectsWorkspaceGroups = false
    var resolutions: [String] = [], writes: [Write] = [], reorderCalls = 0, ordinaryCalls = 0
    var newWorkspaceIndexes: [Int] = [] // (#cm-110.5) the tab index a tab dropped into a new workspace is made at
    var writesBeforeReorder: [Int] = [], freshReorderMembers: [[UUID]] = []
    var orderAtWrites: [[UUID]] = []
    var ordinaryOverride: ((SidebarWorkspaceReorderDropPlan) -> Bool)?
    private var legacyDragActions: SidebarWorkspaceTableActions?
    var list = WorkspaceStatusList(entries: [
        .init(id: "parked", name: "Parked", extends: .todo, color: "5: PARKED"),
        .init(id: "next", name: "Next", extends: .working, color: "1: NEXT"),
        .init(id: "done", name: "Done", color: "2: DONE")], source: .file)
    let hexes = ["parked": "#555555", "next": "#111111", "done": "#222222"]

    init(scene: Scene, role: Role = .outside, folded: Bool = false, empty: Bool = false, sectionOrder: WorkspaceSectionOrder? = nil) throws { // (#cm-110.5)
        self.scene = scene; self.role = role
        let isR3 = scene == .r3 || scene == .r3Before
        suite = "cmux.p5.nested.\(UUID().uuidString)"; defaults = try #require(UserDefaults(suiteName: suite))
        let model = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false,
            settings: UserDefaultsSettingsClient(defaults: defaults), closeTabWarningDefaults: defaults)
        manager = model
        var data: [String: Workspace] = [:]
        for key in isR3 ? ["l1","pa","qa","c1"] : ["u","l1","l2","color","c1","c2","c3","n1","n2","pinA","pinB","pa","qa"] { // (#cm-110.5) `l2`
            let workspace = Workspace(); workspace.hideTaskStatus(); data[key] = workspace
        }
        model.tabs = Array(data.keys.sorted().compactMap { data[$0] })
        let parent = try #require(model.createWorkspaceGroup(name: "P", childWorkspaceIds: [data["pa"]!.id]))
        let child = try #require(model.createWorkspaceGroup(name: "Q", childWorkspaceIds: [data["qa"]!.id]))
        p = parent; q = child
        _ = model.moveWorkspaceGroup(groupId: child, intoParent: parent)
        data["pAnchor"] = try #require(model.workspaceGroupAnchor(for: parent))
        data["qAnchor"] = try #require(model.workspaceGroupAnchor(for: child))
        for workspace in data.values { workspace.hideTaskStatus() }
        let statusList = WorkspaceStatusList(entries: [
            .init(id: "parked", name: "Parked", extends: .todo, color: "5: PARKED"),
            .init(id: "next", name: "Next", extends: .working, color: "1: NEXT"),
            .init(id: "done", name: "Done", color: "2: DONE")], source: .file)
        for key in ["c1","c2","c3"] {
            guard let workspace = data[key] else { continue }
            if empty { continue }
            if !((key == "c1" && role == .colorOnlyOwn) || (key == "c3" && role == .colorOnlyOwnLast)) { workspace.setOwnStatus(statusList.entry(id: "parked")!, list: statusList) }
            workspace.setCustomColor("#555555")
        }
        for key in ["n1","n2"] { if let workspace = data[key] { workspace.setOwnStatus(statusList.entry(id: "next")!, list: statusList); workspace.setCustomColor("#111111") } }
        data["color"]?.setCustomColor("#119933")
        if let a = data["pinA"], let b = data["pinB"] { model.setPinned(a,pinned: true); model.setPinned(b,pinned: true) }
        if role == .pinnedMatching { data["pinA"]?.setOwnStatus(statusList.entry(id: "parked")!,list: statusList) }
        if role == .groupedMatching { data["qa"]?.setOwnStatus(statusList.entry(id: "parked")!,list: statusList) }
        if role == .groupedColor { data["qa"]?.setCustomColor("#555555") }
        let nested = ["pAnchor","pa","qAnchor","qa"]
        let keys: [String]
        if scene == .interleaved { keys = ["l1","c1","l2","c2","u"] } // (#cm-110.5)
        else if isR3 { keys = ["l1"] + nested + ["c1"] }
        else {
            let prefix = ["pinA","pinB","u","l1","color"]
            let statuses = scene == .gap ? ["c1","c2","c3","n1","n2"] : ["n1","n2","c1","c2","c3"]
            keys = prefix + (scene == .f2b ? nested + statuses : statuses + nested)
        }
        model.tabs = keys.compactMap { data[$0] }
        named = data
        state = SidebarState(statusGroups: .init(collapsedStatusIds: folded ? ["parked","not-listed"] : ["not-listed"],
            order: scene == .gap ? ["parked","next","done","not-listed"] : ["next","done","parked","not-listed"],
            last: scene == .f2b || scene == .r3 || scene == .interleaved, belowRow: scene == .f1 || scene == .gap || scene == .r3Before ? "group:\(parent.uuidString)" : nil,
            sectionOrder: sectionOrder)) // (#cm-110.5)
        container = controller.makeContainerView()
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 240,height: 1400),styleMask: .borderless,backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.contentView = container
        model.windowId = windowId
    }
    /// A window that has already run once: the legacy record resolved into a section order, as the app does at the first action. // (#cm-110.5)
    func resolveSections() { _ = state.prepareWorkspaceSections(renderItems: { self.rendered() }) } // (#cm-110.5)
    func w(_ key: String) -> Workspace { named[key]! }
    var source: Workspace {
        switch role {
        case .outside: return w("u")
        case .own, .colorOnlyOwn: return w("c1")
        case .ownLast, .colorOnlyOwnLast: return w("c3")
        case .otherStatus: return w("n1")
        case .plainColor: return w("color")
        case .pinned, .pinnedMatching: return w("pinA")
        case .grouped, .groupedMatching, .groupedColor: return w("qa")
        }
    }
    func close() {
        legacyDragActions = nil
        drag.finishDrag(); controller.reorderDropDragExited(); controller.dismantleContainerView(container)
        window.contentView = nil; window.close(); manager.finalizeAllWorkspacesForWindowClose(); defaults.removePersistentDomain(forName: suite)
    }
    func projection() -> WorkspaceStatusGroupProjection? {
        VerticalTabsSidebar.statusGroupProjection(items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: manager.tabs,list: list,groups: projectsWorkspaceGroups ? manager.workspaceGroups : []),
            list: list,colorHexes: hexes,controlsEnabled: controls,storedOrder: state.statusGroups?.order,workspaceGroups: projectsWorkspaceGroups ? manager.workspaceGroups : [])
    }
    func colors(_ projection: WorkspaceStatusGroupProjection?) -> SidebarWorkspaceColorSectionProjection {
        VerticalTabsSidebar.colorSectionProjection(workspaces: manager.tabs.map {
            .init(id: $0.id,groupId: $0.groupId,isPinned: $0.isPinned,customColor: $0.customColor)
        },collapsedHexes: [],statusGroupProjection: projection,colorHexes: hexes,paletteEntries: [.init(name: "Plain",hex: "#119933")])
    }
    func rendered() -> [SidebarWorkspaceRenderItem] {
        let projected = projection(), groups = manager.workspaceGroups
        let base = VerticalTabsSidebar.baseRenderItems(tabs: manager.tabs, // (#cm-110.3) the production builder: a nested root under a status is drawn from the walk
            groupsById: Dictionary(uniqueKeysWithValues: groups.map { ($0.id,$0) }),orderedGroups: groups,statusGroupProjection: projected)
        return VerticalTabsSidebar.resolveRenderItems(colorSectionProjection: colors(projected),baseItems: base,
            statusGroupProjection: projected,folds: state.statusGroups ?? .init(),tabs: manager.tabs,groups: groups).items
    }
    var held: [UUID: Held] { Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id,Held($0)) }) }
    func depths() -> [UUID: Int] {
        let groups = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id,$0) })
        return SidebarNestedWorkspaceRows.depthById(groupsById: groups,
            effectiveMembership: SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: manager.tabs,groupsById: groups))
    }
    func snapshot() -> VerticalTabsSidebar.WorkspaceStatusDropSnapshot {
        .init(tabs: manager.tabs,workspaceGroups: manager.workspaceGroups,workspaceRenderItems: rendered(),statusGroupProjection: projection(),
            statusGroupFolds: state.statusGroups ?? .init(),colorSectionProjection: colors(projection()),selectedIds: selected,
            rootWorkspaceIds: manager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil,usesTopLevelRows: true))
    }
    func begin(row: SidebarWorkspaceRenderItemID, legacy: Bool = false) throws {
        let item = try #require(rendered().first { $0.id == row })
        let id = try #require(item.headerDropIdentity)
        sourceRow = row
        if legacy {
            let actions = try #require(legacyDragActions)
            try #require(actions.beginWorkspaceDragFromRow == nil)
            SidebarStatusGroupDragSource.begin(workspaceId: id, rowId: row, actions: actions)
        } else {
            let session = drag.beginDragging(tabId: id)
            sourceId = id; token = session.id
            scope.began(windowId: windowId,session: session,rowId: row)
        }
        let sessionId = try #require(token)
        let captured = try #require(scope.source(windowId: windowId,workspaceId: id,sessionId: sessionId,dragState: drag))
        try #require(captured.rowId == (legacy ? nil : row))
        if legacy { try #require(captured.kind == .unknown) }
    }
    struct RowGeometry {
        let raw: CGRect, cell: CGRect, content: CGRect
        let firstSubview: CGRect?
    }
    /// NSTableView's row rect includes spacing. The cell's real bounds measure the physical content, with no fabricated inset.
    func physicalMeasurements() -> [UUID: RowGeometry] {
        let table = container.tableView, overlay = container.reorderDropView
        var result: [UUID: RowGeometry] = [:]
        for (index,row) in rows.enumerated() {
            guard let cell = table.view(atColumn: 0,row: index,makeIfNecessary: true) else { continue }
            cell.layoutSubtreeIfNeeded()
            let content = cell.convert(cell.bounds,to: overlay)
            let cellFrame = cell.superview.map { $0.convert(cell.frame,to: overlay) } ?? content
            let subview = cell.subviews.first.map { $0.convert($0.bounds,to: overlay) }
            result[row.headerDropIdentity] = .init(raw: table.convert(table.rect(ofRow: index),to: overlay),
                cell: cellFrame,content: content,firstSubview: subview)
        }
        return result
    }
    func targets(_ renderer: Renderer) -> [SidebarWorkspaceReorderDropOverlay.Target] {
        let measured = controller.refreshReorderDropTargets(includeHeaders: true)
        if renderer == .native { return measured }
        let frames = physicalMeasurements().mapValues(\.content)
        let memberships = Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id,$0.groupId) })
        return VerticalTabsSidebar.statusAwareSwiftUITargets(items: rendered(),frames: frames,workspaceGroupIds: memberships)
    }
    func point(_ zone: Zone, fraction: CGFloat, side: Side, targets: [SidebarWorkspaceReorderDropOverlay.Target]) throws -> CGPoint {
        if zone == .belowAll {
            let bottom = try #require(physicalMeasurements().values.map { $0.content.maxY }.max())
            return .init(x: side.x,y: bottom+20)
        }
        let id: UUID
        switch zone {
        case .header: id = SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")
        case .quietHeader: id = SidebarStatusHeaderIdentity.uuid(forStatusId: "done")
        case .firstTop: id = w("c1").id
        case .lowerC2, .memberGap: id = w("c2").id
        case .lastEdge, .statusGap, .gapBeforeP: id = w("c3").id
        case .belowAll: fatalError("handled above")
        }
        let rows = targets.sorted { $0.frame.minY < $1.frame.minY }, index = try #require(rows.firstIndex { $0.workspaceId == id })
        let physical = physicalMeasurements()
        let measurement = try #require(physical[id])
        let frame = measurement.content
        let native = controller.refreshReorderDropTargets(includeHeaders: true)
        let typed = VerticalTabsSidebar.workspaceStatusDropTargets(items: rendered(),measured: targets)
        print("P5 geometry zone=\(zone.rawValue) id=\(id) spacing=\(container.tableView.intercellSpacing) raw=\(measurement.raw) cell=\(measurement.cell) content=\(frame) subview=\(String(describing: measurement.firstSubview)) nativeTarget=\(String(describing: native.first { $0.workspaceId == id }?.frame)) typedTarget=\(String(describing: typed.first { $0.workspaceId == id }?.frame))")
        try #require(measurement.raw == native.first { $0.workspaceId == id }?.frame)
        try #require(frame.width > 0 && frame.height > 0)
        if zone == .memberGap || zone == .statusGap || zone == .gapBeforeP {
            try #require(index+1 < rows.count)
            let nextContent = try #require(physical[rows[index+1].workspaceId]?.content)
            let gap = nextContent.minY-frame.maxY
            print("P5 physical gap after=\(frame) next=\(nextContent) actualGap=\(gap) tableSpacing=\(container.tableView.intercellSpacing.height)")
            try #require(abs(gap-2) < 0.01)
            try #require(abs(gap-container.tableView.intercellSpacing.height) < 0.01)
            return .init(x: side.x,y: frame.maxY + gap*fraction)
        }
        if zone == .firstTop { return .init(x: side.x,y: frame.minY) }
        if zone == .lastEdge { return .init(x: side.x,y: frame.maxY-fraction) }
        return .init(x: side.x,y: frame.minY+frame.height*fraction)
    }
    func route(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target]) throws -> SidebarWorkspaceReorderDropPlan? {
        let id = try #require(sourceId), token = try #require(token)
        let record = try #require(scope.source(windowId: windowId,workspaceId: id,sessionId: token,dragState: drag))
        let context = snapshot()
        let result = VerticalTabsSidebar.workspaceStatusRoute(point: point,targets: targets,snapshot: context,
            draggedId: id,sourceKind: record.kind,token: token,foreignDraggedIsPinned: nil,
            controlsEnabled: controls,hasUserStatusList: list.source != .cmux && !list.entries.isEmpty,
            ordinary: { p,t,boundary in VerticalTabsSidebar.workspaceOrdinaryReorderPlan(point: p,targets: t,snapshot: context,
                draggedTabId: id,foreignDraggedIsPinned: nil,permitsGroupEscape: true,permitsStatusBoundaryAlias: boundary) })
        return VerticalTabsSidebar.workspaceStatusOrOrdinaryPlan(status: result,ordinary: {
            VerticalTabsSidebar.workspaceOrdinaryReorderPlan(point: point,targets: targets,snapshot: context,draggedTabId: id,
                foreignDraggedIsPinned: nil,permitsGroupEscape: false)
        })
    }
    func legacy(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target]) throws -> SidebarWorkspaceReorderDropPlan? {
        VerticalTabsSidebar.workspaceLegacyBaseReorderPlan(point: point,targets: targets,snapshot: snapshot(),
            draggedTabId: try #require(sourceId),foreignDraggedIsPinned: nil)
    }
    func statusActions() -> WorkspaceStatusActions {
        WorkspaceStatusActions(list: list,origin: .mac,controlsEnabled: controls,
            resolveColor: { [self] text in resolutions.append(text); return ["5: PARKED":"#555555","1: NEXT":"#111111","2: DONE":"#222222"][text] },
            writeColor: { [self] hex,workspace in orderAtWrites.append(manager.tabs.map(\.id)); writes.append(.init(id: workspace.id,color: hex)); workspace.setCustomColor(hex) })
    }
    func ordinary(_ plan: SidebarWorkspaceReorderDropPlan) -> Bool {
        ordinaryCalls += 1
        switch plan.action {
        case .reorder(let index,let top,let group):
            return manager.reorderSidebarWorkspace(tabId: plan.draggedWorkspaceId,toIndex: index,isDragOperation: true,usesTopLevelRows: top,explicitGroupId: group)
        case .reorderGroup(let index):
            let before = manager.workspaceGroups.map(\.id)
            guard let current = before.firstIndex(of: plan.draggedWorkspaceId) else { return false }
            manager.moveWorkspaceGroup(groupId: plan.draggedWorkspaceId,toIndex: index)
            return manager.workspaceGroups.map(\.id) != before || index == current
        default: return false
        }
    }
    func commit(_ plan: SidebarWorkspaceReorderDropPlan) -> Bool {
        // The ordinary callback is the app's existing model mutation; status-aware actions use the exact production composition.
        switch plan.action { case .statusGroupDrop, .statusAreaBoundaryDrop: break; default: return ordinary(plan) }
        return VerticalTabsSidebar.performWorkspaceStatusAwarePlan(plan,windowId: windowId,dragState: drag,sourceRecorder: scope,
            selectedIds: selected,sidebarState: state,tabManager: manager,statusActions: { [self] in statusActions() },
            statusReorder: { [self] id,target,before,members in
                reorderCalls += 1; writesBeforeReorder.append(writes.count); freshReorderMembers.append(members)
                return manager.reorderWorkspaceWithinColorSection(tabId: id,targetWorkspaceId: target,insertBefore: before,memberWorkspaceIds: members)
            },
            currentProjection: { [self] in projection() },currentRenderItems: { [self] in rendered() },
            performOrdinary: { [self] plan in ordinaryOverride?(plan) ?? ordinary(plan) })
    }
    func applyRows() async {
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(colorScheme: .light,globalFontMagnificationPercent: 100,lazyContractProbe: .init())
        let items = rendered(), projection = projection(), depth = depths()
        rows = items.compactMap { item in
            switch item {
            case .statusesHeader:
                return VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusesArea,presentation: nil,
                    memberCount: projection?.groups.count ?? 0,memberIds: projection?.allMemberWorkspaceIds ?? [],folds: state.statusGroups ?? .init(),
                    environment: environment,onToggle: { [self] in state.toggleStatusesArea() })
            case .statusGroupHeader(let id):
                let entry = list.entry(id: id)!
                let members = projection?.group(for: id)?.memberWorkspaceIds ?? []
                return VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusGroup(id),
                    presentation: .init(name: WorkspaceStatusPresentation.text(entry.label),tintHex: hexes[id]!,glyph: nil,behavesAs: entry.behavesAs),
                    memberCount: members.count,memberIds: Set(members),folds: state.statusGroups ?? .init(),environment: environment,
                    onToggle: { [self] in state.toggleStatusGroup(id: id) })
            case .workspace(let id):
                let workspace = manager.tabs.first { $0.id == id }!
                var model = SidebarAppKitRowCellTests.makeModel(workspaceId: id,colorSchemeIsDark: false)
                model.depth = projection?.contains(workspaceId: id) == true ? 2 : depth[id] ?? 0
                return .init(workspaceRowModel: model,actions: rowActions(workspace,model: model),groupId: workspace.groupId,
                    isPinned: workspace.isPinned,environment: environment)
            default:
                return .init(id: item.id,workspaceId: item.headerDropIdentity!,groupId: item.id.groupId,isGroupHeader: item.id.groupId != nil,
                    isPinned: false,environment: environment,equivalenceValue: Band(),makeContent: { _,_ in AnyView(Band()) })
            }
        }
        container.tableView.intercellSpacing = NSSize(width: 0,height: 2)
        var actions = SidebarWorkspaceTableActions(attachScrollView: { _ in },closeWorkspace: { _ in },createWorkspaceAtEnd: {},createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { [self] id in
                let session = drag.beginDragging(tabId: id)
                sourceId = id; token = session.id
                scope.began(windowId: windowId, session: session, rowId: nil)
            },movingWorkspaceCount: { _ in 1 },endWorkspaceDrag: {},isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _,_,_ in nil },performWorkspaceDrop: { _,_,_ in false },commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {},currentDropIndicator: { nil },currentDropIndicatorScope: { .raw },canPerformBonsplitAction: { _,_ in false },
            moveBonsplitToExistingWorkspace: { _,_ in false },moveBonsplitToNewWorkspace: { [self] index,_ in newWorkspaceIndexes.append(index); return UUID() },didMoveBonsplitToWorkspace: { _ in }, // (#cm-110.5)
            updateDragAutoscroll: {},setBonsplitDropTargetCollectionActive: { _ in },setBonsplitDropIndicator: { _ in })
        actions.usesStatusHeaderDropTargets = { true }
        actions.resolveTabStatusLanding = { [self] point, targets, headersOnly in // (#cm-110.10)
            VerticalTabsSidebar.tabStatusLanding(point: point, targets: targets, snapshot: snapshot(), headersOnly: headersOnly, // (#cm-110.10)
                controlsEnabled: controls, hasUserStatusList: true) // (#cm-110.10)
        } // (#cm-110.10)
        legacyDragActions = actions
        controller.apply(rows: rows,actions: actions,workspaceIds: manager.tabs.map(\.id),selectedWorkspaceId: manager.selectedTabId,selectedScrollTargetWorkspaceId: nil)
        await withCheckedContinuation { c in RunLoop.main.perform(inModes: [.common]) { c.resume() } }
        container.layoutSubtreeIfNeeded(); container.tableView.layoutSubtreeIfNeeded()
    }
    func click(_ row: SidebarWorkspaceRenderItemID) async throws {
        let outcome = controller.dispatchRowClick(.init(rowId: row,modifiers: []))
        guard case .dispatched = outcome else { Issue.record("Expected actual row-click dispatch"); return }
        await withCheckedContinuation { c in RunLoop.main.perform(inModes: [.common]) { c.resume() } }
    }
    private func rowActions(_ workspace: Workspace, model: SidebarWorkspaceRowModel) -> SidebarAppKitRowActions {
        let commands = SidebarWorkspaceRowCommands(tab: workspace,tabManager: manager,notificationStore: nil,
            index: manager.tabs.firstIndex { $0.id == workspace.id } ?? 0,contextMenuWorkspaceIds: [workspace.id],remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,allRemoteContextMenuTargetsDisconnected: false,contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: .init(items: []),colorScheme: .light,refreshSnapshot: {},readSelectedTabIds: { [self] in selected },
            writeSelectedTabIds: { [self] in selected = $0 },readLastSelectionIndex: { [self] in selectionIndex },
            writeLastSelectionIndex: { [self] in selectionIndex = $0 },setSelectionToTabs: {},snapshotProvider: { nil })
        return SidebarAppKitRowActions(commands: commands,onOpenStatusURL: { _ in },onOpenWorkspaceDescriptionURL: { _ in },onOpenPullRequest: { _ in },onOpenPort: { _ in },
            onToggleChecklistExpansion: {},onToggleMetadataExpansion: {},onToggleMarkdownExpansion: {},onConsumeChecklistAddFieldActivation: {},
            checklistSetItemState: { _,_ in },checklistRemoveItem: { _ in },checklistAddItem: { _ in },checklistEditItem: { _,_ in },checklistMoveItem: { _,_ in },
            checklistOpenPane: {},checklistAddAttachments: { _ in },checklistRemoveAttachment: { _,_ in },checklistOpenAttachments: { _,_ in },
            onChecklistPopoverPresentedChange: { _ in },onBeginChecklistItemEdit: { _ in },onEndChecklistItemEdit: { _ in },applyTodoStatus: { _ in },hideTodoStatus: {},commitRename: { _ in })
    }
}

extension SidebarNestedStatusDropFixture {
    /// Puts a one-status list (`parked`) in the app's real store, as `SidebarWorkspaceSectionMigrationTests` does, so `AppDelegate.statusListInUse` reads it; the returned closure puts the delegate back. Call it inside `AppContextSerialGate.withExclusiveAppContext` and restore with `defer`. Without a list in use the header-drag refusals are never reached (a cut of each guard still passes), so the tests need it. (#cm-110.5)
    static func installStatusListInUse() throws -> () -> Void {
        let suite = "cmux.statuslist.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cmux.json")
        try ##"{"workspaceStatuses":[{"id":"parked","name":"Parked","extends":"todo","color":"#112233"}]}"##.write(to: file, atomically: true, encoding: .utf8)
        let store = WorkspaceStatusListStore(fileURL: file, defaults: defaults, resolveColor: { $0 }, paletteFingerprint: { "fixed" }, clock: ContinuousClock())
        store.load()
        try #require(store.list.source != .cmux, "The store holds the file's list")
        let previous = AppDelegate.shared, delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate
        return {
            AppDelegate.shared = previous
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
