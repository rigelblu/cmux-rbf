import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// (#cm-110.10) A tab dropped on a status group lands where a workspace dropped there from elsewhere would.
@MainActor
@Suite("A tab dropped on a status group", .serialized)
struct SidebarTabStatusLandingTests {
    private typealias F = SidebarNestedStatusDropFixture

    private func landing(_ f: F, at point: CGPoint, headersOnly: Bool = false,
                         targets: [SidebarWorkspaceReorderDropOverlay.Target]) -> SidebarTabStatusLanding? {
        VerticalTabsSidebar.tabStatusLanding(point: point, targets: targets, snapshot: f.snapshot(), headersOnly: headersOnly,
            controlsEnabled: f.controls, hasUserStatusList: true)
    }

    /// The real new workspace, last in the tab order with no status, as the drop makes it before committing a landing.
    private func newWorkspace(_ f: F) -> Workspace {
        let workspace = f.manager.addWorkspace(select: false, placementOverride: .end, autoWelcomeIfNeeded: false)
        workspace.hideTaskStatus()
        return workspace
    }

    private func commit(_ f: F, _ landing: SidebarTabStatusLanding, _ workspace: Workspace) -> Bool {
        VerticalTabsSidebar.commitTabStatusLanding(landing, newWorkspace: workspace, tabManager: f.manager,
            sidebarState: f.state, actions: f.statusActions(), currentProjection: { f.projection() })
    }

