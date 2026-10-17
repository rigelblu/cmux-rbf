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
@Suite(.serialized)
struct SidebarNestedStatusDropTests {
    private typealias F = SidebarNestedStatusDropFixture
    private struct Example: Sendable, CustomStringConvertible {
        let scene: F.Scene, renderer: F.Renderer, side: F.Side, role: F.Role, zone: F.Zone
        let fraction: Double, folded: Bool, empty: Bool
        nonisolated init(_ scene: F.Scene, _ renderer: F.Renderer, _ side: F.Side, _ role: F.Role,
                         _ zone: F.Zone, _ fraction: Double = 0.25, folded: Bool = false, empty: Bool = false) {
            self.scene = scene; self.renderer = renderer; self.side = side; self.role = role; self.zone = zone
            self.fraction = fraction; self.folded = folded; self.empty = empty
        }
        nonisolated var description: String {
            "\(scene.rawValue)_\(renderer.rawValue)_\(side.rawValue)_\(role.rawValue)_\(zone.rawValue)_\(fraction)_fold\(folded)_empty\(empty)"
        }
    }
    nonisolated private static var ownCases: [Example] {
        var out: [Example] = []
        for scene: F.Scene in [.f1,.f2b] { for renderer in F.Renderer.allCases { for side in F.Side.allCases {
            for role: F.Role in [.own,.colorOnlyOwn] {
                for zone: F.Zone in [.lowerC2,.lastEdge] {
                    for fraction in zone == .lastEdge ? [1.0,0.0] : [0.75] { out.append(.init(scene,renderer,side,role,zone,fraction)) }
                }
                for fraction in [0.25,0.5,0.75] { out.append(.init(scene,renderer,side,role,.memberGap,fraction)) }
            }
        }}}
        return out
    }
    nonisolated private static var outsideCases: [Example] {
        var out: [Example] = []
        for scene: F.Scene in [.f1,.f2b] { for renderer in F.Renderer.allCases { for side in F.Side.allCases {
            for (zone,fraction): (F.Zone,Double) in [(.header,0.25),(.firstTop,0),(.lastEdge,1),(.lastEdge,0),(.memberGap,0.25),(.memberGap,0.5),(.memberGap,0.75)] {
                out.append(.init(scene,renderer,side,.outside,zone,fraction))
            }
            for (folded,empty) in [(true,false),(false,true)] { out.append(.init(scene,renderer,side,.outside,.header,0.25,folded: folded,empty: empty)) }
            for role: F.Role in [.own,.colorOnlyOwn] { out.append(.init(scene,renderer,side,role,.header)) }
            for role: F.Role in [.ownLast,.colorOnlyOwnLast] { out.append(.init(scene,renderer,side,role,.firstTop,0)) }
            if scene == .f1 { for fraction in [0.25,0.5,0.75] { out.append(.init(scene,renderer,side,.outside,.gapBeforeP,fraction)) } }
        }}}
        for renderer in F.Renderer.allCases { for side in F.Side.allCases {
            for role: F.Role in [.outside,.own,.otherStatus] { for fraction in [0.25,0.5,0.75] {
                out.append(.init(.gap,renderer,side,role,.statusGap,fraction))
            }}
            out.append(.init(.f2b,renderer,side,.outside,.quietHeader))
        }}
        return out
    }
    nonisolated private static var fixedCases: [Example] {
        var out: [Example] = []
        for scene: F.Scene in [.f1,.f2b] { for renderer in F.Renderer.allCases { for side in F.Side.allCases {
            for role: F.Role in [.pinned,.grouped,.pinnedMatching,.groupedMatching,.plainColor,.otherStatus] { for inset in [1.0,0.0] { out.append(.init(scene,renderer,side,role,.lastEdge,inset)) } }
            for role: F.Role in [.pinned,.grouped] { out.append(.init(scene,renderer,side,role,.header)) }
        }}}
        return out
    }
    nonisolated private static var belowCases: [Example] {
        var out: [Example] = []
        for renderer in F.Renderer.allCases { for side in F.Side.allCases {
            for role: F.Role in [.outside,.own,.colorOnlyOwn,.plainColor,.pinned,.grouped,.groupedMatching,.groupedColor] {
                out.append(.init(.f2b,renderer,side,role,.belowAll))
            }
        }}
        return out
    }

    @Test(arguments: Self.ownCases)
    private func sameGroupNestedMovesPermuteOnlyTheirSlotsAfterAnActualRowClick(_ e: Example) async throws {
        try await checkStatusDrop(e, clickFirst: true, measuredLegacyControl: true)
    }
    @Test(arguments: Self.outsideCases)
    private func nestedHeadersEdgesAndGapsApplyTheChosenStatusOnceOrMoveAnAuthoritativeMember(_ e: Example) async throws {
        try await checkStatusDrop(e)
    }
    @Test(arguments: Self.fixedCases)
    private func nestedPinnedGroupedAndOtherStatusSourcesKeepTheirStructuralPolicy(_ e: Example) async throws {
        try await checkStatusDrop(e)
    }

