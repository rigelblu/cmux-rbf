import AppKit
import CmuxControlSocket
import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// `cm-110.14`, scrolling (Decisions, the 2026-10-29 entry on scrolling): after a status, color or cycle move the selected
// workspace is scrolled into view; a row he is not working in never moves the view; a drop never moves the view.
// Two halves. The table half drives a real `SidebarWorkspaceTableController` with rows in a window. The model half reads the
// counter a move bumps on `SidebarState` when the moved workspace is the selected one.
@MainActor
@Suite("Scrolling after a move (cm-110.14)", .serialized)
struct WorkspaceMoveRevealScrollTests {
    typealias Nested = SidebarNestedRootStatusTests

    // MARK: The table half

    private struct TestRowContent: View, Equatable {
        let fixedHeight: CGFloat
        var body: some View { Color.clear.frame(height: fixedHeight) }
    }

    private func row(_ id: UUID) -> SidebarWorkspaceTableRowConfiguration {
#if DEBUG
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: SidebarLazyContractProbe())
#else
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(colorScheme: .light, globalFontMagnificationPercent: 100)
#endif
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(id), workspaceId: id, groupId: nil, isGroupHeader: false, isPinned: false,
            environment: environment, equivalenceValue: TestRowContent(fixedHeight: 30)
        ) { _, _ in AnyView(TestRowContent(fixedHeight: 30)) }
    }

    private func flush() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    private func actions(drop: @escaping () -> Bool = { false }) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {}, createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in }, movingWorkspaceCount: { _ in 1 }, endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true }, updateWorkspaceDrag: { _, _, _ in nil },
            performWorkspaceDrop: { _, _, _ in drop() }, commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil }, currentDropIndicatorScope: { .raw },
            canPerformBonsplitAction: { _, _ in false }, moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil }, didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {}, setBonsplitDropTargetCollectionActive: { _ in }, setBonsplitDropIndicator: { _ in },
            nativeWorkspaceDragLifecycle: nil)
    }

    /// 40 rows of 30 points in a 240-point window: rows 0 to 7 are in view. The selected one starts at row 2.
    @MainActor
    private final class Table {
        let controller = SidebarWorkspaceTableController()
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        let ids = (0..<40).map { _ in UUID() }
        var selected: UUID { ids[2] }
        init() {
            container = controller.makeContainerView()
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = container
        }
        var origin: CGFloat { container.clipView.bounds.origin.y }
        func rowIsInView(_ id: UUID, in order: [UUID]) -> Bool {
            guard let index = order.firstIndex(of: id) else { return false }
            let table = container.tableView
            return table.visibleRect.contains(table.rect(ofRow: index))
        }
    }

    /// The order with `id` moved to `index`.
    private func moved(_ id: UUID, to index: Int, in ids: [UUID]) -> [UUID] {
        var next = ids
        next.remove(at: next.firstIndex(of: id)!)
        next.insert(id, at: index)
        return next
    }

    private func settle(_ table: Table) async {
        await flush()
        table.container.layoutSubtreeIfNeeded()
        table.container.tableView.layoutSubtreeIfNeeded()
    }

    private func start(_ table: Table) async {
        table.controller.apply(rows: table.ids.map(row), actions: actions(), workspaceIds: table.ids,
                               selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected)
        await settle(table)
    }

    /// The tab order stays; the selected row's place in the rows moves, as a status or color regroups it.
    private func applyRegrouped(_ table: Table, token: Int) async -> [UUID] {
        let order = moved(table.selected, to: 35, in: table.ids)
        table.controller.apply(rows: order.map(row), actions: actions(), workspaceIds: table.ids,
                               selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected,
                               selectedRevealScrollToken: token)
        await settle(table)
        return order
    }

    @Test func aMoveTokenScrollsTheSelectedRowIntoViewWhenItsRowMovedOutOfView() async throws {
        let table = Table()
        await start(table)
        try #require(table.rowIsInView(table.selected, in: table.ids), "the selected row starts in view")
        let order = await applyRegrouped(table, token: 1)
        #expect(table.rowIsInView(table.selected, in: order), "the selected row is at row 35 and the view is at \(table.origin); expected it scrolled into view")
    }

    @Test func noTokenLeavesTheViewWhereItWasWhenARowRegroupsOutOfView() async throws {
        let table = Table()
        await start(table)
        let origin = table.origin
        _ = await applyRegrouped(table, token: 0)
        #expect(table.origin == origin, "a regroup with no move token moved the view from \(origin) to \(table.origin)")
    }

    @Test func aDropOfTheSelectedRowBelowTheViewDoesNotMoveTheView() async throws {
        let table = Table()
        await start(table)
        let origin = table.origin
        let pending = moved(table.selected, to: 35, in: table.ids)
        table.controller.apply(rows: table.ids.map(row), actions: actions(drop: { true }),
                               workspaceIds: table.ids, selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected)
        await settle(table)
        let perform = try #require(table.container.reorderDropView.performDropAtPoint)
        try #require(perform(CGPoint(x: 10, y: 10), []), "the drop was refused")
        table.controller.apply(rows: pending.map(row), actions: actions(), workspaceIds: pending,
                               selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected,
                               selectedRevealScrollToken: 1)
        await settle(table)
        #expect(table.origin == origin, "the drop moved the view from \(origin) to \(table.origin)")
    }

    @Test func aDropWhoseTokenArrivesInALaterApplyDoesNotMoveTheViewEither() async throws {
        let table = Table()
        await start(table)
        let origin = table.origin
        table.controller.apply(rows: table.ids.map(row), actions: actions(drop: { true }),
                               workspaceIds: table.ids, selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected)
        await settle(table)
        let perform = try #require(table.container.reorderDropView.performDropAtPoint)
        try #require(perform(CGPoint(x: 10, y: 10), []), "the drop was refused")
        // The tab change lands first and spends the one-shot; the fold the drop opened lands in a later apply and flips the
        // scroll target from the group's header (row 2) to the selected row itself (row 35).
        let order = moved(table.selected, to: 35, in: table.ids)
        table.controller.apply(rows: table.ids.map(row), actions: actions(), workspaceIds: moved(table.selected, to: 20, in: table.ids),
                               selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.ids[0])
        await settle(table)
        table.controller.apply(rows: order.map(row), actions: actions(), workspaceIds: moved(table.selected, to: 20, in: table.ids),
                               selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected,
                               selectedRevealScrollToken: 1)
        await settle(table)
        #expect(table.origin == origin, "the apply that followed the drop moved the view from \(origin) to \(table.origin)")
    }

    @Test func aSelectionChangeAfterADropStillScrollsToTheNewRow() async throws {
        let table = Table()
        await start(table)
        table.controller.apply(rows: table.ids.map(row), actions: actions(drop: { true }),
                               workspaceIds: table.ids, selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected)
        await settle(table)
        let perform = try #require(table.container.reorderDropView.performDropAtPoint)
        try #require(perform(CGPoint(x: 10, y: 10), []), "the drop was refused")
        let order = moved(table.selected, to: 20, in: table.ids)
        table.controller.apply(rows: order.map(row), actions: actions(), workspaceIds: order,
                               selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected)
        await settle(table)
        let far = table.ids[38]
        table.controller.apply(rows: order.map(row), actions: actions(), workspaceIds: order,
                               selectedWorkspaceId: far, selectedScrollTargetWorkspaceId: far)
        await settle(table)
        #expect(table.rowIsInView(far, in: order), "selecting a row after a drop did not scroll to it; the view is at \(table.origin)")
    }

    @Test func aTabDroppedOnAStatusGroupDoesNotMoveTheView() async throws {
        let table = Table()
        await start(table)
        let origin = table.origin
        let created = table.ids[36]
        var tableActions = actions()
        tableActions.moveBonsplitToNewWorkspaceAtLanding = { _, _ in created }
        table.controller.apply(rows: table.ids.map(row), actions: tableActions, workspaceIds: table.ids,
                               selectedWorkspaceId: table.selected, selectedScrollTargetWorkspaceId: table.selected)
        await settle(table)
        let indicator = SidebarDropIndicator(tabId: table.ids[0], edge: .bottom)
        let plan = SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: UUID(), indicator: indicator,
            action: .reorder(targetIndex: 0, usesTopLevelRows: false, explicitGroupId: nil))
        let landing = SidebarTabStatusLanding(plan: plan, indicator: indicator)
        let perform = try #require(table.container.bonsplitDropView.performNewWorkspaceLandingMove)
        try #require(perform(landing, BonsplitTabDragPayload.Transfer(debugTabId: UUID(), sourcePaneId: UUID())), "the landing was refused")
        // The new workspace is selected and sits far below the view, as a status group's last row can.
        table.controller.apply(rows: table.ids.map(row), actions: tableActions, workspaceIds: table.ids,
                               selectedWorkspaceId: created, selectedScrollTargetWorkspaceId: created)
        await settle(table)
        #expect(table.origin == origin, "a tab dropped on a status group moved the view from \(origin) to \(table.origin)")
    }

    // MARK: The model half

    private let routing = ControlRoutingSelectors(
        hasWindowIDParam: false, windowID: nil, groupID: nil, workspaceID: nil, surfaceID: nil, paneID: nil
    )

    private func inNested(list: String? = nil,
                          _ body: (WorkspaceMoveRevealTests.Rig, Nested.World) throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let handle = try Nested.installStatusListHandle(source: list)
            let world = try Nested.World()
            let rig = try WorkspaceMoveRevealTests.Rig(handle: handle, manager: world.manager)
            defer { rig.finish() }
            try body(rig, world)
        }
    }

    @Test func aStatusOnTheSelectedRowBumpsTheScrollToken() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("u"))
            let before = rig.state.selectedRevealScrollToken
            WorkspaceTodoActions.applyStatusOverride(.status(id: "doing"), to: [world.w("u")])
            #expect(rig.state.selectedRevealScrollToken == before + 1, "token \(rig.state.selectedRevealScrollToken), was \(before)")
        }
    }

    @Test func aColorOnTheSelectedRowBumpsTheScrollToken() async throws {
        try await inNested { rig, world in
            rig.manager.selectWorkspace(world.w("u"))
            let before = rig.state.selectedRevealScrollToken
            rig.manager.applyWorkspaceColor("#AA5500", toWorkspaceIds: [world.w("u").id])
            #expect(rig.state.selectedRevealScrollToken == before + 1, "token \(rig.state.selectedRevealScrollToken), was \(before)")
        }
    }

    @Test func aCyclePressOnTheSelectedRowBumpsTheScrollToken() async throws {
        try await inNested(list: WorkspaceMoveRevealTests.fiveStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("u"))
            try #require(world.w("u").setOwnStatus(try #require(AppDelegate.statusListInUse.entry(id: "e1")), list: AppDelegate.statusListInUse))
            let before = rig.state.selectedRevealScrollToken
            WorkspaceTodoActions.cycleStatus(for: world.w("u"))
            #expect(rig.state.selectedRevealScrollToken == before + 1, "token \(rig.state.selectedRevealScrollToken), was \(before)")
        }
    }

    @Test func aStatusOnTheSelectedGroupsOwnWorkspaceBumpsTheScrollToken() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("g"))
            let before = rig.state.selectedRevealScrollToken
            try world.setStatus(world.g, "doing")
            #expect(rig.state.selectedRevealScrollToken == before + 1, "token \(rig.state.selectedRevealScrollToken), was \(before)")
        }
    }

    @Test func aStatusOnARowThatIsNotSelectedBumpsNothing() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            let before = rig.state.selectedRevealScrollToken
            WorkspaceTodoActions.applyStatusOverride(.status(id: "doing"), to: [world.w("u")])
            _ = TerminalController.shared.controlSetWorkspaceTaskStatus(routing: routing, workspaceID: world.w("p1").id, statusRaw: "doing")
            #expect(rig.state.selectedRevealScrollToken == before, "a row he is not working in bumped the token to \(rig.state.selectedRevealScrollToken)")
        }
    }

    @Test func aStatusSetFromTheSocketWithNoWorkspaceTargetsTheSelectedOneAndBumpsTheToken() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("u"))
            let previous = TerminalController.shared.activeTabManagerForCallerNotification()
            TerminalController.shared.setActiveTabManager(rig.manager)
            defer { TerminalController.shared.setActiveTabManager(previous) }
            let before = rig.state.selectedRevealScrollToken
            let result = TerminalController.shared.controlSetWorkspaceTaskStatus(routing: routing, workspaceID: nil, statusRaw: "doing")
            guard case .resolved = result else { Issue.record("the set did not resolve: \(result)"); return }
            try #require(world.w("u").todoState.ownStatus?.id == "doing", "the selected workspace took the status")
            #expect(rig.state.selectedRevealScrollToken == before + 1, "token \(rig.state.selectedRevealScrollToken), was \(before)")
        }
    }
}