    private func parkedOrder(_ f: F, with new: Workspace) -> [UUID] {
        let ids: Set = [f.w("c1").id, f.w("c2").id, f.w("c3").id, new.id]
        return f.manager.tabs.map(\.id).filter(ids.contains)
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases) func theMiddleOfAStatusHeaderIsAHeaderLandingEvenWhenAnExistingWorkspaceWouldBeAsked(_ renderer: SidebarNestedStatusDropFixture.Renderer) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let targets = f.targets(renderer)
            let point = try f.point(.header, fraction: 0.5, side: .left, targets: targets)
            for headersOnly in [false, true] {
                let result = try #require(landing(f, at: point, headersOnly: headersOnly, targets: targets))
                guard case .statusGroupDrop(let plan, _) = result.plan.action else { Issue.record("Expected a status landing"); return }
                #expect(plan.statusId == "parked" && plan.placement == .first && plan.setsStatus)
            }
            let workspace = newWorkspace(f)
            let result = try #require(landing(f, at: point, targets: targets))
            #expect(commit(f, result, workspace))
            #expect(workspace.todoState.ownStatus?.id == "parked" && workspace.customColor == "#555555")
            #expect(f.writes == [F.Write(id: workspace.id, color: "#555555")])
            #expect(f.manager.tabs.map(\.id).filter { $0 == workspace.id || $0 == f.w("c1").id }.first == workspace.id)
        }
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases) func betweenTwoRowsOfAStatusGroupLandsThereWithItsStatus(_ renderer: SidebarNestedStatusDropFixture.Renderer) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let targets = f.targets(renderer)
            let point = try f.point(.memberGap, fraction: 0.5, side: .left, targets: targets)
            let workspace = newWorkspace(f)
            let result = try #require(landing(f, at: point, targets: targets))
            guard case .statusGroupDrop(let plan, _) = result.plan.action else { Issue.record("Expected a status landing"); return }
            #expect(plan.statusId == "parked")
            #expect(commit(f, result, workspace))
            #expect(workspace.todoState.ownStatus?.id == "parked" && workspace.customColor == "#555555")
            #expect(parkedOrder(f, with: workspace) == [f.w("c1").id, f.w("c2").id, workspace.id, f.w("c3").id])
        }
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases) func onTheLastRowsBottomEdgeLandsLastInThatStatus(_ renderer: SidebarNestedStatusDropFixture.Renderer) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let targets = f.targets(renderer)
            let point = try f.point(.lastEdge, fraction: 1, side: .right, targets: targets)
            let workspace = newWorkspace(f)
            let result = try #require(landing(f, at: point, targets: targets))
            #expect(commit(f, result, workspace))
            #expect(workspace.todoState.ownStatus?.id == "parked")
            #expect(parkedOrder(f, with: workspace) == [f.w("c1").id, f.w("c2").id, f.w("c3").id, workspace.id])
        }
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases) func theMiddleOfAWorkspaceRowIsNotAHeaderLanding(_ renderer: SidebarNestedStatusDropFixture.Renderer) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let targets = f.targets(renderer)
            let point = try f.point(.lowerC2, fraction: 0.5, side: .left, targets: targets)
            #expect(landing(f, at: point, headersOnly: true, targets: targets) == nil)
        }
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases) func outsideTheStatusesAreaKeepsToday(_ renderer: SidebarNestedStatusDropFixture.Renderer) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let targets = f.targets(renderer)
            let frame = try #require(f.physicalMeasurements()[f.w("l1").id]?.content)
            #expect(landing(f, at: CGPoint(x: 60, y: frame.minY + 1), targets: targets) == nil)
            #expect(landing(f, at: CGPoint(x: 60, y: frame.maxY + 0.5), targets: targets) == nil)
        }
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases) func belowEveryRowWhenTheAreaIsLastIsNotAStatusLanding(_ renderer: SidebarNestedStatusDropFixture.Renderer) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f2b); defer { f.close() }; await f.applyRows()
            let targets = f.targets(renderer)
            let point = try f.point(.belowAll, fraction: 0.5, side: .left, targets: targets)
            #expect(landing(f, at: point, targets: targets) == nil)
        }
    }

    @Test func withTheControlsOffNoStatusGroupLanding() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let targets = f.targets(.native)
            let point = try f.point(.header, fraction: 0.5, side: .left, targets: targets)
            f.controls = false
            #expect(VerticalTabsSidebar.tabStatusLanding(point: point, targets: targets, snapshot: f.snapshot(), headersOnly: false,
                controlsEnabled: false, hasUserStatusList: true) == nil)
        }
    }

    /// How many drop lines are showing across the table's cells.
    private func visibleDropLines(_ f: F) -> Int {
        func count(_ view: NSView) -> Int {
            (view is SidebarReorderIndicatorView && !view.isHidden ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) }
        }
        let table = f.container.tableView
        return (0..<table.numberOfRows).reduce(0) { total, row in
            total + (table.view(atColumn: 0, row: row, makeIfNecessary: false).map(count) ?? 0)
        }
    }

    @Test func aLandingIsPaintedThroughTheReorderPainterAndClearedWhenTheDropLeaves() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let c2 = f.w("c2").id
            let update = SidebarWorkspaceTableReorderDropUpdate(indicator: SidebarDropIndicator(tabId: c2, edge: .top),
                scope: .raw, draggedWorkspaceId: UUID(), indicatorRowIds: f.manager.tabs.map(\.id), plan: nil, level: 2)
            #expect(visibleDropLines(f) == 0)
            f.container.bonsplitDropView.paintLandingUpdate(update)
            #expect(visibleDropLines(f) == 1, "The landing is painted by the cell that carries the line, as for a workspace drag")
            f.container.bonsplitDropView.setDropIndicator(nil)
            #expect(visibleDropLines(f) == 0, "Leaving the sidebar takes the painted line away")
        }
    }

    /// The Statuses area sits first (#cm-110.5), so the Workspaces header is the row under the last status row. Since `#cm-110.4` the area can only be
    /// first or last, and last leaves no row under it, so the fixture's default layout no longer has this gap.
    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases, [CGFloat(0.25), 0.5, 0.75])
    func theGapUnderTheLastStatusRowGoesWithTheRowAbove(_ renderer: SidebarNestedStatusDropFixture.Renderer, _ fraction: CGFloat) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1, sectionOrder: .statusesFirst); defer { f.close() }; await f.applyRows() // (#cm-110.5)
            let targets = f.targets(renderer)
            let point = try f.point(.gapBeforeP, fraction: fraction, side: .left, targets: targets)
            let workspace = newWorkspace(f)
            let result = try #require(landing(f, at: point, targets: targets))
            guard case .statusGroupDrop(let plan, _) = result.plan.action else { Issue.record("Expected a status landing"); return }
            #expect(plan.statusId == "parked" && plan.placement == .member(f.w("c3").id, insertBefore: false))
            #expect(commit(f, result, workspace))
            #expect(workspace.todoState.ownStatus?.id == "parked")
            #expect(parkedOrder(f, with: workspace) == [f.w("c1").id, f.w("c2").id, f.w("c3").id, workspace.id])
        }
    }

    /// The drop view itself, on the fixture's real container and controller: the row's middle means "into that workspace",
    /// an edge band or a header means a landing.
    @Test func theDropViewTellsTheEdgeBandFromTheRowMiddle() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let view = f.container.bonsplitDropView
            var into: [UUID] = [], landings = 0, plainNew = 0
            view.canPerformAction = { _, _ in true }
            view.performExistingWorkspaceMove = { id, _ in into.append(id); return true }
            view.performNewWorkspaceLandingMove = { _, _ in landings += 1; return true }
            view.performNewWorkspaceMove = { _, _, _ in plainNew += 1; return true }
            view.setWorkspaceDropTargetCollectionActive(true)
            defer { view.setWorkspaceDropTargetCollectionActive(false) }
            let transfer = BonsplitTabDragPayload.Transfer(debugTabId: UUID(), sourcePaneId: UUID())
            let targets = f.targets(.native)
            @MainActor func drop(_ zone: F.Zone, _ fraction: CGFloat) throws -> (accepted: Bool, performed: Bool) {
                let point = try f.point(zone, fraction: fraction, side: .left, targets: targets)
                let result = view.debugDrop(point: view.convert(point, from: f.container.reorderDropView), transfer: transfer)
                return (result.accepted, result.performed)
            }
            let middle = try drop(.lowerC2, 0.5)
            #expect(middle.performed && into == [f.w("c2").id] && landings == 0 && plainNew == 0, "The row middle moves the tab into that workspace")
            let edge = try drop(.memberGap, 0.5)
            #expect(edge.performed && landings == 1 && into.count == 1 && plainNew == 0, "An edge band lands on the status")
            let top = try drop(.firstTop, 0)
            #expect(top.performed && landings == 2 && into.count == 1 && plainNew == 0, "The top edge of the first row lands on the status")
            let header = try drop(.header, 0.5)
            #expect(header.performed && landings == 3 && into.count == 1 && plainNew == 0, "A header has no into zone")
        }
    }

    /// The SwiftUI sidebar's overlay builds the same drop view; its four landing closures must reach that view.
    @Test func theSwiftUIOverlayHandsItsLandingClosuresToItsDropView() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            var asked: [Bool] = [], moved = 0, painted = 0
            let landing = SidebarTabStatusLanding(
                plan: SidebarWorkspaceReorderDropPlan(draggedWorkspaceId: UUID(), indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
                    indicatorScope: .raw, action: .reorder(targetIndex: 0, usesTopLevelRows: true, explicitGroupId: nil)),
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom))
            let bridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()
            let overlay = SidebarBonsplitTabWorkspaceDropOverlay(
                currentSelectedTabId: { nil }, sidebarIndexForTabId: { _ in nil },
                moveToExistingWorkspace: { _, _ in false }, moveToNewWorkspace: { _, _ in nil },
                selectedTabIds: .constant([]), lastSidebarSelectionIndex: .constant(nil), dropIndicator: .constant(nil),
                updateAutoscroll: {}, setWorkspaceDropTargetCollectionActive: { _ in },
                isWorkspaceDropTargetCollectionActive: false, targetBridge: bridge,
                resolveStatusLanding: { _, headersOnly in asked.append(headersOnly); return landing },
                moveToNewWorkspaceAtLanding: { _, _ in moved += 1; return UUID() },
                landingPaintUpdate: { _ in painted += 1; return nil },
                paintLandingUpdate: { _ in })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: overlay.frame(width: 200, height: 200))
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { c in RunLoop.main.perform(inModes: [.common]) { c.resume() } }
            host.layoutSubtreeIfNeeded()
            func find(_ view: NSView) -> SidebarBonsplitTabWorkspaceDropView? {
                if let match = view as? SidebarBonsplitTabWorkspaceDropView { return match }
                for child in view.subviews { if let match = find(child) { return match } }
                return nil
            }
            let view = try #require(find(host), "SwiftUI must have made the overlay's real drop view")
            bridge.updateTargets([SidebarDropPlanner.WorkspaceDropTarget(workspaceId: UUID(), isPinned: false, frame: CGRect(x: 0, y: 0, width: 200, height: 30))])
            view.canPerformAction = { _, _ in true }
            let transfer = BonsplitTabDragPayload.Transfer(debugTabId: UUID(), sourcePaneId: UUID())
            // Below the only row: a new-workspace point, the full plan is asked.
            let below = view.debugDrop(point: CGPoint(x: 100, y: 100), transfer: transfer)
            #expect(below.performed && asked == [false] && moved == 1 && painted == 1)
            // The middle of the row: "into" the row, so only a header-only landing is asked for (here the stub answers).
            let middle = view.debugDrop(point: CGPoint(x: 100, y: 15), transfer: transfer)
            #expect(middle.performed && asked == [false, true] && moved == 2 && painted == 2)
        }
    }

    @Test func aTabFromAnyWorkspaceIsPlannedAsANewLooseOne() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try F(scene: .f1); defer { f.close() }; await f.applyRows()
            let targets = f.targets(.native)
            let point = try f.point(.memberGap, fraction: 0.5, side: .left, targets: targets)
            let result = try #require(landing(f, at: point, targets: targets))
            // The stand-in is nobody's workspace: it is in no group, no status and no color section, so nothing refuses it.
            #expect(f.manager.tabs.contains { $0.id == result.standInId } == false)
            guard case .statusGroupDrop(let plan, _) = result.plan.action else { Issue.record("Expected a status landing"); return }
            #expect(plan.setsStatus)
        }
    }
}

