import AppKit
import CmuxFoundation
import Foundation
import Testing
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite(.serialized)
struct SidebarDebugHeaderDropTests {
    @Test(arguments: [SidebarDebugHeaderDrop.Zone.upper, .lower, .topEdge, .bottomEdge, .belowAll], SidebarDebugHeaderDrop.Side.allCases)
    func coordinatesComeFromTheRealTableTargets(_ zone: SidebarDebugHeaderDrop.Zone, _ side: SidebarDebugHeaderDrop.Side) async throws {
        let (controller, container, window) = await mount()
        defer {
            controller.dismantleContainerView(container)
            window.contentView = nil
            window.close()
        }
        let targets = controller.refreshReorderDropTargets(includeHeaders: true)
        let target = try #require(targets.first)
        #expect(target.frame.width > 0 && target.frame.height > 0)
        let actual = try #require(SidebarDebugHeaderDrop.point(targetId: target.workspaceId, zone: zone, side: side, targets: targets))
        let frame = target.frame
        let x = frame.minX + frame.width * (side == .left ? 0.25 : 0.75)
        let y: CGFloat
        switch zone {
        case .upper: y = frame.minY + frame.height * 0.25
        case .lower: y = frame.minY + frame.height * 0.75
        case .topEdge: y = frame.minY
        case .bottomEdge: y = frame.maxY
        case .belowAll: y = try #require(targets.map { $0.frame.maxY }.max()) + 1
        case .gap25, .gap50, .gap75: Issue.record("Interior gaps have their own calibrated Piece4 cases"); return
        }
        #expect(actual == CGPoint(x: x, y: y))
        if zone == .belowAll { #expect(actual.y > targets.map { $0.frame.maxY }.max()!) }
    }
    @Test func anUnknownTargetHasNoCoordinate() {
        #expect(SidebarDebugHeaderDrop.point(targetId: UUID(), zone: .upper, side: .left, targets: []) == nil)
    }
    @Test func theMeasuredPointReachesThePlannerAndItsExactPlanIsCommitted() {
        let source = UUID(), target = UUID()
        let targets = [SidebarWorkspaceReorderDropOverlay.Target(workspaceId: target, groupId: nil, isGroupHeader: false,
            frame: CGRect(x: 10, y: 30, width: 200, height: 40))]
        let expected = SidebarWorkspaceReorderDropPlan(draggedWorkspaceId: source,
            indicator: .init(tabId: target, edge: .bottom), indicatorScope: .raw,
            action: .reorder(targetIndex: 7, usesTopLevelRows: true, explicitGroupId: nil))
        var calls = 0
        var committed: SidebarWorkspaceReorderDropPlan?
        let performed = SidebarDebugHeaderDrop.perform(draggedId: source, targetId: target, zone: .lower, side: .right,
            targets: targets, plan: { point, measured, id in
                calls += 1
                #expect(point == CGPoint(x: 160, y: 60))
                #expect(measured == targets && id == source)
                return expected
            }, commit: { committed = $0; return true })
        #expect(performed)
        #expect(calls == 1)
        #expect(committed == expected)
    }
    @Test func aRefusedPlanCannotReachCommit() {
        let target = UUID()
        let targets = [SidebarWorkspaceReorderDropOverlay.Target(workspaceId: target, groupId: nil, isGroupHeader: false,
            frame: CGRect(x: 10, y: 30, width: 200, height: 40))]
        var commits = 0
        #expect(!SidebarDebugHeaderDrop.perform(draggedId: UUID(), targetId: target, zone: .upper, side: .left,
            targets: targets, plan: { _, _, _ in nil }, commit: { _ in commits += 1; return true }))
        #expect(commits == 0)
    }
    @Test func aMissingTargetCannotReachPlannerOrCommit() {
        var plans = 0, commits = 0
        #expect(!SidebarDebugHeaderDrop.perform(draggedId: UUID(), targetId: UUID(), zone: .upper, side: .left,
            targets: [], plan: { _, _, _ in plans += 1; return nil }, commit: { _ in commits += 1; return true }))
        #expect(plans == 0 && commits == 0)
    }
    @Test func nativeRichMeasurementsIncludeTheColorHeaderInItsWholeBlock() async throws {
        let f = await colorFixture()
        defer { f.controller.dismantleContainerView(f.container); f.window.contentView = nil; f.window.close() }
        let measured = f.controller.refreshReorderDropTargets(includeHeaders: true)
        let headerFrame = f.container.tableView.convert(f.container.tableView.rect(ofRow: 0), to: f.container.reorderDropView)
        let memberFrame = f.container.tableView.convert(f.container.tableView.rect(ofRow: 1), to: f.container.reorderDropView)
        #expect(measured.contains { $0.renderItemId == f.items[0].id && $0.frame == headerFrame })
        let targets = SidebarStatusAreaLayout(items: f.items).headerDropTargets(measured: measured)
        let wholeMid = (headerFrame.minY + memberFrame.maxY) / 2
        let point = CGPoint(x: memberFrame.midX, y: (wholeMid + memberFrame.midY) / 2)
        let plan = try #require(SidebarStatusHeaderDropPlanner().plan(point: point, draggedStatusId: nil, targets: targets))
        #expect(plan.action == .area(aboveRow: "color:#AABBCC", belowRow: "workspace:\(f.loose.uuidString)", last: false))
        #expect(plan.indicator == .init(tabId: f.member, edge: .bottom))
        // The ordinary/default workspace route keeps its established exclusions.
        let ordinary = f.controller.refreshReorderDropTargets()
        #expect(!ordinary.contains { $0.renderItemId == f.items[0].id || $0.renderItemId == .statusesArea() })
    }
    @Test(arguments: [false, true])
    func debugSelectionDistinguishesAColorHeaderFromItsMember(_ header: Bool) async throws {
        let f = await colorFixture()
        defer { f.controller.dismantleContainerView(f.container); f.window.contentView = nil; f.window.close() }
        let row = header ? 0 : 1
        let expectedFrame = f.container.tableView.convert(f.container.tableView.rect(ofRow: row), to: f.container.reorderDropView)
        let point = try #require(SidebarDebugHeaderDrop.point(targetId: f.member, zone: .upper, side: .left,
            targets: f.controller.refreshReorderDropTargets(includeHeaders: true), renderItemId: f.items[row].id))
        #expect(point == CGPoint(x: expectedFrame.minX + expectedFrame.width * 0.25,
                                y: expectedFrame.minY + expectedFrame.height * 0.25))
    }
    @Test func anUnknownRenderIdentityCannotFallBackToASharedWorkspaceUUID() async {
        let f = await colorFixture()
        defer { f.controller.dismantleContainerView(f.container); f.window.contentView = nil; f.window.close() }
        #expect(SidebarDebugHeaderDrop.point(targetId: f.member, zone: .upper, side: .left,
            targets: f.controller.refreshReorderDropTargets(includeHeaders: true), renderItemId: .statusGroup("removed")) == nil)
    }

    private struct MeasuredRow: View, Equatable {
        var body: some View { Color.clear.frame(height: 30) }
    }
    private func colorFixture() async -> (controller: SidebarWorkspaceTableController, container: SidebarWorkspaceTableContainerView,
        window: NSWindow, items: [SidebarWorkspaceRenderItem], member: UUID, loose: UUID) {
        _ = NSApplication.shared
        let member = UUID(), loose = UUID()
        let section = SidebarWorkspaceColorSection(id: .init(normalizedHex: "#AABBCC", pinTier: .unpinned),
            title: "Color", memberWorkspaceIds: [member], isCollapsed: false)
        let items: [SidebarWorkspaceRenderItem] = [.colorSectionHeader(section: section), .workspace(workspaceId: member),
            .workspace(workspaceId: loose), .statusesHeader]
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(colorScheme: .light,
            globalFontMagnificationPercent: 100, lazyContractProbe: .init())
        var rows: [SidebarWorkspaceTableRowConfiguration] = []
        for (index, item) in items.enumerated() {
            if case .statusesHeader = item {
                let status = VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusesArea, presentation: nil,
                    memberCount: 0, memberIds: [], folds: .init(), environment: environment, onToggle: {})
                rows.append(status)
                continue
            }
            let workspaceId: UUID = index < 2 ? member : loose
            let toggle: (@MainActor () -> Void)?
            if index == 0 { toggle = {} } else { toggle = nil }
            let content = MeasuredRow()
            let configuration = SidebarWorkspaceTableRowConfiguration(id: item.id, workspaceId: workspaceId,
                groupId: nil, isGroupHeader: false, isPinned: false, colorSectionToggle: toggle,
                environment: environment, equivalenceValue: content,
                makeContent: { _, _ in AnyView(MeasuredRow()) })
            rows.append(configuration)
        }
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        controller.apply(rows: rows, actions: Self.tableActions(), workspaceIds: [member, loose],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil)
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        return (controller, container, window, items, member, loose)
    }

    private func mount() async -> (SidebarWorkspaceTableController, SidebarWorkspaceTableContainerView, NSWindow) {
        _ = NSApplication.shared
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        let configuration = VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusGroup("measured"),
            presentation: nil, memberCount: 0, memberIds: [], folds: .init(),
            environment: .init(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init()), onToggle: {})
        // Include native status targets only for header planning; workspace semantics remain guarded by the adapter.
        controller.apply(rows: [configuration], actions: Self.tableActions(), workspaceIds: [],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil)
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        return (controller, container, window)
    }
    private static func tableActions(begin: @escaping (UUID) -> Void = { _ in }, moving: @escaping (UUID) -> Int = { _ in 1 }) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {}, createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: begin, movingWorkspaceCount: moving, endWorkspaceDrag: {}, isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _, _ in nil }, performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false }, clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw }, canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false }, moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in }, updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in }, setBonsplitDropIndicator: { _ in }
        )
    }
}
#endif