    private func checkStatusDrop(_ e: Example, clickFirst: Bool = false, measuredLegacyControl: Bool = false) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: e.scene,role: e.role,folded: e.folded,empty: e.empty)
            defer { f.close() }
            if e.zone == .quietHeader { f.source.setOwnStatus(try #require(f.list.entry(id: "parked")),list: f.list); f.source.setCustomColor(f.hexes["parked"]) }
            await f.applyRows()
            try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == f.p)
            if clickFirst {
                try await f.click(.workspace(f.source.id))
                try #require(f.manager.selectedTabId == f.source.id && f.selected == [f.source.id])
            } else { f.selected = [f.source.id,f.w("l1").id] }
            try f.begin(row: .workspace(f.source.id))
            let targets = f.targets(e.renderer), point = try f.point(e.zone,fraction: e.fraction,side: e.side,targets: targets)
            if measuredLegacyControl && e.zone != .memberGap {
                let roots = f.manager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil,usesTopLevelRows: true)
                let lastMember = try #require(roots.firstIndex(of: f.w("c3").id))
                let rawSuccessor = lastMember+1 < roots.count ? roots[lastMember+1] : nil
                try #require(rawSuccessor == (e.scene == .f1 ? f.w("pAnchor").id : nil),"The actual model root successor must match the measured F1/F2b legacy control")
                let possibleLegacy = try f.legacy(point: point,targets: targets)
                let legacy = try #require(possibleLegacy)
                let expected: SidebarDropIndicator = e.zone == .lowerC2 ? .init(tabId: f.w("c3").id,edge: .top)
                    : (e.scene == .f1 ? .init(tabId: f.w("pAnchor").id,edge: .top) : .init(tabId: nil,edge: .bottom))
                try #require(legacy.indicator == expected, "The measured old nested alias is a control, not the new status result")
            }
            if e.zone == .quietHeader { try #require(f.source.attentionTaskStatus(todoControlsEnabled: true,list: f.list) == .todo) }
            let target = e.zone == .quietHeader ? "done" : (e.zone == .statusGap && e.fraction >= 0.5 ? "next" : "parked")
            let beforeMembers = try #require(f.projection()?.group(for: target)?.memberWorkspaceIds)
            let write = !beforeMembers.contains(f.source.id), structurallyFixed = f.source.isPinned || f.source.groupId != nil
            let before = f.held, raw = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups, selected = f.manager.selectedTabId
            let sourceId = f.source.id, others = raw.filter { !Set(beforeMembers+[sourceId]).contains($0) }
            var expected = beforeMembers.filter { $0 != sourceId }
            if !structurallyFixed {
                if e.zone == .header || e.zone == .quietHeader || e.zone == .firstTop || (e.zone == .statusGap && e.fraction >= 0.5) { expected.insert(sourceId,at: 0) }
                else if e.zone == .lowerC2 || e.zone == .memberGap {
                    expected.insert(sourceId,at: try #require(expected.firstIndex(of: f.w("c2").id))+1)
                } else { expected.append(sourceId) }
            }
            let possible = try f.route(point: point,targets: targets)
            let plan = try #require(possible, "Actual typed nested target must admit the decided drop")
            guard case .statusGroupDrop(let value,_) = plan.action else { Issue.record("Expected shared status-aware action"); return }
            #expect(value.statusId == target && value.setsStatus == write)
            if e.zone == .lastEdge { #expect(plan.indicator == .init(tabId: f.w("c3").id,edge: .bottom)) }
            if e.zone == .memberGap {
                #expect(plan.indicator == (e.fraction < 0.5 ? .init(tabId: f.w("c2").id,edge: .bottom) : .init(tabId: f.w("c3").id,edge: .top)))
            }
            let frames = Dictionary(uniqueKeysWithValues: targets.map { ($0.workspaceId,$0.frame) })
            let actualScope = try #require(VerticalTabsSidebar.workspaceStatusDropScopeId(scope: plan.indicatorScope,projection: f.projection()))
            #expect(actualScope == target)
            let actualMembers = try #require(f.projection()?.group(for: actualScope)?.memberWorkspaceIds)
            let frame = VerticalTabsSidebar.workspaceStatusDropGapFrame(statusId: actualScope,draggedId: sourceId,indicator: plan.indicator,
                items: f.rendered(),memberWorkspaceIds: actualMembers,frames: frames,width: 240)
            #expect(frame != nil && SidebarNestedDropLine.level(for: plan,depthById: f.depths()) == 2)
            #expect(f.commit(plan))
            if write {
                let entry = try #require(f.list.entry(id: target))
                #expect(!f.source.todoState.statusHidden)
                if let builtin = WorkspaceTaskStatus(rawValue: target) {
                    #expect(f.source.todoState.ownStatus == nil && f.source.todoState.statusOverride?.status == builtin)
                    #expect(f.source.statusResolution(list: f.list) == .cmuxInEffect(entry,offered: true))
                } else {
                    #expect(f.source.todoState.ownStatus?.id == target)
                    #expect(f.source.statusResolution(list: f.list) == .ownInEffect(entry))
                }
                let rawColor = ["parked":"5: PARKED","next":"1: NEXT","done":"2: DONE"][target]!
                #expect(f.resolutions == [rawColor] && f.writes == [.init(id: sourceId,color: f.hexes[target]!)])
            } else { #expect(f.writes.isEmpty && f.resolutions.isEmpty && F.Held(f.source) == before[sourceId]) }
            #expect(f.held.filter { $0.key != sourceId } == before.filter { $0.key != sourceId })
            #expect(f.manager.workspaceGroups == groups && f.manager.selectedTabId == selected)
            if structurallyFixed {
                #expect(f.manager.tabs.map(\.id) == raw && f.reorderCalls == 0)
                #expect(f.source.groupId == before[sourceId]?.group && f.source.isPinned == before[sourceId]?.pin)
                #expect(f.projection()?.contains(workspaceId: sourceId) == false)
            } else {
                #expect(f.projection()?.group(for: target)?.memberWorkspaceIds == expected)
                let afterIds = f.manager.tabs.map(\.id), moved = Set(beforeMembers+[sourceId])
                #expect(afterIds.filter { !moved.contains($0) } == others)
                #expect(raw.indices.filter { moved.contains(raw[$0]) } == afterIds.indices.filter { moved.contains(afterIds[$0]) })
                #expect(f.reorderCalls == (expected.count > 1 ? 1 : 0))
                #expect(f.writesBeforeReorder.allSatisfy { $0 == (write ? 1 : 0) })
                #expect(f.freshReorderMembers.allSatisfy { $0.contains(sourceId) })
            }
            if e.folded { #expect(f.state.statusGroups?.collapsedStatusIds.contains("parked") == true && !f.rendered().contains { $0.id == .workspace(sourceId) }) }
            if e.zone == .quietHeader { #expect(f.source.attentionTaskStatus(todoControlsEnabled: true,list: f.list) == .done) }
        
        }
    }

    @Test(arguments: Self.belowCases)
    private func nestedBelowAllKeepsTheEndDescriptorAndDistinctRefusalOrProjectionResult(_ e: Example) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f2b,role: e.role); defer { f.close() }
            await f.applyRows(); try f.begin(row: .workspace(f.source.id))
            let targets = f.targets(e.renderer), point = try f.point(.belowAll,fraction: 0,side: e.side,targets: targets)
            let before = f.held, raw = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups, record = f.state.statusGroups
            let source = f.source.id, possible = try f.route(point: point,targets: targets)
            if e.role == .pinned { try #require(f.manager.tabs.filter(\.isPinned).map(\.id) == [f.w("pinA").id,f.w("pinB").id]) }
            if e.role == .own || e.role == .colorOnlyOwn || e.role == .plainColor {
                #expect(possible == nil)
                if let possible { #expect(!f.commit(possible)) }
                #expect(f.held == before && f.manager.tabs.map(\.id) == raw && f.state.statusGroups == record)
            } else {
                let plan = try #require(possible)
                #expect(plan.indicator == .init(tabId: nil,edge: .bottom) && plan.indicatorScope == .raw)
                #expect(f.commit(plan))
                #expect(f.source.groupId == nil && f.source.isPinned == before[source]?.pin)
                #expect(f.source.todoState.ownStatus?.id == before[source]?.own && f.source.customColor == before[source]?.color)
                let rows = f.rendered(), area = try #require(rows.firstIndex { $0.id == .statusesArea() })
                let row = try #require(rows.firstIndex { $0.id == .workspace(source) })
                if e.role == .pinned {
                    #expect(row < area && f.state.statusGroups == record)
                    #expect(f.manager.tabs.filter(\.isPinned).map(\.id) == [f.w("pinB").id,f.w("pinA").id])
                }
                else if e.role == .groupedMatching || e.role == .groupedColor {
                    #expect(f.projection()?.group(for: "parked")?.memberWorkspaceIds.contains(source) == true && f.state.statusGroups == record)
                } else {
                    #expect(row == rows.count-1 && row > area && f.state.statusGroups?.last == false && f.state.statusGroups?.belowRow == "workspace:\(source.uuidString)")
                }
                #expect(f.held.filter { $0.key != source } == before.filter { $0.key != source })
                #expect(f.manager.workspaceGroups == groups)
                #expect(f.manager.tabs.map(\.id).filter { $0 != source } == raw.filter { $0 != source })
            }
            #expect(f.writes.isEmpty && f.resolutions.isEmpty && f.reorderCalls == 0)
        
        }
    }

    enum Refusal: CaseIterable, Sendable { case controlsOff, removedTarget }
    @Test(arguments: [F.Scene.f1,.f2b], F.Renderer.allCases)
    private func cachedNestedStatusPlansRefuseChangedControlsAndTargetsBeforeAnyWrite(_ scene: F.Scene,_ renderer: F.Renderer) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            for invalid in Refusal.allCases {
                let f = try F(scene: scene); defer { f.close() }
                await f.applyRows(); try f.begin(row: .workspace(f.source.id))
                let targets = f.targets(renderer), point = try f.point(.header,fraction: 0.25,side: .left,targets: targets)
                let possible = try f.route(point: point,targets: targets), plan = try #require(possible)
                guard case .statusGroupDrop(let value,_) = plan.action else { Issue.record("Expected accepted current-plan control"); return }
                try #require(value.statusId == "parked")
                let held = f.held, raw = f.manager.tabs.map(\.id), record = f.state.statusGroups
                switch invalid {
                case .controlsOff: f.controls = false
                case .removedTarget: f.list = .init(entries: f.list.entries.filter { $0.id != "parked" },source: .file)
                }
                #expect(!f.commit(plan))
                #expect(f.writes.isEmpty && f.resolutions.isEmpty && f.reorderCalls == 0)
                #expect(f.held == held && f.manager.tabs.map(\.id) == raw && f.state.statusGroups == record)
            }
        
        }
    }

    @Test(arguments: [F.Scene.f1,.f2b])
    private func nestedStatusHeadersFoldThroughActualClickAndRestoreTheirOwnWindowValues(_ scene: F.Scene) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: scene); defer { f.close() }
            await f.applyRows()
            let projection = try #require(f.projection()), beforeGroups = f.manager.workspaceGroups, beforeHeld = f.held
            let selected = f.manager.selectedTabId, original = try #require(f.state.statusGroups)
            for renderer in F.Renderer.allCases {
                let typed = VerticalTabsSidebar.workspaceStatusDropTargets(items: f.rendered(),measured: f.targets(renderer))
                #expect(typed.contains { $0.kind == .statusesArea } && typed.contains { $0.kind == .statusGroupHeader(statusId: "parked") })
            }
            let header = try #require(f.rows.first { $0.id == .statusGroup("parked") }), model = try #require(header.appKitGroupHeaderModel)
            #expect(model.depth == 1 && !model.hasOwnWorkspace && !model.isAnchorActive && !model.isPinned)
            #expect(header.appKitUnreadDependencyWorkspaceIds == Set(projection.group(for: "parked")!.memberWorkspaceIds))
            #expect(VerticalTabsSidebar.rowDepth(of: f.w("c1").id,rowDepthById: f.depths(),statusGroupProjection: projection) == 2)
            #expect(f.depths()[f.p] == 0 && f.depths()[f.q] == 1 && f.depths()[f.w("qa").id] == 2)
            try await f.click(.statusGroup("parked")); await f.applyRows()
            #expect(f.state.statusGroups?.collapsedStatusIds.contains("parked") == true)
            #expect(!f.rendered().contains { $0.id == .workspace(f.w("c1").id) })
            let folded = try #require(f.rows.first { $0.id == .statusGroup("parked") })
            let rebuild = try #require(folded.appKitGroupHeaderUnreadRebuild)
            let members = try #require(f.projection()?.group(for: "parked")?.memberWorkspaceIds)
            var summaries = Dictionary(uniqueKeysWithValues: members.map { ($0,SidebarWorkspaceUnreadSummary(unreadCount: 2,latestNotificationText: nil)) })
            summaries[f.w("qa").id] = SidebarWorkspaceUnreadSummary(unreadCount: 100,latestNotificationText: nil)
            #expect(rebuild(SidebarUnreadSnapshot(summaryByWorkspaceId: summaries)).anchorUnreadCount == members.count*2)
            summaries[f.w("c1").id] = SidebarWorkspaceUnreadSummary(unreadCount: 5,latestNotificationText: nil)
            #expect(rebuild(SidebarUnreadSnapshot(summaryByWorkspaceId: summaries)).anchorUnreadCount == members.count*2+3)
            #expect(f.manager.selectedTabId == selected && f.manager.workspaceGroups == beforeGroups && f.held == beforeHeld)
            try await f.click(.statusesArea()); await f.applyRows()
            #expect(f.state.statusGroups?.areaCollapsed == true && !f.rendered().contains { $0.id == .statusGroup("parked") })
            let layout = SidebarStatusAreaLayout(items: f.rendered(),tabs: f.manager.tabs,groups: f.manager.workspaceGroups,statusProjection: f.projection())
            let saved = try #require(layout.saving(state: f.state.statusGroups))
            let snapshot = SessionSidebarSnapshot(isVisible: true,selection: .tabs,width: 240,statusGroups: saved)
            let restored = try JSONDecoder().decode(SessionSidebarSnapshot.self,from: JSONEncoder().encode(snapshot))
            #expect(restored.statusGroups == saved && saved.collapsedStatusIds.contains("not-listed") && saved.order == original.order)
            let ids = f.rendered().map(\.id); f.state.setStatusGroups(restored.statusGroups)
            #expect(f.rendered().map(\.id) == ids && f.manager.workspaceGroups == beforeGroups && f.manager.selectedTabId == selected)
        
        }
    }

    @Test func aRealChildHeaderReparentKeepsTheUnmovedParentAboveTheArea() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .r3); defer { f.close() }
            try f.begin(row: .group(f.q))
            let id = try #require(f.sourceId), token = try #require(f.token)
            let source = try #require(f.scope.source(windowId: f.windowId,workspaceId: id,sessionId: token,dragState: f.drag))
            try #require(source.kind == .workspaceGroupHeader(groupId: f.q))
            try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == f.p)
            let layout = SidebarStatusAreaLayout(items: f.rendered(),tabs: f.manager.tabs,groups: f.manager.workspaceGroups,statusProjection: f.projection())
            let original = try #require(layout.saving(state: f.state.statusGroups)); f.state.setStatusGroups(original)
            try #require(original.last == true && original.aboveRow == "group:\(f.p.uuidString)")
            let before = f.held, parent = try #require(f.manager.workspaceGroups.first { $0.id == f.p })
            var ordinary = 0
            let plan = SidebarStatusAreaBoundaryDropPlan(boundary: .belowAll,
                move: .workspaces(targetIndex: f.manager.tabs.count,usesTopLevelRows: true,explicitGroupId: nil))
            let performer = StatusAreaDropPerformer(state: f.state,movingGroupIds: [f.q],currentTabs: { f.manager.tabs },
                currentGroups: { f.manager.workspaceGroups },currentProjection: { f.projection() },currentRenderItems: { f.rendered() },
                performOrdinary: { move in
                    ordinary += 1
                    _ = f.manager.moveWorkspaceGroup(groupId: f.q,intoParent: nil)
                    guard f.manager.workspaceGroups.first(where: { $0.id == f.q })?.parentGroupId == nil else { return false }
                    if case .workspaces(let index,let top,let group) = move {
                        _ = f.manager.reorderSidebarWorkspace(tabId: id,toIndex: index,isDragOperation: true,usesTopLevelRows: top,explicitGroupId: group)
                    }
                    return true // Actual parent P→root mutation above, even if the following raw reorder is an accepted no-op.
                })
            #expect(performer.perform(plan,workspaceId: id,sourceKind: source.kind))
            try #require(ordinary == 1 && f.manager.workspaceGroups.first(where: { $0.id == f.q })?.parentGroupId == nil)
            assertChildPlacement(f,original: original)
            #expect(f.manager.workspaceGroups.first { $0.id == f.p } == parent && f.held == before)
        
        }
    }

    private struct BoundaryExample: Sendable, CustomStringConvertible {
        let renderer: F.Renderer, side: F.Side, upper: Bool, parentAfter: Bool
        nonisolated init(_ renderer: F.Renderer,_ side: F.Side,_ upper: Bool,_ parentAfter: Bool) { self.renderer = renderer; self.side = side; self.upper = upper; self.parentAfter = parentAfter }
        nonisolated var description: String { "\(renderer.rawValue)_\(side.rawValue)_\(upper ? "aboveArea" : "belowAll")_parentAfter\(parentAfter)" }
    }
    nonisolated private static var childBoundaries: [BoundaryExample] {
        F.Renderer.allCases.flatMap { renderer in F.Side.allCases.flatMap { side in [false,true].flatMap { upper in [false,true].map { BoundaryExample(renderer,side,upper,$0) } } } }
    }
    @Test(arguments: Self.childBoundaries)
    private func aChildHeaderUsesTheActualSharedPlanAndCommitAtBothOuterAreaBoundaries(_ e: BoundaryExample) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: e.parentAfter ? .r3Before : .r3); defer { f.close() }
            await f.applyRows(); try f.begin(row: .group(f.q))
            let original = try #require(f.state.statusGroups), before = f.held
            let parent = try #require(f.manager.workspaceGroups.first { $0.id == f.p })
            let targets = f.targets(e.renderer)
            let point: CGPoint
            if e.upper {
                let frame = try #require(targets.first { $0.workspaceId == SidebarStatusHeaderIdentity.statusesAreaUUID }?.frame)
                point = .init(x: e.side.x,y: frame.minY+frame.height*0.25)
            } else { point = try f.point(.belowAll,fraction: 0,side: e.side,targets: targets) }
            let possible = try f.route(point: point,targets: targets), plan = try #require(possible, "Nested child header has an explicit outer-area root destination")
            #expect(plan.indicator == (e.upper ? .init(tabId: SidebarStatusHeaderIdentity.statusesAreaUUID,edge: .top) : .init(tabId: nil,edge: .bottom)) && plan.indicatorScope == .raw)
            #expect(f.commit(plan), "The production composition must perform the model reparent itself")
            #expect(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == nil)
            let actualRoots = f.manager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil,usesTopLevelRows: true)
            let qRoot = try #require(actualRoots.firstIndex(of: f.w("qAnchor").id))
            if e.upper && e.parentAfter {
                let pRoot = try #require(actualRoots.firstIndex(of: f.w("pAnchor").id))
                #expect(qRoot < pRoot)
            } else { #expect(actualRoots.last == f.w("qAnchor").id) }
            if e.parentAfter {
                let rows = f.rendered().map(\.id), area = try #require(rows.firstIndex(of: .statusesArea()))
                let parentRow = try #require(rows.firstIndex(of: .group(f.p))), childRow = try #require(rows.firstIndex(of: .group(f.q)))
                let parentMember = try #require(rows.firstIndex(of: .workspace(f.w("pa").id))), childMember = try #require(rows.firstIndex(of: .workspace(f.w("qa").id)))
                #expect(parentRow > area && parentMember > area)
                if e.upper { #expect(childRow < area && childMember < area) }
                else { #expect(childRow > parentMember && rows.last == .workspace(f.w("qa").id)) }
                #expect(f.state.statusGroups?.aboveRow == (e.upper ? "group:\(f.q.uuidString)" : "workspace:\(f.w("l1").id.uuidString)"))
                #expect(f.state.statusGroups?.belowRow == "group:\(f.p.uuidString)" && f.state.statusGroups?.last == false)
                #expect(f.state.statusGroups?.order == original.order && f.state.statusGroups?.collapsedStatusIds == original.collapsedStatusIds)
            } else if e.upper {
                let rows = f.rendered().map(\.id), area = try #require(rows.firstIndex(of: .statusesArea()))
                let parentRow = try #require(rows.firstIndex(of: .group(f.p))), childRow = try #require(rows.firstIndex(of: .group(f.q)))
                let childMemberRow = try #require(rows.firstIndex(of: .workspace(f.w("qa").id)))
                #expect(parentRow < childRow && childRow < area && childMemberRow < area && f.state.statusGroups?.last == true)
                #expect(f.state.statusGroups?.aboveRow == "group:\(f.q.uuidString)" && f.state.statusGroups?.belowRow == nil)
                #expect(f.state.statusGroups?.order == original.order && f.state.statusGroups?.collapsedStatusIds == original.collapsedStatusIds)
            } else { assertChildPlacement(f,original: original) }
            #expect(f.manager.workspaceGroups.first { $0.id == f.p } == parent)
            #expect(f.held == before && f.writes.isEmpty && f.resolutions.isEmpty)
        
        }
    }
    private func assertChildPlacement(_ f: F,original: WorkspaceStatusGroupsState) {
        let rows = f.rendered().map(\.id), area = rows.firstIndex(of: .statusesArea())!
        #expect(rows.firstIndex(of: .group(f.p))! < area && rows.firstIndex(of: .workspace(f.w("pa").id))! < area)
        #expect(rows.firstIndex(of: .group(f.q))! > area && rows.firstIndex(of: .workspace(f.w("qa").id))! > area)
        #expect(f.state.statusGroups?.aboveRow == "group:\(f.p.uuidString)" && f.state.statusGroups?.belowRow == "group:\(f.q.uuidString)")
        #expect(f.state.statusGroups?.last == false && f.state.statusGroups?.order == original.order
            && f.state.statusGroups?.collapsedStatusIds == original.collapsedStatusIds)
    }
    private enum ChildGuard: CaseIterable, Equatable, Sendable { case selectedBlock, inheritedPin, ownPin, emptyChild }
    @Test(arguments: ChildGuard.allCases, Self.guardBoundaries)
    private func childBoundarySourceControlsPreservePinTierAndTheOrdinaryContinuation(_ invalid: ChildGuard,_ e: BoundaryExample) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .r3); defer { f.close() }
            switch invalid {
            case .selectedBlock:
                f.selected = [f.w("qAnchor").id,f.w("pAnchor").id]
                try #require(f.selected.count == 2)
            case .inheritedPin:
                f.manager.setWorkspaceGroupPinned(groupId: f.p,isPinned: true)
                try #require(f.manager.workspaceGroups.first { $0.id == f.p }?.isPinned == true)
                try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.isPinned == false)
                try #require(WorkspaceGroupTree(groups: f.manager.workspaceGroups).outermost(of: f.q) == f.p)
            case .ownPin:
                f.manager.setWorkspaceGroupPinned(groupId: f.q,isPinned: true)
                try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.isPinned == true)
            case .emptyChild:
                f.manager.selectTab(f.w("l1"))
                f.manager.setWorkspaceGroupPinned(groupId: f.q,isPinned: true)
                f.manager.closeWorkspace(f.w("qa"),recordHistory: false)
                f.manager.closeWorkspace(f.w("qAnchor"),recordHistory: false)
                let q = try #require(f.manager.workspaceGroups.first { $0.id == f.q })
                try #require(q.isEmpty && q.liveAnchorWorkspaceId == nil && q.parentGroupId == f.p)
                try #require(!f.manager.tabs.contains { $0.groupId == f.q })
            }
            await f.applyRows(); try f.begin(row: .group(f.q))
            let held = f.held, order = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups
            let record = f.state.statusGroups, selected = f.manager.selectedTabId, selectedIds = f.selected
            let targets = f.targets(e.renderer), point = try childGuardPoint(f,e,targets)
            let plan = try f.route(point: point,targets: targets)
            if (invalid == .ownPin || invalid == .emptyChild) && !e.upper {
                // Core's pinned-source unrelated result retains the exact existing ordinary continuation.
                let ordinary = VerticalTabsSidebar.workspaceOrdinaryReorderPlan(point: point,targets: targets,snapshot: f.snapshot(),
                    draggedTabId: try #require(f.sourceId),foreignDraggedIsPinned: nil,permitsGroupEscape: false)
                #expect(plan == ordinary)
                if let plan { _ = f.commit(plan) }
                #expect(f.held == held && Dictionary(uniqueKeysWithValues: f.manager.workspaceGroups.map { ($0.id,$0) })
                    == Dictionary(uniqueKeysWithValues: groups.map { ($0.id,$0) }))
                #expect(f.state.statusGroups == record && f.manager.selectedTabId == selected && f.selected == selectedIds)
                #expect(f.writes.isEmpty && f.resolutions.isEmpty && f.ordinaryCalls == (plan == nil ? 0 : 1))
                if plan == nil { #expect(f.manager.tabs.map(\.id) == order) }
                return
            }
            if invalid == .emptyChild && e.upper {
                let accepted = try #require(plan)
                guard case .statusAreaBoundaryDrop(let boundary,_) = accepted.action else { Issue.record("Expected retained empty-child area continuation"); return }
                #expect(boundary.boundary == .aboveArea)
                let rowsBefore = f.rendered().map(\.id)
                let layout = SidebarStatusAreaLayout(items: f.rendered(),tabs: f.manager.tabs,groups: f.manager.workspaceGroups,statusProjection: f.projection())
                let canonical = layout.saving(state: record)
                let handled = f.commit(accepted)
                #expect(handled)
                #expect(f.state.statusGroups == canonical && f.rendered().map(\.id) == rowsBefore)
                #expect(f.held == held && f.manager.tabs.map(\.id) == order && f.manager.workspaceGroups == groups)
                #expect(f.manager.selectedTabId == selected && f.selected == selectedIds)
                #expect(f.writes.isEmpty && f.resolutions.isEmpty && f.ordinaryCalls == 1)
                return
            }
            if let plan { let handled = f.commit(plan); #expect(!handled) }
            #expect(f.held == held && f.manager.tabs.map(\.id) == order && f.manager.workspaceGroups == groups)
            #expect(f.state.statusGroups == record && f.manager.selectedTabId == selected && f.selected == selectedIds)
            #expect(f.writes.isEmpty && f.resolutions.isEmpty && f.ordinaryCalls == 0)
        }
    }

    private enum CachedChildGuard: CaseIterable, Sendable { case supersededSession, removedSource, missingArea }
    @Test(arguments: CachedChildGuard.allCases, Self.guardBoundaries)
    private func cachedChildBoundaryPlansRecheckSessionSourceAndCurrentArea(_ invalid: CachedChildGuard,_ e: BoundaryExample) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .r3); defer { f.close() }
            await f.applyRows(); try f.begin(row: .group(f.q))
            let targets = f.targets(e.renderer), point = try childGuardPoint(f,e,targets)
            let accepted = try f.route(point: point,targets: targets)
            let plan = try #require(accepted,"Positive current child-root plan control precedes each invalidation")
            guard case .statusAreaBoundaryDrop(_,let capturedToken) = plan.action else { Issue.record("Expected the real admitted boundary action"); return }
            switch invalid {
            case .supersededSession:
                let workspaceId = try #require(f.sourceId)
                try #require(f.token == capturedToken)
                f.drag.finishDrag()
                let completed = f.scope.source(windowId: f.windowId,workspaceId: workspaceId,sessionId: capturedToken,dragState: f.drag)
                try #require(completed?.kind == .workspaceGroupHeader(groupId: f.q) && f.drag.draggedTabId == nil)
                try f.begin(row: .group(f.q))
                let newerToken = try #require(f.token)
                try #require(newerToken != capturedToken)
                try #require(f.scope.source(windowId: f.windowId,workspaceId: workspaceId,sessionId: capturedToken,dragState: f.drag) == nil)
            case .removedSource:
                _ = f.manager.deleteWorkspaceGroup(groupId: f.q,recordHistory: false)
                try #require(!f.manager.workspaceGroups.contains { $0.id == f.q })
            case .missingArea:
                f.controls = false
                try #require(!f.rendered().contains { $0.id == .statusesArea() })
            }
            let held = f.held, order = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups
            let record = f.state.statusGroups, selected = f.manager.selectedTabId, selectedIds = f.selected
            #expect(!f.commit(plan))
            #expect(f.held == held && f.manager.tabs.map(\.id) == order && f.manager.workspaceGroups == groups)
            #expect(f.state.statusGroups == record && f.manager.selectedTabId == selected && f.selected == selectedIds)
            #expect(f.writes.isEmpty && f.resolutions.isEmpty && f.ordinaryCalls == 0)
        }
    }

    private enum CollapsedChildSelection: String, CaseIterable, Sendable { case outside, anchor, member }
    @Test(arguments: CollapsedChildSelection.allCases, Self.guardBoundaries)
    private func collapsedChildBoundaryMovesKeepTheOriginalSelectionAndAllFoldFlags(_ selection: CollapsedChildSelection,_ e: BoundaryExample) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .r3); defer { f.close() }
            let selectedWorkspace: Workspace
            switch selection {
            case .outside: selectedWorkspace = f.w("l1")
            case .anchor: selectedWorkspace = f.w("qAnchor")
            case .member: selectedWorkspace = f.w("qa")
            }
            if selection == .member {
                let group = try #require(f.manager.workspaceGroups.first { $0.id == f.q })
                try #require(selectedWorkspace.id == f.w("qa").id && selectedWorkspace.groupId == group.id)
                try #require(group.liveAnchorWorkspaceId == f.w("qAnchor").id && group.liveAnchorWorkspaceId != selectedWorkspace.id)
            }
            f.manager.selectTab(selectedWorkspace)
            f.manager.setWorkspaceGroupCollapsed(groupId: f.q,isCollapsed: true)
            try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.isCollapsed == true)
            try #require(f.manager.selectedTabId == selectedWorkspace.id)
            f.selected = [f.w("qAnchor").id]
            await f.applyRows()
            try #require(!f.rendered().contains { $0.id == .workspace(f.w("qa").id) })
            if selection == .member { try #require(f.manager.selectedTabId == f.w("qa").id) }
            try f.begin(row: .group(f.q))
            let held = f.held, groups = f.manager.workspaceGroups, record = try #require(f.state.statusGroups)
            let selected = f.manager.selectedTabId, selectedIds = f.selected
            let targets = f.targets(e.renderer), point = try childGuardPoint(f,e,targets)
            let accepted = try f.route(point: point,targets: targets), plan = try #require(accepted)
            #expect(f.commit(plan))
            #expect(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == nil)
            let folds = Dictionary(uniqueKeysWithValues: groups.map { ($0.id,$0.isCollapsed) })
            #expect(Dictionary(uniqueKeysWithValues: f.manager.workspaceGroups.map { ($0.id,$0.isCollapsed) }) == folds)
            #expect(f.manager.workspaceGroups.first { $0.id == f.p } == groups.first { $0.id == f.p })
            #expect(f.held == held && f.manager.selectedTabId == selected && f.selected == selectedIds)
            #expect(f.writes.isEmpty && f.resolutions.isEmpty)
            let rows = f.rendered().map(\.id), area = try #require(rows.firstIndex(of: .statusesArea()))
            let q = try #require(rows.firstIndex(of: .group(f.q))), p = try #require(rows.firstIndex(of: .group(f.p)))
            #expect(p < area && !rows.contains(.workspace(f.w("qa").id)))
            if e.upper {
                #expect(q < area && f.state.statusGroups?.aboveRow == "group:\(f.q.uuidString)" && f.state.statusGroups?.last == true)
            } else {
                #expect(q == rows.count-1 && q > area && f.state.statusGroups?.aboveRow == "group:\(f.p.uuidString)"
                    && f.state.statusGroups?.belowRow == "group:\(f.q.uuidString)" && f.state.statusGroups?.last == false)
            }
            #expect(f.state.statusGroups?.order == record.order && f.state.statusGroups?.collapsedStatusIds == record.collapsedStatusIds)
        }
    }

    nonisolated private static var guardBoundaries: [BoundaryExample] { childBoundaries.filter { !$0.parentAfter } }
    private func childGuardPoint(_ f: F,_ e: BoundaryExample,_ targets: [SidebarWorkspaceReorderDropOverlay.Target]) throws -> CGPoint {
        if !e.upper { return try f.point(.belowAll,fraction: 0,side: e.side,targets: targets) }
        let frame = try #require(targets.first { $0.workspaceId == SidebarStatusHeaderIdentity.statusesAreaUUID }?.frame)
        return .init(x: e.side.x,y: frame.minY+frame.height*0.25)
    }
    @Test(arguments: [false,true], [SidebarStatusGroupDropRules.AreaBoundary.aboveArea,.belowAll])
    private func aChildRootCallbackThatDidNotDetachCannotClaimSuccessOrRebindItsUnmovedParent(_ ordinaryResult: Bool,_ boundary: SidebarStatusGroupDropRules.AreaBoundary) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .r3); defer { f.close() }
            try f.begin(row: .group(f.q))
            let id = try #require(f.sourceId), token = try #require(f.token)
            let source = try #require(f.scope.source(windowId: f.windowId,workspaceId: id,sessionId: token,dragState: f.drag))
            try #require(source.kind == .workspaceGroupHeader(groupId: f.q))
            try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == f.p)
            let layout = SidebarStatusAreaLayout(items: f.rendered(),tabs: f.manager.tabs,groups: f.manager.workspaceGroups,statusProjection: f.projection())
            f.state.setStatusGroups(layout.saving(state: f.state.statusGroups))
            let record = f.state.statusGroups, held = f.held, groups = f.manager.workspaceGroups, order = f.manager.tabs.map(\.id)
            let selected = f.manager.selectedTabId, selectedIds = f.selected
            var callbacks = 0
            let plan = SidebarStatusAreaBoundaryDropPlan(boundary: boundary,
                move: .workspaces(targetIndex: f.manager.tabs.count,usesTopLevelRows: true,explicitGroupId: nil))
            let actor = StatusAreaDropPerformer(state: f.state,movingGroupIds: [f.q],currentTabs: { f.manager.tabs },
                currentGroups: { f.manager.workspaceGroups },currentProjection: { f.projection() },currentRenderItems: { f.rendered() },
                performOrdinary: { _ in callbacks += 1; return ordinaryResult })
            #expect(!actor.perform(plan,workspaceId: id,sourceKind: source.kind))
            #expect(callbacks == 1 && f.state.statusGroups == record && f.held == held && f.manager.workspaceGroups == groups)
            #expect(f.manager.tabs.map(\.id) == order && f.manager.selectedTabId == selected && f.selected == selectedIds)
            #expect(f.writes.isEmpty && f.resolutions.isEmpty)
        }
    }

    @Test(arguments: [false,true])
    func aRefusedChildRootOrdinaryStepRestoresTheActualModelAfterTheRealDetach(_ ordinaryResult: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .r3); defer { f.ordinaryOverride = nil; f.close() }
            let tail = Workspace(); tail.hideTaskStatus()
            f.manager.tabs.append(tail)
            f.manager.addWorkspaceToGroup(workspaceId: tail.id,groupId: f.p,placement: .end)
            try #require(tail.groupId == f.p && !tail.isPinned)
            let tailSlot = try #require(f.manager.tabs.firstIndex { $0.id == tail.id })
            let childLast = try #require(f.manager.tabs.firstIndex { $0.id == f.w("qa").id })
            if childLast > tailSlot {
                // End means after the last direct workspace; use the existing same-parent header reorder to put Q before the new sibling.
                let placed = f.manager.reorderSidebarWorkspace(tabId: f.w("qAnchor").id,toIndex: tailSlot,
                    isDragOperation: true,usesTopLevelRows: false,explicitGroupId: f.p)
                try #require(placed)
            }
            let originalChildLast = try #require(f.manager.tabs.firstIndex { $0.id == f.w("qa").id })
            let originalTail = try #require(f.manager.tabs.firstIndex { $0.id == tail.id })
            try #require(originalChildLast < originalTail && f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == f.p)
            await f.applyRows(); try f.begin(row: .group(f.q))
            let sourceId = try #require(f.sourceId), token = try #require(f.token)
            let source = try #require(f.scope.source(windowId: f.windowId,workspaceId: sourceId,sessionId: token,dragState: f.drag))
            try #require(source.kind == .workspaceGroupHeader(groupId: f.q))
            try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == f.p)
            let rootsBefore = f.manager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil,usesTopLevelRows: true)
            try #require(rootsBefore.last == f.w("c1").id && !rootsBefore.contains(sourceId))
            let held = f.held, order = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups
            let record = f.state.statusGroups, selected = f.manager.selectedTabId, selectedIds = f.selected
            var calls = 0
            f.ordinaryOverride = { plan in
                calls += 1
                let roots = f.manager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil,usesTopLevelRows: true)
                #expect(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == nil,"The production helper must have actually detached Q before this refusal")
                #expect(f.manager.tabs.map(\.id) != order,"Actual production detach must move Q past the still-unmoved trailing P member")
                #expect(roots.last == f.w("c1").id && roots.contains(sourceId))
                if case .reorder(let index,let top,let parent) = plan.action {
                    #expect(top && parent == nil && index == roots.count-1)
                    #expect(roots.firstIndex(of: sourceId) != index,"The real requested end slot after hidden c1 must change Q's current root slot")
                } else { Issue.record("Expected the shared helper's actual ordinary root-reorder step") }
                return ordinaryResult // Neither callback outcome performs a model reorder or test-side rollback.
            }
            let boundary = SidebarStatusAreaBoundaryDropPlan(boundary: .belowAll,
                move: .workspaces(targetIndex: rootsBefore.count,usesTopLevelRows: true,explicitGroupId: nil))
            let plan = SidebarWorkspaceReorderDropPlan(draggedWorkspaceId: sourceId,indicator: .init(tabId: nil,edge: .bottom),
                indicatorScope: .raw,action: .statusAreaBoundaryDrop(plan: boundary,sessionId: token))
            let handled = f.commit(plan)
            #expect(!handled && calls == 1)
            #expect(f.manager.workspaceGroups == groups && f.manager.tabs.map(\.id) == order)
            #expect(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId == f.p)
            #expect(f.held == held && f.manager.selectedTabId == selected && f.selected == selectedIds)
            #expect(f.state.statusGroups == record && f.writes.isEmpty && f.resolutions.isEmpty && f.ordinaryCalls == 0)
        }
    }
    @Test(arguments: F.Side.allCases, [0.25,0.5,0.75])
    private func nativeDebugStatusPointsUseMeasuredContentAndKeepRawDefaults(_ side: F.Side,_ fraction: Double) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .gap); defer { f.close() }
            await f.applyRows(); try f.begin(row: .workspace(f.source.id))
            let native = f.targets(.native), content = f.physicalMeasurements()
            let previous = try #require(native.first { $0.workspaceId == f.w("c3").id })
            let nextId = SidebarStatusHeaderIdentity.uuid(forStatusId: "next")
            let next = try #require(native.first { $0.workspaceId == nextId })
            try #require(previous.statusContentFrame == content[previous.workspaceId]?.content && previous.statusContentFrame != nil)
            try #require(next.statusContentFrame == content[nextId]?.content && next.statusContentFrame != nil)
            try #require(next.frame.minY == previous.frame.maxY,"Actual raw native targets abut; the physical two-point gap is in measured content")
            let typed = VerticalTabsSidebar.workspaceStatusDropTargets(items: f.rendered(),measured: native)
            let frames = Dictionary(uniqueKeysWithValues: typed.map { ($0.workspaceId,$0.frame) })
            let physicalPoint = try f.point(.statusGap,fraction: fraction,side: side,targets: native)
            let zone: SidebarDebugHeaderDrop.Zone = fraction < 0.5 ? .gap25 : (fraction == 0.5 ? .gap50 : .gap75)
            let debugSide: SidebarDebugHeaderDrop.Side = side == .left ? .left : .right
            let explicit = SidebarDebugHeaderDrop.point(targetId: previous.workspaceId,zone: zone,side: debugSide,
                targets: native,pointFrames: frames)
            try #require(explicit == physicalPoint)
            #expect(SidebarDebugHeaderDrop.point(targetId: previous.workspaceId,zone: zone,side: debugSide,targets: native) == nil)
            let area = try #require(native.first { $0.workspaceId == SidebarStatusHeaderIdentity.statusesAreaUUID })
            let rawHeader = SidebarDebugHeaderDrop.point(targetId: area.workspaceId,zone: .upper,side: debugSide,targets: native)
            #expect(rawHeader == CGPoint(x: area.frame.minX+area.frame.width*(side == .left ? 0.25 : 0.75),y: area.frame.minY+area.frame.height*0.25))
            let held = f.held, groups = f.manager.workspaceGroups
            var seenPoint: CGPoint?, calls = 0
            let performed = SidebarDebugHeaderDrop.perform(draggedId: f.source.id,targetId: previous.workspaceId,
                zone: zone,side: debugSide,targets: native,pointFrames: frames,
                plan: { point,measured,id in
                    calls += 1; seenPoint = point
                    #expect(id == f.source.id && measured == native,"The actual plan must receive unchanged raw targets and their metadata")
                    do { return try f.route(point: point,targets: measured) }
                    catch { Issue.record("Actual source/session route threw: \(error)"); return nil }
                },commit: { f.commit($0) })
            #expect(performed)
            #expect(calls == 1 && seenPoint == physicalPoint)
            let target = fraction < 0.5 ? "parked" : "next"
            #expect(f.source.todoState.ownStatus?.id == target && f.source.customColor == f.hexes[target])
            #expect(f.writes == [.init(id: f.source.id,color: f.hexes[target]!)])
            #expect(f.resolutions == [target == "parked" ? "5: PARKED" : "1: NEXT"])
            #expect(f.projection()?.group(for: target)?.memberWorkspaceIds.contains(f.source.id) == true)
            #expect(f.held.filter { $0.key != f.source.id } == held.filter { $0.key != f.source.id } && f.manager.workspaceGroups == groups)
        }
    }
}