@MainActor
@Suite("A tab dropped around a workspace group under a status", .serialized)
struct SidebarTabStatusLandingGroupTests {
    private typealias F = SidebarNestedStatusDropFixture

    private func fixture() throws -> F {
        let f = try F(scene: .f2b)
        f.projectsWorkspaceGroups = true
        var groups = f.manager.workspaceGroups
        let index = try #require(groups.firstIndex { $0.id == f.p })
        groups[index].statusId = "parked"; groups[index].customColor = "#555555"
        f.manager.workspaceGroups = groups
        return f
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases) func betweenTheMemberRowsOfAGroupUnderAStatusTheNewWorkspaceJoinsTheGroupWithNoStatus(_ renderer: SidebarNestedStatusDropFixture.Renderer) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try fixture(); defer { f.close() }; await f.applyRows()
            let targets = f.targets(renderer)
            let frame = try #require(f.physicalMeasurements()[f.w("pa").id]?.content)
            let point = CGPoint(x: 180, y: frame.midY + 1)
            let result = try #require(VerticalTabsSidebar.tabStatusLanding(point: point, targets: targets, snapshot: f.snapshot(),
                headersOnly: false, controlsEnabled: true, hasUserStatusList: true))
            guard case .reorder(_, false, let group) = result.plan.action else { Issue.record("Expected a group join, got \(result.plan.action)"); return }
            #expect(group == f.p)
            let workspace = f.manager.addWorkspace(select: false, placementOverride: .end, autoWelcomeIfNeeded: false)
            workspace.hideTaskStatus()
            #expect(VerticalTabsSidebar.commitTabStatusLanding(result, newWorkspace: workspace, tabManager: f.manager,
                sidebarState: f.state, actions: f.statusActions()))
            #expect(workspace.groupId == f.p)
            #expect(workspace.todoState.ownStatus == nil && f.writes.isEmpty)
        }
    }
}
