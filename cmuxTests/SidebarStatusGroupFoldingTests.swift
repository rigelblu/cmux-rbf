import AppKit
import CmuxNotifications
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarStatusGroupFoldingTests {
    private static let list = WorkspaceStatusList(entries: [
        WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo),
        WorkspaceStatusEntry(id: "done", name: "Done"),
    ], source: .file)
    private static let colors = ["parked": "#AABBCC", "done": "#AABBCC"]

    @Test func anOldSessionWithoutTheRecordIsNotSeeded() throws {
        let data = Data(#"{"isVisible":true,"selection":"tabs","width":280}"#.utf8)
        let snapshot = try JSONDecoder().decode(SessionSidebarSnapshot.self, from: data)
        let state = SidebarState(statusGroups: snapshot.statusGroups)
        #expect(snapshot.statusGroups == nil)
        #expect(state.statusGroups == nil)
    }

    @Test func theWindowFoldRecordRoundTripsWithoutPruningUnknownIds() throws {
        let folds = WorkspaceStatusGroupsState(areaCollapsed: true, collapsedStatusIds: ["parked", "not-listed"])
        let snapshot = SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 280, statusGroups: folds)
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(SessionSidebarSnapshot.self, from: data)
        #expect(restored.statusGroups == folds)
    }

    @Test func aNotSeededWindowEncodesNoRecord() throws {
        let state = SidebarState(statusGroups: nil)
        let snapshot = SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 280, statusGroups: state.statusGroups)
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["statusGroups"] == nil)
    }

    @Test func aRestoredWindowWaitsForAListBeforeSeeding() {
        let state = SidebarState(collapsedColorSectionHexes: ["#AABBCC"], statusGroups: nil)
        state.prepareStatusGroupsForSelection(list: .cmuxFive, resolvedHexByStatusId: [:], selectedWorkspace: nil, workspaceGroups: [])
        #expect(state.statusGroups == nil)
    }

    @Test func theFirstListCopiesFoldsBeforeOpeningTheSelectedColor() throws {
        let state = SidebarState(collapsedColorSectionHexes: ["#AABBCC"], statusGroups: nil)
        state.prepareStatusGroupsForSelection(list: .cmuxFive, resolvedHexByStatusId: [:], selectedWorkspace: nil, workspaceGroups: [])
        let selected = try Self.selectedWorkspace()
        state.prepareStatusGroupsForSelection(list: Self.list, resolvedHexByStatusId: Self.colors, selectedWorkspace: selected, workspaceGroups: [])
        let folds = try #require(state.statusGroups)
        // Both statuses shared the folded color before selection opened that color group.
        #expect(folds.collapsedStatusIds.contains("done"))
        #expect(state.collapsedColorSectionHexes.isEmpty)
    }

    @Test func theSelectedGroupIsOpenAfterTheFirstCopy() throws {
        let state = SidebarState(collapsedColorSectionHexes: ["#AABBCC"], statusGroups: nil)
        state.prepareStatusGroupsForSelection(
            list: Self.list, resolvedHexByStatusId: Self.colors, selectedWorkspace: try Self.selectedWorkspace()
        , workspaceGroups: [])
        let folds = try #require(state.statusGroups)
        #expect(!folds.collapsedStatusIds.contains("parked"))
        #expect(!folds.areaCollapsed)
    }

    @Test func aNewWindowDoesNotCopyItsColorFolds() throws {
        let state = SidebarState(collapsedColorSectionHexes: ["#AABBCC"])
        state.prepareStatusGroupsForSelection(list: Self.list, resolvedHexByStatusId: Self.colors, selectedWorkspace: nil, workspaceGroups: [])
        #expect(try #require(state.statusGroups).collapsedStatusIds.isEmpty)
    }

    @Test func aSeededWindowNeverCopiesAgainAndKeepsAbsentIds() {
        let original = WorkspaceStatusGroupsState(areaCollapsed: true, collapsedStatusIds: ["parked", "not-listed"])
        let state = SidebarState(statusGroups: original)
        state.prepareStatusGroupsForSelection(list: .cmuxFive, resolvedHexByStatusId: [:], selectedWorkspace: nil, workspaceGroups: [])
        state.prepareStatusGroupsForSelection(list: Self.list, resolvedHexByStatusId: Self.colors, selectedWorkspace: nil, workspaceGroups: [])
        #expect(state.statusGroups == original)
    }

    @Test func selectingASeededMemberUnfoldsItsGroupAndArea() throws {
        let state = SidebarState(statusGroups: .init(areaCollapsed: true, collapsedStatusIds: ["parked", "done"]))
        state.revealStatusGroup(
            containing: try Self.selectedWorkspace(), list: Self.list, resolvedHexByStatusId: Self.colors
        , workspaceGroups: [])
        let folds = try #require(state.statusGroups)
        #expect(!folds.areaCollapsed)
        #expect(!folds.collapsedStatusIds.contains("parked"))
        #expect(folds.collapsedStatusIds.contains("done"))
    }

    @Test(arguments: [1, 3])
    func aSelectedWorkspaceAtRestoreDoesNotEraseTheLaterCopySource(_ automaticReveals: Int) throws {
        let state = SidebarState(collapsedColorSectionHexes: ["#AABBCC"], statusGroups: nil)
        let selected = try Self.selectedWorkspace()
        for _ in 0..<automaticReveals {
            state.prepareStatusGroupsForSelection(list: .cmuxFive, resolvedHexByStatusId: [:], selectedWorkspace: selected, workspaceGroups: [])
        }
        #expect(state.statusGroups == nil)
        #expect(state.collapsedColorSectionHexes.isEmpty)
        state.prepareStatusGroupsOnListArrival(list: Self.list, resolvedHexByStatusId: Self.colors, selectedWorkspace: selected, workspaceGroups: [])
        let folds = try #require(state.statusGroups)
        #expect(folds.collapsedStatusIds.contains("done"))
        #expect(!folds.collapsedStatusIds.contains("parked"))
        #expect(!folds.areaCollapsed)
    }

    @Test(arguments: [false, true])
    func aDeliberateColorToggleUpdatesThePendingCopySource(_ deliberatelyFolded: Bool) throws {
        let state = SidebarState(collapsedColorSectionHexes: ["#AABBCC"], statusGroups: nil)
        let selected = try Self.selectedWorkspace()
        state.prepareStatusGroupsForSelection(list: .cmuxFive, resolvedHexByStatusId: [:], selectedWorkspace: selected, workspaceGroups: [])
        state.toggleColorSection(hex: "#AABBCC")
        if !deliberatelyFolded { state.toggleColorSection(hex: "#AABBCC") }
        #expect(state.collapsedColorSectionHexes.contains("#AABBCC") == deliberatelyFolded)
        // Automatic selection reveals the color again but must preserve the explicit choice for the pending copy.
        state.prepareStatusGroupsForSelection(list: .cmuxFive, resolvedHexByStatusId: [:], selectedWorkspace: selected, workspaceGroups: [])
        state.prepareStatusGroupsOnListArrival(list: Self.list, resolvedHexByStatusId: Self.colors, selectedWorkspace: selected, workspaceGroups: [])
        let folds = try #require(state.statusGroups)
        #expect(folds.collapsedStatusIds.contains("done") == deliberatelyFolded)
        #expect(!folds.collapsedStatusIds.contains("parked"))
        #expect(!folds.areaCollapsed)
    }

    @Test func anEmptyFileListCompletesTheOneTimeCopy() throws {
        let state = SidebarState(collapsedColorSectionHexes: ["#AABBCC"], statusGroups: nil)
        state.prepareStatusGroupsForSelection(list: .init(entries: [], source: .file),
                                              resolvedHexByStatusId: [:], selectedWorkspace: nil, workspaceGroups: [])
        #expect(state.statusGroups != nil)
        state.prepareStatusGroupsOnListArrival(list: Self.list, resolvedHexByStatusId: Self.colors, selectedWorkspace: nil, workspaceGroups: [])
        #expect(try #require(state.statusGroups).collapsedStatusIds.isEmpty)
    }

    @Test func aListRevisionDoesNotReopenASeededFoldOverTheSelection() throws {
        let original = WorkspaceStatusGroupsState(areaCollapsed: true, collapsedStatusIds: ["parked", "not-listed"])
        let state = SidebarState(collapsedColorSectionHexes: ["#AABBCC"], statusGroups: original)
        let renamed = WorkspaceStatusList(entries: [
            WorkspaceStatusEntry(id: "parked", name: "Renamed", extends: .todo),
            WorkspaceStatusEntry(id: "done", name: "Done"),
        ], source: .file)
        state.prepareStatusGroupsOnListArrival(list: renamed, resolvedHexByStatusId: Self.colors,
                                              selectedWorkspace: try Self.selectedWorkspace(), workspaceGroups: [])
        #expect(state.statusGroups == original)
    }

    @Test func aFoldedAreaHidesEveryStatusHeaderAndMember() {
        let first = UUID(), second = UUID(), loose = UUID()
        let result = Self.render(first: first, second: second, loose: loose, folds: .init(areaCollapsed: true))
        // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
        #expect(result.items.map(\.id) == [.workspacesArea(), .workspace(loose), .statusesArea()])
    }

    @Test func aFoldedStatusHidesOnlyItsOwnMembers() {
        let first = UUID(), second = UUID(), loose = UUID()
        let result = Self.render(first: first, second: second, loose: loose,
                                 folds: .init(collapsedStatusIds: ["parked"]))
        // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
        #expect(result.items.map(\.id) == [
            .workspacesArea(), .workspace(loose), .statusesArea(), .statusGroup("parked"), .statusGroup("done"), .workspace(second),
        ])
    }

    @Test(arguments: [false, true])
    func theDebugRowsReportTheDrawnHeadersFoldState(_ area: Bool) throws {
        let items: [SidebarWorkspaceRenderItem] = area ? [.statusesHeader] : [.statusesHeader, .statusGroupHeader(statusId: "parked")]
        let rows = SidebarDebugRow.rows(
            from: items, workspaceTitle: { _ in "" }, groupName: { _ in "" }, groupIsFolded: { _ in false },
            groupIdOfWorkspace: { _ in nil }, statusName: { $0 },
            statusGroups: .init(areaCollapsed: area, collapsedStatusIds: ["parked"])
        )
        #expect(try #require(rows.last).folded)
    }

    @Test(arguments: [false, true], [false, true])
    func unreadRebuildUsesFreshDependenciesAndIsZeroWhileOpen(_ area: Bool, _ collapsed: Bool) throws {
        let ids: Set<UUID> = [UUID(), UUID()]
        let kind: SidebarStatusHeaderKind = area ? .statusesArea : .statusGroup("parked")
        let folds = WorkspaceStatusGroupsState(areaCollapsed: collapsed, collapsedStatusIds: collapsed ? ["parked"] : [])
        let configuration = Self.configuration(kind: kind, ids: ids, folds: folds, onToggle: {})
        let rebuild = try #require(configuration.appKitGroupHeaderUnreadRebuild)
        let first = rebuild(Self.unread(ids: ids, count: 2))
        let second = rebuild(Self.unread(ids: ids, count: 5))
        #expect(first.anchorUnreadCount == (collapsed ? 4 : 0))
        #expect(second.anchorUnreadCount == (collapsed ? 10 : 0))
        #expect(first.statusHeaderKind == kind)
        #expect(second.statusHeaderKind == kind)
        #expect(configuration.appKitUnreadDependencyWorkspaceIds == ids)
    }

    enum Activation: CaseIterable, Equatable, Sendable { case rowClick, chevron, voiceOver }

    @Test(arguments: [false, true], Activation.allCases)
    func bothHeadersFoldThroughOneActionAndSelectNothing(_ area: Bool, _ activation: Activation) async throws {
        _ = NSApplication.shared
        let state = SidebarState()
        let kind: SidebarStatusHeaderKind = area ? .statusesArea : .statusGroup("parked")
        var focused = 0
        let configuration = Self.configuration(kind: kind, ids: [UUID()], folds: try #require(state.statusGroups), onToggle: {
            if area { state.toggleStatusesArea() } else { state.toggleStatusGroup(id: "parked") }
        }, onFocusAnchor: { _ in focused += 1 })
        switch activation {
        case .rowClick:
            let controller = SidebarWorkspaceTableController()
            let container = controller.makeContainerView()
            container.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
            defer { controller.dismantleContainerView(container) }
            controller.apply(rows: [configuration], actions: Self.tableActions(), workspaceIds: [],
                             selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil)
            await Self.flush()
            #expect(controller.dispatchRowClick(.init(rowId: configuration.id, modifiers: [])) == .dispatched)
            #expect(container.tableView.selectedRow == -1)
        case .chevron, .voiceOver:
            let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
            cell.configure(model: try #require(configuration.appKitGroupHeaderModel),
                           actions: try #require(configuration.appKitGroupHeaderActions),
                           isPointerHovering: false, contextMenuDidOpen: {}, contextMenuDidClose: {})
            if activation == .voiceOver {
                #expect(cell.accessibilityPerformPress())
            } else {
                let chevron = try #require(cell.subviews.compactMap { $0 as? SidebarHeaderGlyphButton }.first)
                chevron.performClick(nil)
            }
        }
        let folds = try #require(state.statusGroups)
        #expect(area ? folds.areaCollapsed : folds.collapsedStatusIds.contains("parked"))
        #expect(focused == 0)
    }

    @Test(arguments: [false, true])
    func anUnreadRepaintKeepsTheHeaderIdentityAndFoldAction(_ area: Bool) throws {
        let kind: SidebarStatusHeaderKind = area ? .statusesArea : .statusGroup("parked")
        let ids: Set<UUID> = [UUID()]
        var toggled = 0
        let original = Self.configuration(kind: kind, ids: ids,
                                         folds: .init(areaCollapsed: true, collapsedStatusIds: ["parked"]),
                                         onToggle: { toggled += 1 })
        let repainted = original.applyingUnreadSnapshot(Self.unread(ids: ids, count: 3))
        #expect(repainted.id == original.id)
        #expect(repainted.statusHeaderKind == kind)
        #expect(!repainted.isGroupHeader && !repainted.isColorSectionHeader)
        #expect(repainted.appKitGroupHeaderModel?.anchorUnreadCount == 3)
        repainted.colorSectionToggle?()
        #expect(toggled == 1)
    }

    private static func selectedWorkspace() throws -> Workspace {
        let workspace = Workspace()
        workspace.customColor = "#AABBCC"
        #expect(workspace.setOwnStatus(try #require(list.entry(id: "parked")), list: list))
        return workspace
    }

    private static func render(
        first: UUID, second: UUID, loose: UUID, folds: WorkspaceStatusGroupsState
    ) -> SidebarStatusRenderItemsResolution {
        VerticalTabsSidebar.resolveRenderItems(
            colorSectionProjection: .project(workspaces: [], paletteEntries: [], collapsedHexes: []),
            baseItems: [first, second, loose].map { .workspace(workspaceId: $0) },
            statusGroupProjection: .init(groups: [
                .init(statusId: "parked", memberWorkspaceIds: [first]),
                .init(statusId: "done", memberWorkspaceIds: [second]),
            ]), folds: folds
        , groups: [])
    }

    private static func configuration(
        kind: SidebarStatusHeaderKind, ids: Set<UUID>, folds: WorkspaceStatusGroupsState,
        onToggle: @escaping @MainActor () -> Void,
        onFocusAnchor: @escaping (NSEvent.ModifierFlags) -> Void = { _ in }
    ) -> SidebarWorkspaceTableRowConfiguration {
        VerticalTabsSidebar.statusHeaderConfiguration(
            kind: kind, presentation: .init(name: "Parked", tintHex: nil, glyph: nil, behavesAs: .todo),
            memberCount: ids.count, memberIds: ids, folds: folds,
            environment: .init(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init()),
            sidebarFontScale: 1.0, // (cm-128.16)
            onToggle: onToggle, onFocusAnchor: onFocusAnchor
        )
    }

    private static func unread(ids: Set<UUID>, count: Int) -> SidebarUnreadSnapshot {
        var summaries = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, SidebarWorkspaceUnreadSummary(unreadCount: count, latestNotificationText: nil))
        })
        summaries[UUID()] = SidebarWorkspaceUnreadSummary(unreadCount: 100, latestNotificationText: nil)
        return SidebarUnreadSnapshot(summaryByWorkspaceId: summaries)
    }

    private static func flush() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    private static func tableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {}, createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in }, movingWorkspaceCount: { _ in 1 }, endWorkspaceDrag: {}, isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _, _ in nil }, performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false }, clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw }, canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false }, moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in }, updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in }, setBonsplitDropIndicator: { _ in }
        )
    }
}
