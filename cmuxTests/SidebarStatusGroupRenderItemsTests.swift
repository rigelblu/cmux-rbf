import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// cm-110.1 Piece 1: the `Statuses` area in the sidebar. Every test here calls the code the sidebar calls. (#cm-110.1)
@MainActor
@Suite struct SidebarStatusGroupRenderItemsTests {
    private typealias Sidebar = VerticalTabsSidebar

    // MARK: Fixtures

    private struct Fixture {
        let wA = UUID()
        let wB = UUID()
        let wC = UUID()
        let wD = UUID()

        /// next: [wB], parked: [] (empty), done: [wC]
        var projection: WorkspaceStatusGroupProjection {
            WorkspaceStatusGroupProjection(groups: [
                WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: [wB]),
                WorkspaceStatusGroup(statusId: "parked", memberWorkspaceIds: []),
                WorkspaceStatusGroup(statusId: "done", memberWorkspaceIds: [wC]),
            ])
        }

        var baseItems: [SidebarWorkspaceRenderItem] {
            [.workspace(workspaceId: wA), .workspace(workspaceId: wB), .workspace(workspaceId: wC), .workspace(workspaceId: wD)]
        }
    }

    private static let emptyColorProjection = SidebarWorkspaceColorSectionProjection.project(
        workspaces: [],
        paletteEntries: [],
        collapsedHexes: []
    )

    private static let palette: [WorkspaceColorPaletteEntry] = [
        WorkspaceColorPaletteEntry(name: "Blue", hex: "#3B82F6"),
        WorkspaceColorPaletteEntry(name: "Yellow", hex: "#EAB308"),
        WorkspaceColorPaletteEntry(name: "Teal", hex: "#14B8A6"),
    ]

    private static func snapshot(_ id: UUID, color: String?, pinned: Bool = false) -> SidebarWorkspaceColorSectionWorkspaceSnapshot {
        SidebarWorkspaceColorSectionWorkspaceSnapshot(id: id, groupId: nil, isPinned: pinned, customColor: color)
    }

    private static func environment() -> SidebarWorkspaceTableEnvironmentSnapshot {
        SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
    }

    /// Render items compare by their row identity.
    private static func ids(_ items: [SidebarWorkspaceRenderItem]) -> [SidebarWorkspaceRenderItemID] {
        items.map(\.id)
    }

    // MARK: Render items

    @Test func theStatusesHeaderComesLastAndEachStatusGroupHoldsItsRowsInFileOrder() {
        let f = Fixture()
        let resolution = Sidebar.resolveRenderItems(
            colorSectionProjection: Self.emptyColorProjection,
            baseItems: f.baseItems,
            statusGroupProjection: f.projection
        , groups: [])
        let expected: [SidebarWorkspaceRenderItem] = [
            .workspacesHeader, // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
            .workspace(workspaceId: f.wA),
            .workspace(workspaceId: f.wD),
            .statusesHeader,
            .statusGroupHeader(statusId: "next"),
            .workspace(workspaceId: f.wB),
            .statusGroupHeader(statusId: "parked"),
            .statusGroupHeader(statusId: "done"),
            .workspace(workspaceId: f.wC),
        ]
        #expect(Self.ids(resolution.items) == Self.ids(expected))
    }

    @Test func noProjectionLeavesTheItemsAsTheyWere() {
        let f = Fixture()
        let resolution = Sidebar.resolveRenderItems(
            colorSectionProjection: Self.emptyColorProjection,
            baseItems: f.baseItems,
            statusGroupProjection: nil
        , groups: [])
        #expect(Self.ids(resolution.items) == Self.ids(f.baseItems))
    }

    @Test func commandNumbersComeFromTheBaseItemsEvenWhenRowsMoveIntoTheArea() {
        let f = Fixture()
        let resolution = Sidebar.resolveRenderItems(
            colorSectionProjection: Self.emptyColorProjection,
            baseItems: f.baseItems,
            statusGroupProjection: f.projection
        , groups: [])
        #expect(resolution.numberedWorkspaceIndexById == [f.wA: 0, f.wB: 1, f.wC: 2, f.wD: 3])
        // The drawn order puts wB and wC after wD, so numbering the drawn items would change the numbers.
        #expect(SidebarWorkspaceRenderItem.numberedWorkspaceIndexById(from: resolution.items) != resolution.numberedWorkspaceIndexById)
    }

    @Test func theNestedWindowKeepsItsRowsAndGetsTheSameArea() {
        let wParent = UUID()
        let wChild = UUID()
        let wLoose = UUID()
        let gParent = UUID()
        let gChild = UUID()
        let parentGroup = WorkspaceGroup(
            id: gParent, name: "Parent", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: wParent, customColor: nil, iconSymbol: nil, parentGroupId: nil
        )
        let childGroup = WorkspaceGroup(
            id: gChild, name: "Child", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: wChild, customColor: nil, iconSymbol: nil, parentGroupId: gParent
        )
        let groupsById: [UUID: WorkspaceGroup] = [gParent: parentGroup, gChild: childGroup]
        #expect(SidebarNestedWorkspaceRows.hasNestedGroup(groupsById))

        let nestedItems = SidebarNestedWorkspaceRows.items(
            tabs: [Workspace(id: wParent), Workspace(id: wChild), Workspace(id: wLoose)],
            groupsById: groupsById,
            orderedGroups: [parentGroup, childGroup],
            effectiveMembership: [wParent: gParent, wChild: gChild, wLoose: nil]
        )
        let projection = WorkspaceStatusGroupProjection(groups: [
            WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: [wLoose]),
        ])
        let resolution = Sidebar.resolveRenderItems(
            colorSectionProjection: Self.emptyColorProjection,
            baseItems: nestedItems,
            statusGroupProjection: projection
        , groups: [])
        let area: [SidebarWorkspaceRenderItem] = [
            .statusesHeader, .statusGroupHeader(statusId: "next"), .workspace(workspaceId: wLoose),
        ]
        #expect(Self.ids(Array(resolution.items.suffix(3))) == Self.ids(area))
        // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
        let nestedWithoutLoose = [SidebarWorkspaceRenderItem.workspacesHeader]
            + nestedItems.filter { $0.id != SidebarWorkspaceRenderItem.workspace(workspaceId: wLoose).id }
        #expect(Self.ids(Array(resolution.items.dropLast(3))) == Self.ids(nestedWithoutLoose))
        #expect(resolution.items.contains { item in
            if case .groupHeader(let id, _) = item, id == gChild { return true }
            return false
        })
    }

    @Test func neitherStatusHeaderIsAnInteractiveRow() {
        let w1 = UUID()
        let g1 = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: g1, anchorWorkspaceId: w1),
            .workspace(workspaceId: w1),
            .statusesHeader,
            .statusGroupHeader(statusId: "done"),
        ]
        // A workspace group's header stands in for its anchor, so w1 appears twice (base behavior).
        let interactiveIds = SidebarWorkspaceRenderItem.interactiveRowIds(from: items)
        #expect(interactiveIds == [w1, w1])
        #expect(!interactiveIds.contains(SidebarStatusHeaderIdentity.statusesAreaUUID))
        #expect(!interactiveIds.contains(SidebarStatusHeaderIdentity.uuid(forStatusId: "done")))
    }

    // MARK: The gate (04:91, 09:434)

    @Test func withTheControlsOffAListInTheFileChangesNothing() {
        let f = Fixture()
        let list = WorkspaceStatusList(entries: [WorkspaceStatusEntry(id: "next", name: "Next", color: "#3B82F6")], source: .file)
        let item = WorkspaceStatusGroupProjectionItem(workspaceId: f.wA, resolution: .ownInEffect(list.entries[0]))
        let on = Sidebar.statusGroupProjection(items: [item], list: list, colorHexes: ["next": "#3B82F6"], controlsEnabled: true, workspaceGroups: [])
        let off = Sidebar.statusGroupProjection(items: [item], list: list, colorHexes: ["next": "#3B82F6"], controlsEnabled: false, workspaceGroups: [])
        #expect(on?.group(for: "next")?.memberWorkspaceIds == [f.wA])
        #expect(off == nil)

        // No area means no exclusions: the linked color keeps its color group, as before cm-110.1.
        let colorProjection = Sidebar.colorSectionProjection(
            workspaces: [Self.snapshot(f.wA, color: "#3B82F6")],
            collapsedHexes: [],
            statusGroupProjection: off,
            colorHexes: ["next": "#3B82F6"],
            paletteEntries: Self.palette
        )
        #expect(colorProjection.sections.map { $0.id.normalizedHex } == ["#3B82F6"])
    }

    // MARK: Color groups beside the area

    @Test func aColorAStatusNamesHasNoColorGroupAmongTheUnpinnedRowsButOneNobodyNamesKeepsIt() {
        let wBlueLoose = UUID()
        let wBluePinned = UUID()
        let wTeal = UUID()
        let wTealMember = UUID() // sits in a status group, wears teal
        let projection = WorkspaceStatusGroupProjection(groups: [
            WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: [wTealMember]),
        ])
        let colorProjection = Sidebar.colorSectionProjection(
            workspaces: [
                Self.snapshot(wBlueLoose, color: "#3B82F6"),
                Self.snapshot(wBluePinned, color: "#3B82F6", pinned: true),
                Self.snapshot(wTeal, color: "#14B8A6"),
                Self.snapshot(wTealMember, color: "#14B8A6"),
            ],
            collapsedHexes: [],
            statusGroupProjection: projection,
            colorHexes: ["next": "#3B82F6"],
            paletteEntries: Self.palette
        )
        let unpinned = colorProjection.sections.filter { $0.id.pinTier == .unpinned }
        // Blue is named by a status, so its unpinned color group is gone; teal is not named, so it stays,
        // without the row that moved into the status group.
        #expect(unpinned.map { $0.id.normalizedHex } == ["#14B8A6"])
        #expect(unpinned.first?.memberWorkspaceIds == [wTeal])
        // A pinned row joins no status group, so the pinned blue color group stays.
        #expect(colorProjection.sections.contains { $0.id.pinTier == .pinned && $0.id.normalizedHex == "#3B82F6" })
    }

    @Test func aMoveInsideAColorGroupStillPerformsWithAStatusGroupBesideIt() throws {
        let manager = TabManager()
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) } // a new manager starts with one
        let ids = manager.tabs.map(\.id)
        let (w1, w2, w3, w4) = (ids[0], ids[1], ids[2], ids[3])
        manager.tabs[0].customColor = "#EAB308"
        manager.tabs[1].customColor = "#EAB308"
        manager.tabs[2].customColor = "#3B82F6"
        manager.tabs[3].customColor = "#3B82F6"
        let statusProjection = WorkspaceStatusGroupProjection(groups: [
            WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: [w3, w4]),
        ])

        // What the perform-time re-check builds.
        let fresh = Sidebar.colorSectionProjection(
            workspaces: manager.tabs.map { Self.snapshot($0.id, color: $0.customColor, pinned: $0.isPinned) },
            collapsedHexes: [],
            statusGroupProjection: statusProjection,
            colorHexes: ["next": "#3B82F6"],
            paletteEntries: Self.palette
        )
        let section = try #require(fresh.sectionByWorkspaceId[w2])
        #expect(section.memberWorkspaceIds == [w1, w2])
        #expect(fresh.sectionByWorkspaceId[w1]?.id == section.id)
        #expect(fresh.sectionByWorkspaceId[w3] == nil)

        #expect(manager.reorderWorkspaceWithinColorSection(
            tabId: w2, targetWorkspaceId: w1, insertBefore: true, memberWorkspaceIds: section.memberWorkspaceIds
        ))
        #expect(manager.tabs.map(\.id) == [w2, w1, w3, w4])
    }

    // MARK: Indent

    @Test func aRowInAStatusGroupIsIndentedWithoutPuttingDepthsInTheNestedMap() {
        let f = Fixture()
        // A window with no nested group has an empty depth map; that emptiness is how drop lines know it.
        let nestedDepths = SidebarNestedWorkspaceRows.depthById(groupsById: [:], effectiveMembership: [:])
        #expect(nestedDepths.isEmpty)
        #expect(Sidebar.rowDepth(of: f.wB, rowDepthById: nestedDepths, statusGroupProjection: f.projection) == 2)
        #expect(Sidebar.rowDepth(of: f.wA, rowDepthById: nestedDepths, statusGroupProjection: f.projection) == 0)
        #expect(Sidebar.rowDepth(of: f.wB, rowDepthById: [f.wB: 1], statusGroupProjection: f.projection) == 1)

        let plan = SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: f.wA,
            indicator: SidebarDropIndicator(tabId: f.wB, edge: .top),
            indicatorScope: .raw,
            action: .reorder(targetIndex: 0, usesTopLevelRows: true, explicitGroupId: nil)
        )
        #expect(SidebarNestedDropLine.level(for: plan, depthById: nestedDepths) == nil)
    }

    // MARK: Drag (interim rule)

    private struct DropFixture {
        let wNext1 = UUID()
        let wNext2 = UUID()
        let wParked = UUID()
        let wLoose = UUID()
        var projection: WorkspaceStatusGroupProjection {
            WorkspaceStatusGroupProjection(groups: [
                WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: [wNext1, wNext2]),
                WorkspaceStatusGroup(statusId: "parked", memberWorkspaceIds: [wParked]),
            ])
        }

        func basePlan(dragged: UUID, target: UUID?, edge: SidebarDropEdge) -> SidebarWorkspaceReorderDropPlan {
            SidebarWorkspaceReorderDropPlan(
                draggedWorkspaceId: dragged,
                indicator: SidebarDropIndicator(tabId: target, edge: edge),
                indicatorScope: .raw,
                action: .reorder(targetIndex: 0, usesTopLevelRows: true, explicitGroupId: nil) // what the generic planner would hand over
            )
        }
    }

    @Test(arguments: [(SidebarDropEdge.top, true), (SidebarDropEdge.bottom, false)])
    func statusRowDroppedAmongItsOwnGroupPlansStatusGroupMove(edge: SidebarDropEdge, insertBefore: Bool) {
        let f = DropFixture()
        let result = Sidebar.statusGroupInterimDrop(
            draggedTabId: f.wNext1,
            basePlan: f.basePlan(dragged: f.wNext1, target: f.wNext2, edge: edge),
            projection: f.projection
        )
        guard case .plan(let plan) = result else {
            Issue.record("expected a plan, got \(result)")
            return
        }
        #expect(plan.action == .statusGroupMove(
            statusId: "next",
            targetWorkspaceId: f.wNext2,
            insertBefore: insertBefore,
            memberWorkspaceIds: [f.wNext1, f.wNext2]
        ))
        #expect(plan.draggedWorkspaceId == f.wNext1)
    }

    @Test func statusRowDroppedAnywhereButItsOwnGroupIsRefused() {
        let f = DropFixture()
        // another status group's row, a loose row, and no row at all
        for target in [f.wParked, f.wLoose, nil] as [UUID?] {
            let result = Sidebar.statusGroupInterimDrop(
                draggedTabId: f.wNext1,
                basePlan: f.basePlan(dragged: f.wNext1, target: target, edge: .bottom),
                projection: f.projection
            )
            guard case .refused = result else {
                Issue.record("target \(String(describing: target)): expected refused, got \(result)")
                continue
            }
        }
    }

    @Test func workspaceFromOutsideDroppedOnAStatusGroupRowIsRefused() {
        let f = DropFixture()
        for target in [f.wNext1, f.wNext2, f.wParked] {
            let result = Sidebar.statusGroupInterimDrop(
                draggedTabId: f.wLoose,
                basePlan: f.basePlan(dragged: f.wLoose, target: target, edge: .top),
                projection: f.projection
            )
            guard case .refused = result else {
                Issue.record("target \(target): expected refused, got \(result)")
                continue
            }
        }
    }

    @Test func dropsThatTouchNoStatusGroupAreLeftToTheGenericRules() {
        let f = DropFixture()
        let other = UUID()
        let loose = Sidebar.statusGroupInterimDrop(
            draggedTabId: f.wLoose,
            basePlan: f.basePlan(dragged: f.wLoose, target: other, edge: .top),
            projection: f.projection
        )
        guard case .notStatusRelated = loose else {
            Issue.record("loose onto loose: expected notStatusRelated, got \(loose)")
            return
        }
        // no list in use: no projection, so the rule never applies, whatever the ids are
        let noArea = Sidebar.statusGroupInterimDrop(
            draggedTabId: f.wNext1,
            basePlan: f.basePlan(dragged: f.wNext1, target: f.wParked, edge: .top),
            projection: nil
        )
        guard case .notStatusRelated = noArea else {
            Issue.record("no projection: expected notStatusRelated, got \(noArea)")
            return
        }
    }

    // MARK: Perform

    @Test func plannedStatusGroupMoveHoldsOnlyWhileTheFreshGroupMatches() {
        let f = DropFixture()
        let members = [f.wNext1, f.wNext2]
        func holds(_ projection: WorkspaceStatusGroupProjection?, members: [UUID] = members, dragged: UUID? = nil, target: UUID? = nil) -> Bool {
            Sidebar.statusGroupMoveHolds(
                freshProjection: projection,
                statusId: "next",
                memberWorkspaceIds: members,
                draggedWorkspaceId: dragged ?? f.wNext1,
                targetWorkspaceId: target ?? f.wNext2
            )
        }
        #expect(holds(f.projection))
        // members changed since the plan: reordered, one left, one joined
        #expect(!holds(WorkspaceStatusGroupProjection(groups: [WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: [f.wNext2, f.wNext1])])))
        #expect(!holds(WorkspaceStatusGroupProjection(groups: [WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: [f.wNext1])])))
        #expect(!holds(WorkspaceStatusGroupProjection(groups: [WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: [f.wNext1, f.wNext2, f.wLoose])])))
        // the status group is gone, or no list is in use
        #expect(!holds(WorkspaceStatusGroupProjection(groups: [WorkspaceStatusGroup(statusId: "parked", memberWorkspaceIds: members)])))
        #expect(!holds(nil))
        // dragged or target not in the group (members equal, so only that check can refuse)
        #expect(!holds(f.projection, dragged: f.wLoose))
        #expect(!holds(f.projection, target: f.wLoose))
    }

    @Test func aStatusGroupRowMovesThroughTheTabManagerOnlyWhileTheGroupStillMatches() {
        let manager = TabManager()
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) } // a new manager starts with one
        let ids = manager.tabs.map(\.id)
        let (w1, w2, w3, w4) = (ids[0], ids[1], ids[2], ids[3])
        let members = [w1, w3] // slots 0 and 2; w2 and w4 are loose
        let projection = WorkspaceStatusGroupProjection(groups: [WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: members)])
        let plan = SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: w3,
            indicator: SidebarDropIndicator(tabId: w1, edge: .top),
            indicatorScope: .raw,
            action: .statusGroupMove(statusId: "next", targetWorkspaceId: w1, insertBefore: true, memberWorkspaceIds: members)
        )

        // The group changed since the plan (w4 joined): nothing moves.
        let stale = WorkspaceStatusGroupProjection(groups: [WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: members + [w4])])
        #expect(!Sidebar.performStatusGroupMove(
            plan: plan, statusId: "next", targetWorkspaceId: w1, insertBefore: true, memberWorkspaceIds: members,
            freshProjection: stale, tabManager: manager
        ))
        #expect(manager.tabs.map(\.id) == [w1, w2, w3, w4])

        // The group still matches: w3 goes before w1 in the two slots the group holds; w2 and w4 stay put.
        #expect(Sidebar.performStatusGroupMove(
            plan: plan, statusId: "next", targetWorkspaceId: w1, insertBefore: true, memberWorkspaceIds: members,
            freshProjection: projection, tabManager: manager
        ))
        #expect(manager.tabs.map(\.id) == [w3, w2, w1, w4])
    }

    // MARK: An empty workspace group's header sits just above the Statuses area (04:52, AS 34)

    private func as34Rows(count: Int) -> [Workspace] {
        let suiteName = "cmux.as34.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = TabManager(
            autoWelcomeIfNeeded: false, settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        while manager.tabs.count < count { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        return Array(manager.tabs.prefix(count))
    }

    private func as34Group(anchor: WorkspaceGroupAnchor, pinned: Bool = false) -> WorkspaceGroup {
        WorkspaceGroup(
            id: UUID(), name: "g", isCollapsed: false, isPinned: pinned, anchor: anchor,
            customColor: nil, iconSymbol: nil, parentGroupId: nil
        )
    }

    /// `knowsGroups` hands the tabs and groups to the resolver, which is how it finds the pinned tier (a `Pinned` section needs them). // (#cm-110.5)
    private func as34Items(rows: [Workspace], groups: [WorkspaceGroup], showsArea: Bool = true, knowsGroups: Bool = false) -> [SidebarWorkspaceRenderItem] {
        Sidebar.resolveRenderItems(
            colorSectionProjection: SidebarWorkspaceColorSectionProjection.project(
                workspaces: rows.map { .init(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned, customColor: $0.customColor) },
                paletteEntries: Self.palette, collapsedHexes: []
            ),
            baseItems: SidebarWorkspaceRenderItem.renderItems(
                tabs: rows, groupsById: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }), orderedGroups: groups
            ),
            statusGroupProjection: showsArea ? WorkspaceStatusGroupProjection(groups: [
                WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: []),
            ]) : nil
        , tabs: knowsGroups ? rows : [], groups: knowsGroups ? groups : []).items
    }

    @Test(arguments: [false, true])
    func anEmptyGroupHeaderSitsLastBeforeTheStatusesHeaderWhenTheAreaShows(withColorGroup: Bool) {
        let rows = as34Rows(count: 2)
        let first = as34Group(anchor: .empty(UUID()))
        let second = as34Group(anchor: .empty(UUID()))
        if withColorGroup { for row in rows { row.customColor = "#3B82F6" } }
        let items = as34Items(rows: rows, groups: [first, second])
        #expect(Array(Self.ids(items).suffix(4)) == Self.ids([
            .groupHeader(groupId: first.id, anchorWorkspaceId: first.anchorWorkspaceId),
            .groupHeader(groupId: second.id, anchorWorkspaceId: second.anchorWorkspaceId),
            .statusesHeader, .statusGroupHeader(statusId: "next"),
        ]))
        #expect(items.compactMap { item -> UUID? in
            if case .workspace(let id) = item { return id }; return nil
        } == rows.map(\.id))
    }

    @Test func anAnchorOnlyGroupHeaderStaysAtItsAnchorSlotWhenStatusesShow() throws {
        let suiteName = "cmux.anchor-only-placement.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = TabManager(
            autoWelcomeIfNeeded: false, settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let groupId = try #require(manager.createWorkspaceGroup(name: "One workspace"))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        #expect(manager.tabs.first?.id == group.anchorWorkspaceId)
        let base = SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs, groupsById: [groupId: group], orderedGroups: manager.workspaceGroups
        )
        let items = Sidebar.resolveRenderItems(
            colorSectionProjection: Self.emptyColorProjection, baseItems: base,
            statusGroupProjection: WorkspaceStatusGroupProjection(groups: [
                WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: []),
            ])
        , groups: []).items
        // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
        #expect(Self.ids(items) == Self.ids([.workspacesHeader] + base + [.statusesHeader, .statusGroupHeader(statusId: "next")]))
    }

    // Cold tests: keep the drawn order as the oracle, including the real UI's
    // single/block/group commit split. G is a source group, H the anchor-only header at its tab slot.
    private enum HeaderDrag: String {
        case looseRow, selectedRows, noncontiguousRows, groupHeader, groupedMember
        case nestedWindow, selectedGroupHeaders, pinnedRow, statusMember
        case colorMember, emptyPinnedHeader, nestedSelectedRows, collapsedGroupHeader
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aLooseRowLandsAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.looseRow, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func selectedRowsLandAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.selectedRows, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func noncontiguousRowsLandAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.noncontiguousRows, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aGroupHeaderLandsAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.groupHeader, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aGroupedMemberLandsAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.groupedMember, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aLooseRowInANestedWindowLandsAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.nestedWindow, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func selectedGroupHeadersLandAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.selectedGroupHeaders, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aPinnedRowClampsAtTheTopAndAdoptsAtTheBottomOfAHeader(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.pinnedRow, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aStatusMemberCannotLeaveItsStatusForAHeader(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.statusMember, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aColorMemberOnlyLeavesItsSectionToAdoptTheHeader(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.colorMember, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func anEmptyPinnedHeaderStaysInItsTierAtAHeader(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.emptyPinnedHeader, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func selectedRowsInANestedWindowLandAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.nestedSelectedRows, edge: edge)
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aCollapsedGroupHeaderLandsAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        try checkHeaderDrop(.collapsedGroupHeader, edge: edge)
    }

    private func checkHeaderDrop(_ shape: HeaderDrag, edge: SidebarDropEdge) throws {
        let suiteName = "cmux.cold-header.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false,
                                 settings: UserDefaultsSettingsClient(defaults: defaults),
                                 closeTabWarningDefaults: defaults)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let loose = manager.tabs.map(\.id)
        let (d, e, b, c) = (loose[0], loose[1], loose[2], loose[3])
        var labels = [d: "D", e: "E", b: "B", c: "C"]
        var dragged = d
        var selected: Set<UUID> = [d]
        var movingRenderedIds: Set<UUID> = [d]
        var sourceGroupId: UUID?
        if [.groupHeader, .groupedMember, .nestedWindow, .selectedGroupHeaders, .nestedSelectedRows, .collapsedGroupHeader, .emptyPinnedHeader].contains(shape) {
            let g = try #require(manager.createWorkspaceGroup(name: "Source", childWorkspaceIds: [e]))
            sourceGroupId = g
            let anchor = try #require(manager.workspaceGroupAnchor(for: g)).id
            labels[anchor] = "G"
            if shape == .groupedMember { manager.addWorkspaceToGroup(workspaceId: d, groupId: g) }
            if shape == .groupHeader || shape == .selectedGroupHeaders || shape == .collapsedGroupHeader {
                dragged = anchor
                selected = [anchor]
                movingRenderedIds = [anchor, e]
            }
            if shape == .nestedWindow || shape == .nestedSelectedRows {
                let child = try #require(manager.createWorkspaceGroup(name: "Nested"))
                manager.moveWorkspaceGroup(groupId: child, intoParent: g)
                let childAnchor = try #require(manager.workspaceGroupAnchor(for: child)).id
                labels[childAnchor] = "N"
            }
            if shape == .collapsedGroupHeader { manager.setWorkspaceGroupCollapsed(groupId: g, isCollapsed: true) }
            if shape == .emptyPinnedHeader {
                manager.removeWorkspaceFromGroup(workspaceId: e)
                manager.setWorkspaceGroupPinned(groupId: g, isPinned: true)
                manager.closeWorkspace(try #require(manager.workspaceGroupAnchor(for: g)))
                let empty = try #require(manager.workspaceGroups.first { $0.id == g })
                #expect(empty.isEmpty)
                labels[empty.anchorWorkspaceId] = "G"
                dragged = g // UI maps a header without a live anchor to its group id.
                selected = [g]
                movingRenderedIds = [empty.anchorWorkspaceId]
            }
            if shape == .selectedGroupHeaders {
                let other = try #require(manager.createWorkspaceGroup(name: "Other", childWorkspaceIds: [d]))
                let otherAnchor = try #require(manager.workspaceGroupAnchor(for: other)).id
                labels[otherAnchor] = "J"
                selected.insert(otherAnchor)
                movingRenderedIds.formUnion([otherAnchor, d])
            }
        }
        let h = try #require(manager.createWorkspaceGroup(name: "Target"))
        let hAnchor = try #require(manager.workspaceGroupAnchor(for: h)).id
        labels[hAnchor] = "H"
        // Put H before B/C while keeping each source group's run intact.
        // The anchor-only header must stay at this same slot when statuses show.
        let trailing: Set<UUID> = [b, c]
        let tabs = manager.tabs
        manager.tabs = tabs.filter { $0.id != hAnchor && !trailing.contains($0.id) }
            + tabs.filter { $0.id == hAnchor } + tabs.filter { trailing.contains($0.id) }
        if shape == .selectedRows { selected = [d, e]; movingRenderedIds = selected }
        if shape == .noncontiguousRows { selected = [d, b]; movingRenderedIds = selected }
        if shape == .nestedSelectedRows { selected = [d, b]; movingRenderedIds = selected }
        if shape == .colorMember { try #require(manager.tabs.first { $0.id == d }).customColor = "#3B82F6" }
        if shape == .pinnedRow {
            manager.setPinned(try #require(manager.tabs.first { $0.id == d }), pinned: true)
        }
        let projection = WorkspaceStatusGroupProjection(groups: [
            WorkspaceStatusGroup(statusId: "next", memberWorkspaceIds: shape == .statusMember ? [d] : [])
        ])
        func visibleItems() -> [SidebarWorkspaceRenderItem] {
            Sidebar.resolveRenderItems(
                colorSectionProjection: SidebarWorkspaceColorSectionProjection.project(
                    workspaces: manager.tabs.map {
                        .init(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned, customColor: $0.customColor)
                    }, paletteEntries: Self.palette, collapsedHexes: []),
                baseItems: SidebarWorkspaceRenderItem.renderItems(
                    tabs: manager.tabs,
                    groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) }),
                    orderedGroups: manager.workspaceGroups),
                statusGroupProjection: projection
            , groups: []).items
        }
        func rowId(_ item: SidebarWorkspaceRenderItem) -> UUID? {
            switch item {
            case .workspace(let id): return id
            case .groupHeader(_, let anchor): return anchor
            default: return nil
            }
        }
        func order(_ items: [SidebarWorkspaceRenderItem]) -> String {
            items.map { item in
                if let id = rowId(item) { return labels[id] ?? "?" }
                switch item {
                case .colorSectionHeader: return "Q"
                case .statusesHeader: return "S"
                case .statusGroupHeader: return "next"
                default: return "?"
                }
            }.joined(separator: ",")
        }
        let before = visibleItems()
        let area = try #require(before.firstIndex { if case .statusesHeader = $0 { return true }; return false })
        let drawnHeaderIndex = try #require(before.firstIndex { rowId($0) == hAnchor })
        let drawnBIndex = try #require(before.firstIndex { rowId($0) == b })
        #expect(drawnHeaderIndex < drawnBIndex && drawnBIndex < area)
        #expect(manager.tabs.firstIndex { $0.id == hAnchor }! < manager.tabs.firstIndex { $0.id == b }!)
        let targets = before.enumerated().compactMap { index, item -> SidebarWorkspaceReorderDropTarget? in
            guard let id = rowId(item) else { return nil }
            let groupId: UUID?
            let header: Bool
            if case .groupHeader(let g, _) = item { groupId = g; header = true }
            else { groupId = manager.tabs.first { $0.id == id }?.groupId; header = false }
            return .init(workspaceId: id, groupId: groupId, isGroupHeader: header,
                         frame: CGRect(x: 0, y: CGFloat(index) * 28, width: 320, height: 28))
        }
        let header = try #require(targets.first { $0.workspaceId == hAnchor })
        let moving = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
            orderedWorkspaceIds: manager.tabs.map(\.id), selectedIds: selected, draggedId: dragged,
            anchorIds: Set(manager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId)))
        let basePlan = SidebarWorkspaceReorderDropResolver().plan(for: .init(
            point: CGPoint(x: 1, y: edge == .top ? header.frame.minY + 1 : header.frame.maxY - 1),
            draggedWorkspaceId: dragged,
            workspaces: manager.tabs.map { .init(id: $0.id, isPinned: $0.isPinned, groupId: $0.groupId) },
            groups: manager.workspaceGroups.map {
                .init(id: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId, isPinned: $0.isPinned,
                      isEmpty: $0.isEmpty, parentGroupId: $0.parentGroupId)
            }, targets: targets, draggedBlockWorkspaceIds: Set(moving)))
        if shape == .statusMember {
            if let basePlan {
                if case .refused = Sidebar.statusGroupInterimDrop(
                    draggedTabId: dragged, basePlan: basePlan, projection: projection) {} else {
                    Issue.record("A status member must be refused at H")
                }
            }
            #expect(order(visibleItems()) == order(before))
            return
        }
        if shape == .colorMember, edge == .top {
            if let basePlan { #expect(!SidebarWorkspaceColorSectionDropPolicy.allowsDropOutOfSection(action: basePlan.action)) }
            #expect(order(visibleItems()) == order(before))
            return
        }
        if shape == .colorMember, let basePlan {
            #expect(SidebarWorkspaceColorSectionDropPolicy.allowsDropOutOfSection(action: basePlan.action))
        }
        var expected = before.filter { item in
            if shape == .colorMember, case .colorSectionHeader = item { return false }
            return rowId(item).map { !movingRenderedIds.contains($0) } ?? true
        }
        let movedItems = before.filter { item in rowId(item).map { movingRenderedIds.contains($0) } ?? false }
        let expectedHeaderIndex = try #require(expected.firstIndex { rowId($0) == hAnchor })
        expected.insert(contentsOf: movedItems, at: expectedHeaderIndex + (edge == .bottom ? 1 : 0))
        // Root drops clamp the pin tier; explicit group adoption may unpin a
        // workspace. A header-only pinned group cannot adopt an unpinned group.
        if (shape == .pinnedRow && edge == .top) || shape == .emptyPinnedHeader { expected = before }
        let expectedOrder = order(expected)
        guard let plan = basePlan else {
            #expect(order(before) == expectedOrder,
                    "\(shape.rawValue) \(edge): expected \(expectedOrder); actual \(order(before)); resolver returned nil")
            return
        }
        switch plan.action {
        case .reorder(let index, let topLevel, let explicitGroup):
            if moving.count == 1 {
                _ = manager.reorderSidebarWorkspace(tabId: dragged, toIndex: index, isDragOperation: true,
                                                    usesTopLevelRows: topLevel, explicitGroupId: explicitGroup)
            } else {
                _ = manager.reorderSidebarWorkspaces(tabIds: moving, draggedTabId: dragged, toIndex: index,
                                                     isDragOperation: true, usesTopLevelRows: topLevel,
                                                     explicitGroupId: explicitGroup)
            }
        case .reorderGroup(let index): manager.moveWorkspaceGroup(groupId: dragged, toIndex: index)
        default: Issue.record("Unexpected local action \(plan.action)"); return
        }
        #expect(order(visibleItems()) == expectedOrder,
                "\(shape.rawValue) \(edge): expected \(expectedOrder); actual \(order(visibleItems()))")
        if edge == .bottom && [.looseRow, .selectedRows, .noncontiguousRows, .groupedMember, .nestedWindow, .nestedSelectedRows, .colorMember, .pinnedRow].contains(shape) {
            #expect(manager.tabs.filter { moving.contains($0.id) }.allSatisfy { $0.groupId == h },
                    "Local bottom-edge workspace drops should adopt H")
        }
        if let sourceGroupId, shape == .groupHeader {
            #expect(manager.workspaceGroups.first { $0.id == sourceGroupId }?.parentGroupId == nil,
                    "Group-header outer-edge drops should keep the root group intact")
        }
    }

    @Test(arguments: [SidebarDropEdge.top, .bottom])
    func aForeignRowLandsAtTheHeadersVisibleEdge(edge: SidebarDropEdge) throws {
        let suiteName = "cmux.cold-foreign-header.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        func makeManager() -> TabManager {
            TabManager(autoWelcomeIfNeeded: false, settings: UserDefaultsSettingsClient(defaults: defaults),
                       closeTabWarningDefaults: defaults)
        }
        let manager = makeManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let loose = manager.tabs.map(\.id)
        let source = makeManager()
        let dragged = try #require(source.tabs.first).id
        let groupId = try #require(manager.createWorkspaceGroup(name: "Target"))
        let anchor = try #require(manager.workspaceGroupAnchor(for: groupId)).id
        let tabs = manager.tabs
        manager.tabs = tabs.filter { $0.id == anchor } + tabs.filter { $0.id != anchor }
        let projection = WorkspaceStatusGroupProjection(groups: [.init(statusId: "next", memberWorkspaceIds: [])])
        func visibleItems() -> [SidebarWorkspaceRenderItem] {
            Sidebar.resolveRenderItems(
                colorSectionProjection: Self.emptyColorProjection,
                baseItems: SidebarWorkspaceRenderItem.renderItems(
                    tabs: manager.tabs,
                    groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) }),
                    orderedGroups: manager.workspaceGroups),
                statusGroupProjection: projection
            , groups: []).items
        }
        let before = visibleItems()
        let targets = before.enumerated().compactMap { index, item -> SidebarWorkspaceReorderDropTarget? in
            let id: UUID
            let header: Bool
            switch item {
            case .workspace(let workspace): id = workspace; header = false
            case .groupHeader(_, let workspace): id = workspace; header = true
            default: return nil
            }
            return .init(workspaceId: id, groupId: header ? groupId : nil, isGroupHeader: header,
                         frame: CGRect(x: 0, y: CGFloat(index) * 28, width: 320, height: 28))
        }
        let header = try #require(targets.first { $0.isGroupHeader })
        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(for: .init(
            point: CGPoint(x: 1, y: edge == .top ? header.frame.minY + 1 : header.frame.maxY - 1),
            draggedWorkspaceId: dragged, foreignDraggedIsPinned: false,
            workspaces: manager.tabs.map { .init(id: $0.id, isPinned: $0.isPinned, groupId: $0.groupId) },
            groups: manager.workspaceGroups.map {
                .init(id: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId, isPinned: $0.isPinned,
                      isEmpty: $0.isEmpty, parentGroupId: $0.parentGroupId)
            }, targets: targets)))
        guard case .crossWindow(_, let proposed) = plan.action else {
            Issue.record("Expected foreign action, got \(plan.action)"); return
        }
        // performCrossWindowWorkspaceDrop uses transfer primitives rather than
        // reorderSidebarWorkspace. Exercise those same primitives here:
        // same top-level slot -> raw index conversion, detach, then attach.
        // AppDelegate's private window registry dispatch itself is not covered.
        let topIds = manager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil, targetWorkspaceId: nil, usesTopLevelRows: true)
        let slot = max(0, min(proposed, topIds.count)) // both managers are unpinned
        let rawIndex = topIds.dropFirst(slot).compactMap { id in manager.tabs.firstIndex { $0.id == id } }.first
            ?? manager.tabs.count
        let workspace = try #require(source.detachWorkspace(tabId: dragged))
        manager.attachWorkspace(workspace, at: rawIndex, select: false)
        let hItem = SidebarWorkspaceRenderItem.groupHeader(groupId: groupId, anchorWorkspaceId: anchor)
        // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
        let expected: [SidebarWorkspaceRenderItem] = [.workspacesHeader] +
            (edge == .top ? [.workspace(workspaceId: dragged), hItem] : [hItem, .workspace(workspaceId: dragged)])
            + loose.map { .workspace(workspaceId: $0) }
            + [.statusesHeader, .statusGroupHeader(statusId: "next")]
        let labels = [loose[0]: "B", loose[1]: "C", dragged: "D", anchor: "H"]
        func order(_ items: [SidebarWorkspaceRenderItem]) -> String {
            items.map { item in
                switch item {
                case .workspace(let id), .groupHeader(_, let id): return labels[id] ?? "?"
                case .statusesHeader: return "S"
                case .statusGroupHeader: return "next"
                default: return "?"
                }
            }.joined(separator: ",")
        }
        #expect(Self.ids(visibleItems()) == Self.ids(expected),
                "foreign \(edge): expected \(order(expected)); actual \(order(visibleItems()))")
        // The existing foreign attach policy keeps the workspace ungrouped.
        // With H at its actual tab slot, that still lands at its drawn edge.
        #expect(workspace.groupId == nil)
    }

    @Test func withNoAreaAnEmptyGroupHeaderStaysWhereTheBaseItemsPutIt() {
        let rows = as34Rows(count: 2)
        let empty = as34Group(anchor: .empty(UUID()))
        #expect(Self.ids(as34Items(rows: rows, groups: [empty], showsArea: false)) == Self.ids([
            .workspace(workspaceId: rows[0].id), .workspace(workspaceId: rows[1].id),
            .groupHeader(groupId: empty.id, anchorWorkspaceId: empty.anchorWorkspaceId),
        ]))
    }

    @Test func anEmptyGroupHeaderWithAGroupThatHoldsRowsBelowItStaysAboveThatGroup() {
        let rows = as34Rows(count: 4)
        let before = as34Group(anchor: .empty(UUID()))
        let live = as34Group(anchor: .workspace(rows[1].id))
        let trailing = as34Group(anchor: .empty(UUID()))
        rows[1].groupId = live.id
        rows[2].groupId = live.id
        #expect(Self.ids(as34Items(rows: rows, groups: [before, live, trailing])) == Self.ids([
            .workspacesHeader, // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
            .workspace(workspaceId: rows[0].id),
            .groupHeader(groupId: before.id, anchorWorkspaceId: before.anchorWorkspaceId),
            .groupHeader(groupId: live.id, anchorWorkspaceId: live.anchorWorkspaceId),
            .workspace(workspaceId: rows[2].id), .workspace(workspaceId: rows[3].id),
            .groupHeader(groupId: trailing.id, anchorWorkspaceId: trailing.anchorWorkspaceId),
            .statusesHeader, .statusGroupHeader(statusId: "next"),
        ]))
    }

    @Test func anEmptyGroupHeaderBetweenTwoGroupsThatHoldRowsStaysWhereItIs() {
        let rows = as34Rows(count: 4)
        let first = as34Group(anchor: .workspace(rows[0].id))
        let empty = as34Group(anchor: .empty(UUID()))
        let second = as34Group(anchor: .workspace(rows[2].id))
        rows[0].groupId = first.id
        rows[1].groupId = first.id
        rows[2].groupId = second.id
        rows[3].groupId = second.id
        #expect(Self.ids(as34Items(rows: rows, groups: [first, empty, second])) == Self.ids([
            .workspacesHeader, // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
            .groupHeader(groupId: first.id, anchorWorkspaceId: first.anchorWorkspaceId),
            .workspace(workspaceId: rows[1].id),
            .groupHeader(groupId: empty.id, anchorWorkspaceId: empty.anchorWorkspaceId),
            .groupHeader(groupId: second.id, anchorWorkspaceId: second.anchorWorkspaceId),
            .workspace(workspaceId: rows[3].id), .statusesHeader, .statusGroupHeader(statusId: "next"),
        ]))
    }

    @Test func durableEmptyHeadersKeepTheirPinTierWhileAnchorOnlyHeadersKeepTheirTabSlot() {
        let rows = as34Rows(count: 3)
        let pinned = as34Group(anchor: .empty(UUID()), pinned: true)
        let anchorOnly = as34Group(anchor: .workspace(rows[0].id))
        let trailing = as34Group(anchor: .empty(UUID()))
        rows[0].groupId = anchorOnly.id
        #expect(Self.ids(as34Items(rows: rows, groups: [pinned, anchorOnly, trailing], knowsGroups: true)) == Self.ids([
            .pinnedHeader, // 02_decisions 2026-10-23 (cm-110.5): "pinned workspaces sit in a `Pinned` section at the very top"
            .groupHeader(groupId: pinned.id, anchorWorkspaceId: pinned.anchorWorkspaceId),
            .workspacesHeader, // 02_decisions 2026-10-23 (cm-110.4): "the rows with no status get a `Workspaces` header … shown whichever section comes first"
            .groupHeader(groupId: anchorOnly.id, anchorWorkspaceId: anchorOnly.anchorWorkspaceId),
            .workspace(workspaceId: rows[1].id), .workspace(workspaceId: rows[2].id),
            .groupHeader(groupId: trailing.id, anchorWorkspaceId: trailing.anchorWorkspaceId),
            .statusesHeader, .statusGroupHeader(statusId: "next"),
        ]))
    }

    // MARK: Header model, row configuration, cell

    private static func groupModel(statusId: String = "parked", memberCount: Int = 2) -> SidebarGroupHeaderRowModel {
        Sidebar.statusHeaderModel(
            kind: .statusGroup(statusId),
            presentation: SidebarStatusGroupPresentation(name: "Parked", tintHex: "#6B7280", glyph: .symbol("archivebox"), behavesAs: .todo),
            memberCount: memberCount,
            unreadCount: 0,
            isCollapsed: false,
            environment: environment()
        )
    }

    @Test func aStatusHeaderRowKeepsItsIdentityThroughAnUnreadRepaint() {
        let parkedUUID = SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")
        #expect(parkedUUID.uuid.6 >> 4 == 5) // RFC 4122 version 5: never a random (version 4) workspace or group id
        #expect(SidebarStatusHeaderIdentity.statusesAreaUUID.uuid.6 >> 4 == 5)

        let model = Self.groupModel()
        var toggled = 0
        let config = SidebarWorkspaceTableRowConfiguration(
            statusHeaderModel: model,
            statusHeaderKind: .statusGroup("parked"),
            actions: Sidebar.statusHeaderActions(),
            colorSectionToggle: { toggled += 1 },
            environment: Self.environment(),
            unreadDependencyWorkspaceIds: [UUID()],
            unreadRebuild: { _ in
                var changed = model
                changed.anchorUnreadCount = 3 // a rebuilt model that differs, so the repaint really rebuilds the row
                return changed
            }
        )
        let repainted = config.applyingUnreadSnapshot(SidebarUnreadSnapshot())
        #expect(repainted.appKitGroupHeaderModel?.anchorUnreadCount == 3)
        #expect(repainted.id == config.id)
        #expect(repainted.id == .statusGroup("parked"))
        #expect(repainted.statusHeaderKind == .statusGroup("parked"))
        #expect(!repainted.isGroupHeader)
        #expect(!repainted.isColorSectionHeader)
        #expect(repainted.workspaceId == parkedUUID)
        #expect(repainted.groupId == nil)
        #expect(repainted.colorSectionToggle != nil)
        repainted.colorSectionToggle?()
        #expect(toggled == 1)
    }

    private func makeTableActions(onClose: @escaping (UUID) -> Void) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: onClose,
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in },
            movingWorkspaceCount: { _ in 1 },
            endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _, _ in nil },
            performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {},
            currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw },
            canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    private struct PlainRow: View, Equatable {
        var body: some View { EmptyView() }
    }

    private func flush() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    @Test func aStatusHeaderIsNotSomethingThePointerCanDragDropOnOrCloseAndAClickSelectsNothing() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 400)

        var closed: [UUID] = []
        var focused = 0
        let actions = Sidebar.statusHeaderActions(onFocusAnchor: { _ in focused += 1 })
        let statusRow = SidebarWorkspaceTableRowConfiguration(
            statusHeaderModel: Self.groupModel(),
            statusHeaderKind: .statusGroup("parked"),
            actions: actions,
            colorSectionToggle: nil,
            environment: Self.environment()
        )
        let workspaceId = UUID()
        let workspaceRow = SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: Self.environment(),
            equivalenceValue: PlainRow()
        ) { _, _ in AnyView(PlainRow()) }
        controller.apply(
            rows: [statusRow, workspaceRow],
            actions: makeTableActions(onClose: { closed.append($0) }),
            workspaceIds: [workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flush()
        container.layoutSubtreeIfNeeded()

        // Piece3: the status row has its own header payload/identity; it remains outside workspace-only drop targets.
        #expect(controller.tableView(container.tableView, pasteboardWriterForRow: 0) != nil)
        #expect(controller.tableView(container.tableView, pasteboardWriterForRow: 1) != nil)
        #expect(controller.workspaceIdForDrag(statusRow, actions: nil) == statusRow.workspaceId)
        #expect(controller.workspaceIdForDrag(workspaceRow, actions: nil) == workspaceId)

        // Middle-click closes the workspace row and nothing for the status row.
        controller.middleClick(row: 0)
        #expect(closed.isEmpty)
        controller.middleClick(row: 1)
        #expect(closed == [workspaceId])

        // Click: handled, and it focuses no anchor.
        let outcome = controller.dispatchRowClick(.init(rowId: statusRow.id, modifiers: []))
        await flush()
        #expect(outcome == .dispatched)
        #expect(focused == 0)

        // Drop targets: the workspace row is one, the status row is not.
        let targets = controller.refreshReorderDropTargets()
        #expect(targets.contains { $0.workspaceId == workspaceId })
        #expect(!targets.contains { $0.workspaceId == statusRow.workspaceId })
    }

    @Test func aStatusHeaderCellIsAButtonThatSaysItsStateAndAReusedCellDropsTheRole() {
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        cell.configurePresentation(model: Self.groupModel(statusId: "parked", memberCount: 2))
        #expect(cell.accessibilityRole() == .button)
        #expect(cell.accessibilityIdentifier() == "sidebarStatusGroup.parked")
        #expect(cell.accessibilityLabel() == "Status group, Parked, 2 workspaces, expanded")
        #expect(cell.accessibilityValue() == nil)
        #expect(cell.accessibilityHelp() == nil)

        let area = Sidebar.statusHeaderModel(
            kind: .statusesArea, presentation: nil, memberCount: 3, unreadCount: 0, isCollapsed: false, environment: Self.environment()
        )
        cell.configurePresentation(model: area)
        #expect(cell.accessibilityIdentifier() == "sidebarStatusesArea")
        #expect(cell.accessibilityLabel() == "Workblocks, 3 status groups, expanded")

        // The same cell, reused for a workspace group's header: the group's own look, and no button role.
        cell.prepareForReuse()
        var group = Self.groupModel()
        group.statusHeaderKind = nil
        group.depth = 3
        cell.configurePresentation(model: group)
        #expect(cell.accessibilityRole() != .button)
        #expect(cell.accessibilityIdentifier() == "sidebarWorkspaceGroup.\(group.groupId.uuidString)")
        #expect(cell.accessibilityLabel() == group.name)
        #expect(cell.accessibilityDisclosureLevel() == 3)
        #expect(cell.isAccessibilityExpanded())
    }

    /// A workspace group's header, in a fresh cell: what upstream draws and says, to compare a reused cell with.
    @Test func aCellReusedBetweenGroupAndStatusHeadersKeepsNothingOfTheOtherKind() {
        var group = Self.groupModel()
        group.statusHeaderKind = nil
        group.depth = 3
        let fresh = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        fresh.configurePresentation(model: group)

        // group -> status: no disclosure level or expanded state of the group left over
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        cell.configurePresentation(model: group)
        #expect(cell.accessibilityDisclosureLevel() == 3)
        #expect(cell.isAccessibilityExpanded())
        cell.prepareForReuse()
        cell.configurePresentation(model: Self.groupModel())
        #expect(cell.accessibilityRole() == .button)
        #expect(cell.accessibilityDisclosureLevel() == 0)
        #expect(!cell.isAccessibilityExpanded())

        // status -> group: exactly what a fresh cell says (the role reset restores the default, it does not clear it)
        cell.prepareForReuse()
        cell.configurePresentation(model: group)
        #expect(cell.accessibilityRole() == fresh.accessibilityRole())
        #expect(cell.accessibilityDisclosureLevel() == fresh.accessibilityDisclosureLevel())
        #expect(cell.isAccessibilityExpanded() == fresh.isAccessibilityExpanded())
        #expect(cell.accessibilityIdentifier() == fresh.accessibilityIdentifier())
        #expect(cell.accessibilityLabel() == fresh.accessibilityLabel())
    }

    @Test func theWordsSayHowManyAndWhatThePressDoes() {
        #expect(SidebarStatusHeaderText.statusGroupLabel(name: "Parked", memberCount: 1, isCollapsed: false) == "Status group, Parked, 1 workspace, expanded")
        #expect(SidebarStatusHeaderText.statusGroupLabel(name: "Parked", memberCount: 0, isCollapsed: true) == "Status group, Parked, 0 workspaces, collapsed")
        #expect(SidebarStatusHeaderText.statusesAreaLabel(groupCount: 1, isCollapsed: false) == "Workblocks, 1 status group, expanded")
        #expect(SidebarStatusHeaderText.statusesAreaLabel(groupCount: 4, isCollapsed: true) == "Workblocks, 4 status groups, collapsed")
        // The chevron names the action, not the state.
        #expect(SidebarStatusHeaderText.chevronLabel(kind: .statusGroup("x"), isCollapsed: false) == "Collapse status group")
        #expect(SidebarStatusHeaderText.chevronLabel(kind: .statusGroup("x"), isCollapsed: true) == "Expand status group")
        #expect(SidebarStatusHeaderText.chevronLabel(kind: .statusesArea, isCollapsed: false) == "Collapse Workblocks area")
        #expect(SidebarStatusHeaderText.chevronLabel(kind: .statusesArea, isCollapsed: true) == "Expand Workblocks area")
    }

    // MARK: What a header shows

    @Test func aHeaderDrawsTheGlyphOfTheStatusItExtendsWhenItsEntryNamesNoIcon() {
        let list = WorkspaceStatusList(entries: [
            WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "#6B7280"),
            WorkspaceStatusEntry(id: "snooze", name: "Snooze", extends: .working, color: "#8B5CF6", icon: .symbol("moon.zzz.fill")),
        ], source: .file)
        let hexes = ["parked": "#6B7280", "snooze": "#8B5CF6"]
        let parked = SidebarStatusGroupPresentation.resolve(statusId: "parked", list: list, colorHexes: hexes)
        #expect(parked == SidebarStatusGroupPresentation(name: "Parked", tintHex: "#6B7280", glyph: nil, behavesAs: .todo))
        let snooze = SidebarStatusGroupPresentation.resolve(statusId: "snooze", list: list, colorHexes: hexes)
        #expect(snooze.glyph == .symbol("moon.zzz.fill"))
        #expect(snooze.behavesAs == .working)
        // The status is not in the list at all: its id, no color.
        let gone = SidebarStatusGroupPresentation.resolve(statusId: "gone", list: list, colorHexes: hexes)
        #expect(gone.name == "gone")
        #expect(gone.tintHex == nil)
        // The AppKit model carries what the presentation says.
        let model = Sidebar.statusHeaderModel(
            kind: .statusGroup("parked"), presentation: parked, memberCount: 0, unreadCount: 0, isCollapsed: false, environment: Self.environment()
        )
        #expect(model.statusBehavesAs == .todo)
        #expect(model.statusGlyph == nil)
        #expect(model.tintHex == "#6B7280")
    }

    @Test func thePresentationHelperResolvesEachProjectedStatusAndIsEmptyWithoutAnArea() {
        let list = WorkspaceStatusList(entries: [
            WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "#6B7280"),
            WorkspaceStatusEntry(id: "snooze", name: "Snooze", extends: .working, color: "#8B5CF6", icon: .symbol("moon.zzz.fill")),
        ], source: .file)
        let hexes = ["parked": "#6B7280", "snooze": "#8B5CF6"]
        let projection = WorkspaceStatusGroupProjection(groups: [
            WorkspaceStatusGroup(statusId: "snooze", memberWorkspaceIds: []),
            WorkspaceStatusGroup(statusId: "parked", memberWorkspaceIds: [UUID()]),
        ])
        let presentations = Sidebar.statusGroupPresentations(projection: projection, list: list, colorHexes: hexes)
        #expect(Set(presentations.keys) == ["snooze", "parked"])
        #expect(presentations["snooze"] == SidebarStatusGroupPresentation.resolve(statusId: "snooze", list: list, colorHexes: hexes))
        #expect(presentations["parked"]?.behavesAs == .todo)
        // No area, nothing to read.
        #expect(Sidebar.statusGroupPresentations(projection: nil, list: list, colorHexes: hexes).isEmpty)
    }

    @Test func theGlyphImageDrawsTheSymbolNotTheStatusGlyphThatSharesItsColor() throws {
        func image(glyph: WorkspaceStatusGlyph?) -> NSImage {
            SidebarStatusHeaderGlyphImage.make(
                presentation: SidebarStatusGroupPresentation(name: "Snooze", tintHex: "#8B5CF6", glyph: glyph, behavesAs: .working),
                fontScale: 1, colorScheme: .light, nameColor: .black, tickColor: .white
            )
        }
        let symbol = try #require(image(glyph: .symbol("moon.zzz.fill")).tiffRepresentation)
        let pie = try #require(image(glyph: nil).tiffRepresentation)
        let otherSymbol = try #require(image(glyph: .symbol("archivebox")).tiffRepresentation)
        // The pie is what a missing symbol falls back to, so the symbol must differ from it, and from another symbol.
        #expect(symbol != pie)
        #expect(symbol != otherSymbol)
        let rep = try #require(NSBitmapImageRep(data: symbol))
        var opaque = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { opaque += 1 }
        }
        #expect(opaque > 4)
    }

    @Test func aSwiftUIStatusHeaderScalesItsGlyphWithItsRowModel() {
        let presentation = SidebarStatusGroupPresentation(name: "Done", tintHex: nil, glyph: nil, behavesAs: .done)
        let model = Sidebar.statusHeaderModel(
            kind: .statusGroup("done"), presentation: presentation, memberCount: 1, unreadCount: 0,
            isCollapsed: false, environment: .init(
                colorScheme: .light, globalFontMagnificationPercent: 150, lazyContractProbe: SidebarLazyContractProbe()
            )
        )
        let header = SidebarStatusGroupSwiftUIHeader(
            statusId: "done", presentation: presentation, memberCount: 1, isCollapsed: false,
            listWidth: 320, colorScheme: .light, fontScale: model.fontScale,
            globalFontMagnificationPercent: model.globalFontMagnificationPercent
        )
        let expectedSide = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale).iconFrame
        #expect(header.glyphImage.size == NSSize(width: expectedSide, height: expectedSide))
        #expect(header.glyphImage.size != NSSize(
            width: SidebarWorkspaceGroupHeaderMetrics(fontScale: 1).iconFrame,
            height: SidebarWorkspaceGroupHeaderMetrics(fontScale: 1).iconFrame
        ))
    }

    @Test func theMountedSwiftUIStatusHeaderUsesItsRowModelsScaleAndAppKitTypography() throws {
        let presentation = SidebarStatusGroupPresentation(name: "Done", tintHex: nil, glyph: nil, behavesAs: .done)
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light, globalFontMagnificationPercent: 150, lazyContractProbe: SidebarLazyContractProbe()
        )
        let projection = WorkspaceStatusGroupProjection(groups: [
            WorkspaceStatusGroup(statusId: "done", memberWorkspaceIds: [UUID()])
        ])
        let model = Sidebar.statusHeaderModel(
            kind: .statusGroup("done"), presentation: presentation, memberCount: 1, unreadCount: 0,
            isCollapsed: false, environment: environment
        )
        let header = try #require(Sidebar.sidebarStatusGroupHeaderRow(
            statusId: "done", projection: projection, presentations: ["done": presentation],
            listWidth: 320, environment: environment
        ))
        #expect(header.fontScale == model.fontScale)
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        #expect(header.glyphImage.size == NSSize(width: metrics.iconFrame, height: metrics.iconFrame))
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        cell.configurePresentation(model: model)
        let name = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Done" })
        #expect(header.nameFontPointSize == name.font?.pointSize)
        #expect(header.chevronFontPointSize == GlobalFontMagnification.scaledSize(
            metrics.chevronFontSize, percent: model.globalFontMagnificationPercent
        ))
    }

    @Test func aSwiftUIDoneHeaderCutsItsCheckOutInTheCompositedBandColor() throws {
        let presentation = SidebarStatusGroupPresentation(name: "Done", tintHex: "#6B7280", glyph: nil, behavesAs: .done)
        for scheme in [ColorScheme.light, .dark] {
            let header = SidebarStatusGroupSwiftUIHeader(
                statusId: "done", presentation: presentation, memberCount: 1, isCollapsed: false,
                listWidth: 320, colorScheme: scheme, fontScale: 1, globalFontMagnificationPercent: 100
            )
            let palette = SidebarGroupHeaderBandPalette(
                tintHex: presentation.tintHex, isAnchorActive: false, isMultiSelected: false,
                multiSelectionBackgroundStyle: .clear,
                renderedAppearance: .init(colorScheme: scheme, contrast: .standard)
            )
            func image(tick: NSColor) -> Data? {
                SidebarStatusHeaderGlyphImage.make(
                    presentation: presentation, fontScale: 1, colorScheme: scheme,
                    nameColor: palette.primaryTextColor, tickColor: tick
                ).tiffRepresentation
            }
            let drawn = try #require(header.glyphImage.tiffRepresentation)
            let flattened = try #require(image(tick: palette.compositedBandColor))
            let fullStrength = try #require(image(tick: palette.bandColor))
            #expect(flattened != fullStrength)
            #expect(drawn == flattened)
            #expect(drawn != fullStrength)
        }
    }

    // MARK: Done's check is cut out in the band's visible color (#cm-110.1)

    @Test func aBandPaletteExposesTheBandAsItLooksNotTheColorBeforeItsOpacity() {
        for scheme in [ColorScheme.light, .dark] {
            for hex: String? in ["#6B7280", nil] {
                let palette = SidebarGroupHeaderBandPalette(
                    tintHex: hex, isAnchorActive: false, isMultiSelected: false,
                    multiSelectionBackgroundStyle: .clear,
                    renderedAppearance: .init(colorScheme: scheme, contrast: .standard)
                )
                var base = NSColor.windowBackgroundColor
                NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? base
                }
                let band = palette.bandColor.usingColorSpace(.sRGB) ?? palette.bandColor
                let seen = palette.compositedBandColor.usingColorSpace(.sRGB) ?? palette.compositedBandColor
                let alpha = palette.bandOpacity
                #expect(abs(seen.alphaComponent - 1) < 0.001)
                #expect(abs(seen.redComponent - (band.redComponent * alpha + base.redComponent * (1 - alpha))) < 0.003)
                #expect(abs(seen.greenComponent - (band.greenComponent * alpha + base.greenComponent * (1 - alpha))) < 0.003)
                #expect(abs(seen.blueComponent - (band.blueComponent * alpha + base.blueComponent * (1 - alpha))) < 0.003)
                // The band's own color sits far from what is seen: that gap is what the check used to be cut out in.
                let gap = abs(seen.redComponent - band.redComponent) + abs(seen.greenComponent - band.greenComponent)
                    + abs(seen.blueComponent - band.blueComponent)
                #expect(gap > 0.05)
            }
        }
    }

    @Test func aDoneStatusHeaderCutsItsCheckOutInTheBandsVisibleColor() throws {
        let presentation = SidebarStatusGroupPresentation(name: "Done", tintHex: "#6B7280", glyph: nil, behavesAs: .done)
        let model = Sidebar.statusHeaderModel(
            kind: .statusGroup("done"), presentation: presentation, memberCount: 1, unreadCount: 0,
            isCollapsed: false, environment: Self.environment()
        )
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        cell.configurePresentation(model: model)
        let drawn = try #require(cell.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden && $0.image != nil }?.image)
        let palette = SidebarGroupHeaderBandPalette(
            tintHex: model.tintHex, isAnchorActive: model.isAnchorActive, isMultiSelected: model.isMultiSelected,
            multiSelectionBackgroundStyle: model.multiSelectionBackgroundStyle,
            renderedAppearance: .init(cell.effectiveAppearance)
        )
        func image(tick: NSColor) -> Data? {
            SidebarStatusHeaderGlyphImage.make(
                presentation: presentation, fontScale: model.fontScale, colorScheme: model.colorSchemeIsDark ? .dark : .light,
                nameColor: palette.primaryTextColor, tickColor: tick
            ).tiffRepresentation
        }
        let flattened = try #require(image(tick: palette.compositedBandColor))
        let fullStrength = try #require(image(tick: palette.bandColor))
        #expect(flattened != fullStrength) // the two colors really draw differently, so the next two lines can tell them apart
        #expect(drawn.tiffRepresentation == flattened)
        #expect(drawn.tiffRepresentation != fullStrength)
    }


}
